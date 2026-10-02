// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {WormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {VaaBody} from "wormhole-sdk/libraries/VaaLib.sol";

import {SpokeVaultForkBase} from "../../fork/spoke/SpokeVaultForkBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";

/// @notice Current Across relay data (bytes32 addresses, uint256 deposit id), as the live SpokePools take it.
struct RelayData {
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

interface ILiveSpokePool {
    function fillRelay(RelayData calldata relayData, uint256 repaymentChainId, bytes32 repaymentAddress) external;
    function requestSlowFill(RelayData calldata relayData) external;
    function getCurrentTime() external view returns (uint256);
}

/// @notice Leads 1 and 2 against the live contracts (public RPCs, blocks pinned below the head), ported to main.
///         Arbitrum: what the live SpokePool does with a fill or a slow-fill request after the deposit's deadline
///         (context for S-23). Robinhood: one-base-unit sends home through the real AcrossBridgeAdapter into the live
///         SpokePool, and a report published through the real Wormhole Core with those sends listed. On main the send
///         count (50) stays within MAX_HUB_BOUND_IN_FLIGHT=64 (S-11); both leads still hold.
contract Fork_AcrossDeadlineAndDustSends is SpokeVaultForkBase {
    using WormholeOverride for ICoreBridge;

    bytes4 internal constant EXPIRED_FILL_DEADLINE = bytes4(keccak256("ExpiredFillDeadline()"));

    function _relay(uint32 fillDeadline) internal returns (RelayData memory r) {
        r.depositor = bytes32(uint256(uint160(makeAddr("escrow"))));
        r.recipient = bytes32(uint256(uint160(makeAddr("coreVault"))));
        r.inputToken = bytes32(uint256(uint160(RH_USDG)));
        r.outputToken = bytes32(uint256(uint160(ARB_USDC)));
        r.inputAmount = 1000e6;
        r.outputAmount = 999e6;
        r.originChainId = ROBINHOOD;
        r.depositId = 12_345;
        r.fillDeadline = fillDeadline;
        r.message = TransitMessage.encode(FUND_ID, ROBINHOOD, keccak256("transit"), TransferKind.Principal);
    }

    /// @notice Lead 2: no fill and no slow-fill request after `fillDeadline` on the destination clock.
    function test_lead2_forkArbitrum_expiredDepositCanNeitherBeFilledNorSlowFilled() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        ILiveSpokePool pool = ILiveSpokePool(ARB_SPOKE_POOL);
        uint256 nowOnArbitrum = pool.getCurrentTime();
        assertEq(nowOnArbitrum, block.timestamp);
        address relayer = makeAddr("relayer");
        deal(ARB_USDC, relayer, 10_000e6);
        vm.prank(relayer);
        IERC20(ARB_USDC).approve(ARB_SPOKE_POOL, type(uint256).max);

        // One second past the deadline: the relayer's fill and a slow-fill request both revert.
        RelayData memory expired = _relay(uint32(nowOnArbitrum - 1));
        vm.prank(relayer);
        vm.expectRevert(EXPIRED_FILL_DEADLINE);
        pool.fillRelay(expired, ARBITRUM, bytes32(uint256(uint160(relayer))));
        vm.prank(relayer);
        vm.expectRevert(EXPIRED_FILL_DEADLINE);
        pool.requestSlowFill(expired);

        // At the deadline the same fill goes through (the recipient is an EOA here, so no handler is called).
        RelayData memory live = _relay(uint32(nowOnArbitrum));
        uint256 before = IERC20(ARB_USDC).balanceOf(makeAddr("coreVault"));
        vm.prank(relayer);
        pool.fillRelay(live, ARBITRUM, bytes32(uint256(uint160(relayer))));
        assertEq(IERC20(ARB_USDC).balanceOf(makeAddr("coreVault")) - before, 999e6);
    }

    /// @notice Lead 1: the live Robinhood SpokePool accepts a dust send home built by the real AcrossBridgeAdapter
    ///         (since DEC-162 the smallest its fee rule lets through: one USDG base unit to arrive); each one lands in
    ///         the report for 6.5 h, and the real Wormhole Core publishes them.
    function test_lead1_forkRobinhood_oneUnitSendsHomeAreAcceptedAndListed() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));
        MockPositionAdapter spokeUni = new MockPositionAdapter(guardian, false);
        spokeUni.addPool(SPOKE_POOL, RH_WETH, RH_USDG);
        TransitEscrow escrowImpl = new TransitEscrow();
        // The real adapter needs its vault at construction and the vault pins the adapter: predict the vault.
        address vaultAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        AcrossBridgeAdapter bridge = new AcrossBridgeAdapter(vaultAt, guardian, RH_SPOKE_POOL);
        ForkAdapters memory a = ForkAdapters({
            hubUni: makeAddr("hubUni"),
            hubAave: makeAddr("hubAave"),
            spokeUni: address(spokeUni),
            hubBridge: makeAddr("hubBridge"),
            spokeBridge: address(bridge),
            spokeVault: vaultAt
        });
        SpokeVault vault = new SpokeVault(
            _mandate(a),
            FUND_ID,
            ROBINHOOD,
            makeAddr("coreVault"),
            RH_USDG,
            RH_SPOKE_POOL,
            RH_WORMHOLE_CORE,
            address(escrowImpl),
            excessRecipient
        );
        assertEq(address(vault), vaultAt);
        spokeUni.setVault(address(vault));
        vm.prank(manager);
        vault.setOperatingCashParameters(0, 0);

        // 1,000 USDG arrive (Across fill as the repository's fork suites simulate it).
        deal(RH_USDG, address(vault), 1000e6);
        vm.prank(RH_SPOKE_POOL);
        vault.handleV3AcrossMessage(
            RH_USDG,
            1000e6,
            makeAddr("relayer"),
            TransitMessage.encode(FUND_ID, ARBITRUM, keccak256("t"), TransferKind.Principal)
        );

        uint32 depositsBefore = IAcrossSpokePool(RH_SPOKE_POOL).numberOfDeposits();
        // DEC-162: the Across adapter refuses a send its fee would swallow; the dust is the smallest send it lets
        // through (0.030026 USDG: 0.08% rounded up plus 0.03, one base unit to arrive). The quote argument is ignored.
        BridgeQuote memory q;
        uint256 dust = 30_026;
        uint256 n = 50;
        uint256 g = gasleft();
        vm.startPrank(manager);
        for (uint256 i; i < n; ++i) {
            vault.sendToHub(dust, TransferKind.Principal, 0, q);
        }
        vm.stopPrank();
        console2.log("average gas per dust send home on Robinhood (warm-ish)", (g - gasleft()) / n);
        assertEq(IAcrossSpokePool(RH_SPOKE_POOL).numberOfDeposits() - depositsBefore, n, "every deposit accepted");
        assertEq(vault.inFlightTransitIds().length, n);

        // The real Wormhole Core publishes the report that lists them; its payload grows by 96 bytes per send.
        vm.recordLogs();
        g = gasleft();
        vault.report();
        console2.log("report() gas on Robinhood with 50 sends listed", g - gasleft());
        VaaBody[] memory published = ICoreBridge(RH_WORMHOLE_CORE).fetchPublishedMessages(vm.getRecordedLogs());
        ReportCodec.Report memory r = ReportCodec.decode(published[0].payload);
        assertEq(r.inFlightToHub.length, n);
        console2.log("payload bytes", published[0].payload.length);
    }
}
