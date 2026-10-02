// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {AcrossHarnessVault} from "../../mocks/across/AcrossHarnessVault.sol";
import {IAcrossSpokePoolLive} from "../../mocks/across/IAcrossSpokePoolLive.sol";

/// @notice DEC-162 on the live Across SpokePools: the Across adapter's rule-built deposit is accepted on both chains
///         with every term fixed by the adapter, fills on the destination at the adapter's amount, and the stuck-send
///         loop (expiry, refund, the vault notes it, one band up) runs on the live pool. Ported from the bridge fee
///         research prototype (branch test/pp-sc-test-bridge-fee-research, commit ce7ece0), without signed quotes.
contract AcrossFeeRuleLiveForkTest is Test {
    uint256 internal constant ARBITRUM_CHAIN_ID = 42_161;
    address internal constant ARB_SPOKE_POOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant RH_SPOKE_POOL = 0xD29C85F15DF544bA632C9E25829fd29d767d7978;
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint256 internal constant AMOUNT = 20_400e6;
    /// @dev The adapter's first sends: 0.08% plus 0.03 (doc 11 §7 row A, doc 12 §6).
    uint256 internal constant INITIAL_FEE = 16_320_000 + 30_000;

    address internal guardian = makeAddr("guardian");
    address internal spokeVault = makeAddr("spokeVault");
    address internal coreVault = makeAddr("coreVault");
    address internal relayer = makeAddr("relayer");

    AcrossHarnessVault internal vault;
    AcrossBridgeAdapter internal adapter;

    /// @dev Non-indexed fields of the live `FundsDeposited` event.
    struct Deposited {
        bytes32 inputToken;
        bytes32 outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes32 recipient;
        bytes32 exclusiveRelayer;
    }

    // ------------------------------------------------------------------ helpers

    function _forkArbitrum() internal {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        assertEq(block.chainid, ARBITRUM_CHAIN_ID);
    }

    function _forkRobinhood() internal {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));
        assertEq(block.chainid, ROBINHOOD_CHAIN_ID);
    }

    function _deploy(address pool, address token) internal {
        vault = new AcrossHarnessVault();
        adapter = new AcrossBridgeAdapter(address(vault), guardian, pool, address(0));
        vault.pin(adapter);
        deal(token, address(vault), 10 * AMOUNT);
    }

    function _hubToSpoke() internal view returns (IBridgeAdapter.SendRequest memory) {
        return IBridgeAdapter.SendRequest({
            inputToken: ARB_USDC,
            outputToken: RH_USDG,
            inputAmount: AMOUNT,
            destinationChainId: ROBINHOOD_CHAIN_ID,
            recipient: bytes32(uint256(uint160(spokeVault))),
            message: TransitMessage.encode(
                keccak256("fund"), ARBITRUM_CHAIN_ID, bytes32(uint256(1)), TransferKind.Principal
            )
        });
    }

    function _spokeToHub() internal view returns (IBridgeAdapter.SendRequest memory) {
        return IBridgeAdapter.SendRequest({
            inputToken: RH_USDG,
            outputToken: ARB_USDC,
            inputAmount: AMOUNT,
            destinationChainId: ARBITRUM_CHAIN_ID,
            recipient: bytes32(uint256(uint160(coreVault))),
            message: TransitMessage.encode(
                keccak256("fund"), ROBINHOOD_CHAIN_ID, bytes32(uint256(2)), TransferKind.Income
            )
        });
    }

    function decodeDeposited(bytes calldata data) external pure returns (Deposited memory d) {
        (d.inputToken, d.outputToken, d.inputAmount, d.outputAmount, d.quoteTimestamp) =
            abi.decode(data, (bytes32, bytes32, uint256, uint256, uint32));
        (d.fillDeadline, d.exclusivityDeadline, d.recipient, d.exclusiveRelayer) =
            abi.decode(data[5 * 32:], (uint32, uint32, bytes32, bytes32));
    }

    /// @dev Sends through the harness and returns the call plus the single `FundsDeposited` the live pool emitted.
    function _sendAndRead(address pool, IBridgeAdapter.SendRequest memory req)
        internal
        returns (IBridgeAdapter.BridgeCall memory call, address escrow, Deposited memory d, bytes32 depositor)
    {
        vm.recordLogs();
        (call, escrow) = vault.send(req);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == pool && logs[i].topics[0] == IAcrossSpokePool.FundsDeposited.selector) {
                d = this.decodeDeposited(logs[i].data);
                depositor = logs[i].topics[3];
                assertEq(uint256(logs[i].topics[2]), uint256(call.transitRef), "deposit id = transitRef");
                ++found;
            }
        }
        assertEq(found, 1, "one FundsDeposited");
    }

    function _assertAdapterFixedTerms(
        IBridgeAdapter.SendRequest memory req,
        IBridgeAdapter.BridgeCall memory call,
        address escrow,
        Deposited memory d,
        bytes32 depositor
    ) internal view {
        assertEq(depositor, bytes32(uint256(uint160(escrow))), "keyless escrow is the depositor");
        assertEq(d.recipient, req.recipient, "recipient fixed by the vault");
        assertEq(d.inputAmount, AMOUNT, "amount sent");
        assertEq(d.outputAmount, call.amountToArrive, "amount to arrive fixed by the adapter");
        assertEq(d.exclusiveRelayer, bytes32(0), "no exclusive relayer");
        assertEq(d.exclusivityDeadline, 0, "no exclusivity");
        assertEq(d.quoteTimestamp, block.timestamp, "quote time = block time");
        assertEq(d.fillDeadline, block.timestamp + 21_600, "6 h deadline (DEC-066)");
    }

    // ------------------------------------------------------------------ tests

    /// DEC-162: on Arbitrum One the live pool accepts the adapter-built deposit; every term is the adapter's.
    function test_DEC162_arbitrum_ruleBuiltDepositIsAcceptedWithAdapterFixedTerms() public {
        _forkArbitrum();
        _deploy(ARB_SPOKE_POOL, ARB_USDC);
        IBridgeAdapter.SendRequest memory req = _hubToSpoke();
        (IBridgeAdapter.BridgeCall memory call, address escrow, Deposited memory d, bytes32 depositor) =
            _sendAndRead(ARB_SPOKE_POOL, req);
        _assertAdapterFixedTerms(req, call, escrow, d, depositor);
        assertEq(AMOUNT - d.outputAmount, INITIAL_FEE, "initial rate 0.08% plus 3 cents");
    }

    /// DEC-162: the same on Robinhood Chain for a send home.
    function test_DEC162_robinhood_ruleBuiltDepositIsAcceptedWithAdapterFixedTerms() public {
        _forkRobinhood();
        _deploy(RH_SPOKE_POOL, RH_USDG);
        IBridgeAdapter.SendRequest memory req = _spokeToHub();
        (IBridgeAdapter.BridgeCall memory call, address escrow, Deposited memory d, bytes32 depositor) =
            _sendAndRead(RH_SPOKE_POOL, req);
        _assertAdapterFixedTerms(req, call, escrow, d, depositor);
        assertEq(AMOUNT - d.outputAmount, INITIAL_FEE, "initial rate 0.08% plus 3 cents");
    }

    /// DEC-162: the adapter-built hub-to-spoke deposit fills on the live Robinhood Chain pool at the adapter's amount.
    function test_DEC162_ruleBuiltDepositFillsOnTheDestinationPool() public {
        _forkArbitrum();
        _deploy(ARB_SPOKE_POOL, ARB_USDC);
        IBridgeAdapter.SendRequest memory req = _hubToSpoke();
        (IBridgeAdapter.BridgeCall memory call, address escrow, Deposited memory d,) = _sendAndRead(ARB_SPOKE_POOL, req);

        IAcrossSpokePoolLive.V3RelayData memory rd = IAcrossSpokePoolLive.V3RelayData({
            depositor: bytes32(uint256(uint160(escrow))),
            recipient: d.recipient,
            exclusiveRelayer: bytes32(0),
            inputToken: d.inputToken,
            outputToken: d.outputToken,
            inputAmount: d.inputAmount,
            outputAmount: d.outputAmount,
            originChainId: ARBITRUM_CHAIN_ID,
            depositId: uint256(call.transitRef),
            fillDeadline: d.fillDeadline,
            exclusivityDeadline: 0,
            message: req.message
        });
        _forkRobinhood();
        // The exact relay data of the deposit (the recipient is an EOA stand-in, so no handler runs). The fill
        // deadline is hours after the Robinhood pin, so the live pool accepts the fill.
        deal(RH_USDG, relayer, d.outputAmount);
        vm.startPrank(relayer);
        IERC20(RH_USDG).approve(RH_SPOKE_POOL, d.outputAmount);
        IAcrossSpokePoolLive(RH_SPOKE_POOL).fillRelay(rd, ARBITRUM_CHAIN_ID, bytes32(uint256(uint160(relayer))));
        vm.stopPrank();
        assertEq(IERC20(RH_USDG).balanceOf(spokeVault), call.amountToArrive, "arrives at the adapter's amount");
        IAcrossSpokePoolLive pool = IAcrossSpokePoolLive(RH_SPOKE_POOL);
        assertEq(pool.fillStatuses(pool.getV3RelayHash(rd)), 2, "this deposit's relay hash is Filled");
    }

    /// DEC-162 stuck-send loop on the live Robinhood Chain pool: a send at the initial rate expires, Across refunds the
    /// escrow after the deadline, the vault notes the expiry, and the retry goes one band up (0.08% to 0.12%) and is
    /// accepted by the live pool with a fresh quote time and deadline.
    function test_DEC162_robinhood_expiredSendIsRetriedOneBandUp() public {
        _forkRobinhood();
        _deploy(RH_SPOKE_POOL, RH_USDG);
        IBridgeAdapter.SendRequest memory req = _spokeToHub();
        (IBridgeAdapter.BridgeCall memory stuck, address escrow,,) = _sendAndRead(RH_SPOKE_POOL, req);
        assertEq(AMOUNT - stuck.amountToArrive, INITIAL_FEE);

        // Nobody fills: after the deadline Across refunds the full amount to the escrow (68 to 99 min later on
        // Robinhood Chain, measured 2026-10-02), and the vault recognizes it and notes the expiry.
        vm.warp(uint256(stuck.fillDeadline) + 99 minutes);
        deal(RH_USDG, escrow, AMOUNT);
        vault.noteExpiry(stuck.transitRef);

        (IBridgeAdapter.BridgeCall memory retry, address escrow2, Deposited memory d, bytes32 depositor) =
            _sendAndRead(RH_SPOKE_POOL, req);
        assertEq(AMOUNT - retry.amountToArrive, 24_480_000 + 30_000, "one band above the expired rate");
        _assertAdapterFixedTerms(req, retry, escrow2, d, depositor);
    }
}
