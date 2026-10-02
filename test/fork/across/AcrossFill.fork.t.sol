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

/// @dev Live SpokePool fill entry point (across-protocol/contracts `V3SpokePoolInterface.fillRelay`, selector
///      0xdeff4b24, present in both pinned implementations). Outside the frozen subset; read only by these tests.
interface IAcrossSpokePoolFill {
    struct V3RelayDataBytes32 {
        bytes32 depositor;
        bytes32 recipient;
        bytes32 exclusiveRelayer;
        bytes32 inputToken;
        bytes32 outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 originChainId;
        uint256 depositId;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes message;
    }

    function fillRelay(V3RelayDataBytes32 calldata relayData, uint256 repaymentChainId, bytes32 repaymentAddress)
        external;
}

/// @notice Adversarial fork checks: the fill simulation helper is compared against a real `fillRelay` on the live
///         destination SpokePools, a quote passed by the vault is refused before the live pool is reached, and a
///         stranger's deposit between a build and its execution shifts the id a stale build would carry.
contract AcrossFillForkTest is Test {
    uint256 internal constant ARBITRUM_CHAIN_ID = 42_161;
    address internal constant ARB_SPOKE_POOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant RH_SPOKE_POOL = 0xD29C85F15DF544bA632C9E25829fd29d767d7978;
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    uint256 internal constant INPUT_AMOUNT = 1000e6;
    uint256 internal constant OUTPUT_AMOUNT = 999_400_000;

    address internal guardian = makeAddr("guardian");
    address internal relayer = makeAddr("relayer");
    address internal stranger = makeAddr("stranger");
    address internal spokeVault = makeAddr("spokeVault");

    function _word(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _message(uint256 originChainId) internal pure returns (bytes memory) {
        return TransitMessage.encode(keccak256("fund"), originChainId, bytes32(uint256(9)), TransferKind.Principal);
    }

    // ------------------------------------------------------------------ real fill vs simulator

    /// @dev Drives the live `fillRelay` with `relayer` paying `outputToken`, then runs the simulator on a second
    ///      handler and requires both handlers to have recorded the same callback.
    function _assertRealFillMatchesSimulator(address spokePool, address outputToken, uint256 originChainId) internal {
        bytes memory message = _message(originChainId);
        MockAcrossMessageHandler real = new MockAcrossMessageHandler(spokePool);
        MockAcrossMessageHandler simulated = new MockAcrossMessageHandler(spokePool);

        deal(outputToken, relayer, OUTPUT_AMOUNT);
        vm.startPrank(relayer);
        IERC20(outputToken).approve(spokePool, OUTPUT_AMOUNT);
        IAcrossSpokePoolFill(spokePool)
            .fillRelay(
                IAcrossSpokePoolFill.V3RelayDataBytes32({
                depositor: _word(makeAddr("escrow")),
                recipient: _word(address(real)),
                exclusiveRelayer: bytes32(0),
                inputToken: _word(makeAddr("originToken")),
                outputToken: _word(outputToken),
                inputAmount: INPUT_AMOUNT,
                outputAmount: OUTPUT_AMOUNT,
                originChainId: originChainId,
                depositId: 123_456_789,
                fillDeadline: uint32(block.timestamp) + 21_600,
                exclusivityDeadline: 0,
                message: message
            }),
                block.chainid,
                _word(relayer)
            );
        vm.stopPrank();

        AcrossFillSimulator.simulateFill(
            stdstore, spokePool, outputToken, OUTPUT_AMOUNT, address(simulated), relayer, message
        );

        assertEq(IERC20(outputToken).balanceOf(address(real)), OUTPUT_AMOUNT, "real fill credit");
        assertEq(IERC20(outputToken).balanceOf(relayer), 0, "relayer paid the fill");
        assertEq(real.calls(), 1, "real callback once");
        assertEq(real.calls(), simulated.calls(), "calls");
        assertEq(real.lastTokenSent(), simulated.lastTokenSent(), "tokenSent");
        assertEq(real.lastAmount(), simulated.lastAmount(), "amount");
        assertEq(real.lastRelayer(), simulated.lastRelayer(), "relayer");
        assertEq(real.lastMessage(), simulated.lastMessage(), "message");
        assertEq(real.balanceAtCallback(), simulated.balanceAtCallback(), "balance seen inside the callback");
        assertEq(real.lastTokenSent(), outputToken);
        assertEq(real.lastAmount(), OUTPUT_AMOUNT);
        assertEq(real.lastRelayer(), relayer);
        assertEq(real.balanceAtCallback(), OUTPUT_AMOUNT, "tokens arrive before the callback");
    }

    /// DEC-090: the simulator's argument order, types and transfer-before-callback match the live Arbitrum pool.
    function test_DEC090_arbitrum_realFillRelayMatchesSimulator() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        _assertRealFillMatchesSimulator(ARB_SPOKE_POOL, ARB_USDC, ROBINHOOD_CHAIN_ID);
    }

    /// DEC-090: the same on the live Robinhood Chain pool with USDG.
    function test_DEC090_robinhood_realFillRelayMatchesSimulator() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));
        _assertRealFillMatchesSimulator(RH_SPOKE_POOL, RH_USDG, ARBITRUM_CHAIN_ID);
    }

    // ------------------------------------------------------------------ live pool rejections and ordering

    function _deploy(address spokePool, address inputToken)
        internal
        returns (AcrossHarnessVault harness, AcrossBridgeAdapter adapter)
    {
        harness = new AcrossHarnessVault();
        adapter = new AcrossBridgeAdapter(address(harness), guardian, spokePool);
        harness.pin(adapter);
        deal(inputToken, address(harness), 2 * INPUT_AMOUNT);
    }

    function _hubToSpokeRequest() internal view returns (IBridgeAdapter.SendRequest memory) {
        return IBridgeAdapter.SendRequest({
            inputToken: ARB_USDC,
            outputToken: RH_USDG,
            inputAmount: INPUT_AMOUNT,
            destinationChainId: ROBINHOOD_CHAIN_ID,
            recipient: _word(spokeVault),
            message: _message(ARBITRUM_CHAIN_ID)
        });
    }

    /// DEC-158: the quote terms are the adapter's; a vault that passes a quote in `bridgeData` is refused before the
    /// live pool is reached; the vault keeps its balance and the approval is not left open.
    function test_DEC158_arbitrum_passedQuoteIsRefusedAndMovesNothing() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        (AcrossHarnessVault harness,) = _deploy(ARB_SPOKE_POOL, ARB_USDC);
        IBridgeAdapter.SendRequest memory req = _hubToSpokeRequest();

        vm.expectRevert(AcrossBridgeAdapter.QuotesNotSupported.selector);
        harness.send(req, abi.encode(OUTPUT_AMOUNT, uint32(block.timestamp) + 1));
        assertEq(IERC20(ARB_USDC).balanceOf(address(harness)), 2 * INPUT_AMOUNT, "nothing moved");
        assertEq(IERC20(ARB_USDC).allowance(address(harness), ARB_SPOKE_POOL), 0, "no approval left open");
    }

    /// DEC-090: on the live pool, a stranger's deposit between a build and its execution makes the earlier
    /// `transitRef` stale by one; the harness, which builds and executes in one transaction, matches the emitted id.
    function test_DEC090_arbitrum_strangerDepositShiftsStaleTransitRef() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        (AcrossHarnessVault harness, AcrossBridgeAdapter adapter) = _deploy(ARB_SPOKE_POOL, ARB_USDC);
        IBridgeAdapter.SendRequest memory req = _hubToSpokeRequest();

        uint256 snapshot = vm.snapshotState();
        vm.prank(address(harness));
        IBridgeAdapter.BridgeCall memory stale = adapter.buildSend(req, makeAddr("escrow"), "");
        uint256 staleId = uint256(stale.transitRef);
        vm.revertToState(snapshot);

        deal(ARB_USDC, stranger, INPUT_AMOUNT);
        vm.startPrank(stranger);
        IERC20(ARB_USDC).approve(ARB_SPOKE_POOL, INPUT_AMOUNT);
        IAcrossSpokePool(ARB_SPOKE_POOL)
            .depositV3(
                stranger,
                stranger,
                ARB_USDC,
                RH_USDG,
                INPUT_AMOUNT,
                OUTPUT_AMOUNT,
                ROBINHOOD_CHAIN_ID,
                address(0),
                uint32(block.timestamp),
                uint32(block.timestamp) + 21_600,
                0,
                ""
            );
        vm.stopPrank();

        vm.recordLogs();
        (IBridgeAdapter.BridgeCall memory fresh,) = harness.send(req);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 emittedId = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == ARB_SPOKE_POOL && logs[i].topics[0] == IAcrossSpokePool.FundsDeposited.selector) {
                emittedId = uint256(logs[i].topics[2]);
            }
        }
        assertEq(emittedId, staleId + 1, "stranger took the stale id");
        assertEq(uint256(fresh.transitRef), emittedId, "same-transaction build matches the assigned id");
        assertNotEq(stale.transitRef, fresh.transitRef, "stale build would mislabel the transit");
    }
}
