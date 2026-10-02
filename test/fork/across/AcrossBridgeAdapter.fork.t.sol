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
import {AcrossFillSimulator} from "../../mocks/across/AcrossFillSimulator.sol";
import {MockAcrossMessageHandler} from "../../mocks/across/MockAcrossMessageHandler.sol";

/// @dev Live SpokePool members outside the frozen IAcrossSpokePool subset, read only by these tests.
interface IAcrossSpokePoolState {
    function pausedDeposits() external view returns (bool);
    function chainId() external view returns (uint256);
}

/// @notice The adapter's built call executed by a vault harness against the real Across SpokePools on Arbitrum One
///         (Hub Chain) and Robinhood Chain (Spoke Chain), at the pinned fork blocks. Every Across term but the
///         vault's route, recipient, tokens, amount and message is the adapter's (DEC-158, DEC-162).
contract AcrossBridgeAdapterForkTest is Test {
    // Arbitrum One (Hub Chain)
    uint256 internal constant ARBITRUM_CHAIN_ID = 42_161;
    address internal constant ARB_SPOKE_POOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // Robinhood Chain (Spoke Chain)
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant RH_SPOKE_POOL = 0xD29C85F15DF544bA632C9E25829fd29d767d7978;
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint256 internal constant INPUT_AMOUNT = 1000e6;
    uint256 internal constant OUTPUT_AMOUNT = 999_400_000; // about 0.06% route fee (DEC-034, DEC-085)
    /// @dev DEC-162: the adapter's first sends pay 0.08% plus 0.03 (doc 12 §6): 1,000 arrives as 999.17.
    uint256 internal constant RULE_OUTPUT = INPUT_AMOUNT - 800_000 - 30_000;

    address internal guardian = makeAddr("guardian");
    address internal hubCoreVault = makeAddr("hubCoreVault");
    address internal spokeVault = makeAddr("spokeVault");
    address internal relayer = makeAddr("relayer");

    AcrossHarnessVault internal harness;
    AcrossBridgeAdapter internal adapter;

    // ------------------------------------------------------------------ setup helpers

    function _forkArbitrum() internal {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        assertEq(block.chainid, ARBITRUM_CHAIN_ID);
        _deploy(ARB_SPOKE_POOL, ARB_USDC);
    }

    function _forkRobinhood() internal {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));
        assertEq(block.chainid, ROBINHOOD_CHAIN_ID);
        _deploy(RH_SPOKE_POOL, RH_USDG);
    }

    function _deploy(address spokePool, address inputToken) internal {
        harness = new AcrossHarnessVault();
        adapter = new AcrossBridgeAdapter(address(harness), guardian, spokePool);
        harness.pin(adapter);
        deal(inputToken, address(harness), 10 * INPUT_AMOUNT);
    }

    /// @dev Hub to spoke: USDC on Arbitrum, USDG delivered to the Spoke Vault on Robinhood Chain.
    function _hubToSpokeRequest() internal view returns (IBridgeAdapter.SendRequest memory) {
        return IBridgeAdapter.SendRequest({
            inputToken: ARB_USDC,
            outputToken: RH_USDG,
            inputAmount: INPUT_AMOUNT,
            destinationChainId: ROBINHOOD_CHAIN_ID,
            recipient: bytes32(uint256(uint160(spokeVault))),
            message: TransitMessage.encode(
                keccak256("fund"), ARBITRUM_CHAIN_ID, bytes32(uint256(1)), TransferKind.Principal
            )
        });
    }

    /// @dev Spoke to hub: USDG on Robinhood Chain, USDC delivered to the Core Vault on Arbitrum.
    function _spokeToHubRequest() internal view returns (IBridgeAdapter.SendRequest memory) {
        return IBridgeAdapter.SendRequest({
            inputToken: RH_USDG,
            outputToken: ARB_USDC,
            inputAmount: INPUT_AMOUNT,
            destinationChainId: ARBITRUM_CHAIN_ID,
            recipient: bytes32(uint256(uint160(hubCoreVault))),
            message: TransitMessage.encode(
                keccak256("fund"), ROBINHOOD_CHAIN_ID, bytes32(uint256(2)), TransferKind.Income
            )
        });
    }

    function _word(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    /// @dev Predicts the escrow the harness clones next (CREATE by the harness at its current nonce).
    function _nextEscrow() internal view returns (address) {
        return vm.computeCreateAddress(address(harness), vm.getNonce(address(harness)));
    }

    /// @dev Executes one send and asserts the event, the exact debit, the approval reset and the escrow.
    function _sendAndAssert(IBridgeAdapter.SendRequest memory req, address spokePool)
        internal
        returns (IBridgeAdapter.BridgeCall memory call)
    {
        IERC20 token = IERC20(req.inputToken);
        uint256 vaultBefore = token.balanceOf(address(harness));
        uint256 poolBefore = token.balanceOf(spokePool);
        uint32 depositId = IAcrossSpokePool(spokePool).numberOfDeposits();
        address expectedEscrow = _nextEscrow();

        vm.recordLogs();
        address escrow;
        (call, escrow) = harness.send(req);

        assertEq(escrow, expectedEscrow, "escrow is the depositor");
        _assertDeposited(spokePool, req, depositId, escrow, call.amountToArrive);
        assertEq(call.target, spokePool, "target");
        assertEq(uint256(call.transitRef), depositId, "transitRef = deposit id");
        assertEq(IAcrossSpokePool(spokePool).numberOfDeposits(), depositId + 1, "one deposit");
        assertEq(call.fillDeadline, uint32(block.timestamp) + 21_600, "fillDeadline");
        assertEq(token.balanceOf(address(harness)), vaultBefore - req.inputAmount, "exact vault debit");
        assertEq(token.balanceOf(spokePool), poolBefore + req.inputAmount, "pool credit");
        assertEq(token.allowance(address(harness), spokePool), 0, "approval reset");
        assertEq(token.balanceOf(escrow), 0, "escrow holds nothing until a refund");
    }

    /// @dev Decoded non-indexed fields of the live `FundsDeposited` event.
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
        bytes message;
    }

    /// @dev External so the log data can be sliced as calldata.
    function decodeDeposited(bytes calldata data) external pure returns (Deposited memory d) {
        (d.inputToken, d.outputToken, d.inputAmount, d.outputAmount, d.quoteTimestamp) =
            abi.decode(data, (bytes32, bytes32, uint256, uint256, uint32));
        (d.fillDeadline, d.exclusivityDeadline, d.recipient, d.exclusiveRelayer) =
            abi.decode(data[5 * 32:], (uint32, uint32, bytes32, bytes32));
        uint256 messageOffset = abi.decode(data[9 * 32:10 * 32], (uint256));
        d.message = abi.decode(abi.encodePacked(uint256(32), data[messageOffset:]), (bytes));
    }

    /// @dev Finds the single `FundsDeposited` the pool emitted and asserts every field.
    function _assertDeposited(
        address spokePool,
        IBridgeAdapter.SendRequest memory req,
        uint256 depositId,
        address escrow,
        uint256 amountToArrive
    ) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        Vm.Log memory log;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == spokePool && logs[i].topics[0] == IAcrossSpokePool.FundsDeposited.selector) {
                log = logs[i];
                ++found;
            }
        }
        assertEq(found, 1, "one FundsDeposited");
        assertEq(uint256(log.topics[1]), req.destinationChainId, "destinationChainId");
        assertEq(uint256(log.topics[2]), depositId, "depositId");
        assertEq(log.topics[3], _word(escrow), "depositor = escrow");

        Deposited memory d = this.decodeDeposited(log.data);
        assertEq(d.inputToken, _word(req.inputToken), "inputToken");
        assertEq(d.outputToken, _word(req.outputToken), "outputToken");
        assertEq(d.inputAmount, req.inputAmount, "inputAmount");
        assertEq(d.outputAmount, amountToArrive, "outputAmount = the adapter's amount to arrive");
        assertEq(d.quoteTimestamp, block.timestamp, "quoteTimestamp = now");
        assertEq(d.fillDeadline, uint32(block.timestamp) + 21_600, "fillDeadline = now + 6 h");
        assertEq(d.exclusivityDeadline, 0, "no exclusivity");
        assertEq(d.recipient, req.recipient, "recipient");
        assertEq(d.exclusiveRelayer, bytes32(0), "no exclusive relayer");
        assertEq(d.message, req.message, "message");
    }

    /// @dev Deposits open, buffers as DEC-066 assumes, and no on-chain deposit route list on the live pool.
    function _assertRouteOpen(address spokePool, uint256 chainId) internal view {
        assertEq(IAcrossSpokePoolState(spokePool).chainId(), chainId, "pool chain id");
        assertFalse(IAcrossSpokePoolState(spokePool).pausedDeposits(), "deposits paused");
        assertEq(IAcrossSpokePool(spokePool).fillDeadlineBuffer(), 21_600, "fillDeadlineBuffer");
        assertEq(IAcrossSpokePool(spokePool).depositQuoteTimeBuffer(), 3600, "depositQuoteTimeBuffer");
        assertEq(IAcrossSpokePool(spokePool).getCurrentTime(), block.timestamp, "pool time");
        // The live implementations dropped `enabledDepositRoutes`: the call reverts with empty data.
        (bool ok, bytes memory ret) =
            spokePool.staticcall(abi.encodeWithSignature("enabledDepositRoutes(address,uint256)", ARB_USDC, chainId));
        assertFalse(ok, "enabledDepositRoutes exists");
        assertEq(ret.length, 0, "enabledDepositRoutes revert data");
    }

    // ------------------------------------------------------------------ Arbitrum One: hub to spoke

    function test_DEC066_arbitrum_routeOpenAndBuffersMatch() public {
        _forkArbitrum();
        _assertRouteOpen(ARB_SPOKE_POOL, ARBITRUM_CHAIN_ID);
    }

    /// DEC-066, DEC-085, DEC-087, DEC-090, DEC-162: USDC to chain 4663 for USDG; every FundsDeposited field as built,
    /// the amount to arrive the adapter's rule (0.08% plus 0.03 on the first send).
    function test_DEC087_arbitrum_sendUsdcToRobinhoodEmitsEveryField() public {
        _forkArbitrum();
        assertEq(_sendAndAssert(_hubToSpokeRequest(), ARB_SPOKE_POOL).amountToArrive, RULE_OUTPUT);
    }

    /// DEC-158, DEC-162: the live pool accepts every send the adapter builds back to back (quote time = now, no
    /// exclusivity), and the second send on the route is priced from the first.
    function test_DEC162_arbitrum_consecutiveSendsAreAccepted() public {
        _forkArbitrum();
        _sendAndAssert(_hubToSpokeRequest(), ARB_SPOKE_POOL);
        vm.warp(block.timestamp + 60);
        assertEq(_sendAndAssert(_hubToSpokeRequest(), ARB_SPOKE_POOL).amountToArrive, RULE_OUTPUT);
    }

    /// DEC-090: a spoke-to-hub fill arriving on Arbitrum reaches a contract recipient from the SpokePool.
    function test_DEC090_arbitrum_fillSimulationReachesHandler() public {
        _forkArbitrum();
        _assertFill(ARB_SPOKE_POOL, ARB_USDC, _spokeToHubRequest().message);
    }

    // ------------------------------------------------------------------ Robinhood Chain: spoke to hub

    function test_DEC066_robinhood_routeOpenAndBuffersMatch() public {
        _forkRobinhood();
        _assertRouteOpen(RH_SPOKE_POOL, ROBINHOOD_CHAIN_ID);
    }

    /// DEC-066, DEC-085, DEC-087, DEC-090, DEC-162: USDG to chain 42161 for USDC; every FundsDeposited field as built.
    function test_DEC087_robinhood_sendUsdgToArbitrumEmitsEveryField() public {
        _forkRobinhood();
        assertEq(_sendAndAssert(_spokeToHubRequest(), RH_SPOKE_POOL).amountToArrive, RULE_OUTPUT);
    }

    /// DEC-090: a hub-to-spoke fill arriving on Robinhood Chain reaches a contract recipient from the SpokePool.
    function test_DEC090_robinhood_fillSimulationReachesHandler() public {
        _forkRobinhood();
        _assertFill(RH_SPOKE_POOL, RH_USDG, _hubToSpokeRequest().message);
    }

    function _assertFill(address spokePool, address outputToken, bytes memory message) internal {
        MockAcrossMessageHandler handler = new MockAcrossMessageHandler(spokePool);
        AcrossFillSimulator.simulateFill(
            stdstore, spokePool, outputToken, OUTPUT_AMOUNT, address(handler), relayer, message
        );
        assertEq(IERC20(outputToken).balanceOf(address(handler)), OUTPUT_AMOUNT);
        assertEq(handler.calls(), 1);
        assertEq(handler.lastTokenSent(), outputToken);
        assertEq(handler.lastAmount(), OUTPUT_AMOUNT);
        assertEq(handler.lastRelayer(), relayer);
        assertEq(handler.lastMessage(), message);
        assertEq(handler.balanceAtCallback(), OUTPUT_AMOUNT);
    }
}
