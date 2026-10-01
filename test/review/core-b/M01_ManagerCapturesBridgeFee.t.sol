// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";

/// @notice Review port of core-b M01, consolidated finding M-01 (register S-9). On `e5c778a` the manager named itself
///         Across exclusive relayer for the whole fill window and kept `inputAmount - outputAmount` on every send, and
///         MandateLib accepted `maxBridgeFeeBps` up to 10,000 (one send of 100,000 USDC delivered 1 base unit). Since
///         S-9 both vaults revert `ExclusiveRelayerNotAllowed` and `MAX_BRIDGE_FEE_BPS` is 100. What stays, as the
///         register's residual: a quote at the Mandate bound without exclusivity is accepted, Share Assets drop by the
///         bound at once, and whichever relayer fills first earns it; the manager chooses when the deposit is made.
/// @dev Adaptation to main, interface only: the spoke's first report is delivered before the first send (S-14).
contract M01_ManagerCapturesBridgeFee is CoreVaultFixture {
    address internal managerRelayer = makeAddr("managerRelayer");

    /// @dev The exact `depositV3` call the vault's next send will make: transit id and escrow clone are predictable.
    function _expectedDeposit(BridgeQuote memory q, uint256 inputAmount) internal view returns (bytes memory) {
        bytes32 id = keccak256(abi.encode(block.chainid, address(vault), uint256(1)));
        address escrow = vm.computeCreateAddress(address(vault), vm.getNonce(address(vault)));
        return abi.encodeCall(
            IAcrossSpokePool.depositV3,
            (
                escrow,
                spokeVaultAddress,
                address(usdc),
                address(usdg),
                inputAmount,
                q.outputAmount,
                SPOKE,
                q.exclusiveRelayer,
                q.quoteTimestamp,
                uint32(block.timestamp) + 21_600,
                q.exclusivityDeadline,
                TransitMessage.encode(FUND_ID, HUB, id, TransferKind.Principal)
            )
        );
    }

    function _q(uint256 outputAmount, uint32 exclusivityDeadline, address exclusiveRelayer)
        internal
        view
        returns (BridgeQuote memory)
    {
        return BridgeQuote(outputAmount, uint32(block.timestamp), exclusivityDeadline, exclusiveRelayer);
    }

    /// @dev The review's quote and the two half-way variants (relayer without a period, period without a relayer).
    function test_REVIEW_M01_exclusiveRelayerIsRefusedInEveryForm() public {
        _deposit(alice, 1_000_000e6);
        _ensureSpokeReport();
        uint256 assets = vault.shareAssets();

        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExclusiveRelayerNotAllowed.selector, managerRelayer));
        vault.sendToSpoke(0, 100_000e6, 0, _q(99_500e6, 21_600, managerRelayer));
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExclusiveRelayerNotAllowed.selector, managerRelayer));
        vault.sendToSpoke(0, 100_000e6, 0, _q(99_500e6, 0, managerRelayer));
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExclusiveRelayerNotAllowed.selector, address(0)));
        vault.sendToSpoke(0, 100_000e6, 0, _q(99_500e6, 21_600, address(0)));
        vm.stopPrank();
        assertEq(vault.shareAssets(), assets, "nothing left the fund");
    }

    /// @dev The review's 100% Mandate, and one bps above the new cap, are refused at creation.
    function test_REVIEW_M01_mandateBridgeFeeAboveOnePercentIsRefused() public {
        Mandate memory m = _mandate(2000);
        m.maxBridgeFeeBps = 10_000;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.BpsAboveMax.selector, 10_000, 100));
        new CoreVault(m, _config(25));
        m.maxBridgeFeeBps = 101;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.BpsAboveMax.selector, 101, 100));
        new CoreVault(m, _config(25));
    }

    /// @dev Residual (KNOWN-LIMITATIONS S-9): at the 100 bps cap a non-exclusive over-quote is accepted; 1,000 USDC of
    ///      every 100,000 send leaves Share Assets at once and goes to the first relayer to fill.
    function test_POC_REVIEW_M01_overQuoteAtTheCapWithoutExclusivityStillCostsTheBound() public {
        Mandate memory m = _mandate(2000);
        m.maxBridgeFeeBps = MandateLib.MAX_BRIDGE_FEE_BPS;
        _deploy(m, _config(25));
        _deposit(alice, 1_000_000e6);
        _ensureSpokeReport();
        uint256 assets = vault.shareAssets();

        BridgeQuote memory q = _q(99_000e6, 0, address(0));
        vm.expectCall(address(pool), _expectedDeposit(q, 100_000e6));
        vm.prank(manager);
        vault.sendToSpoke(0, 100_000e6, 0, q);
        console2.log("given away per 100,000 send, to the fastest relayer", assets - vault.shareAssets());
        assertEq(assets - vault.shareAssets(), 1000e6);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BridgeFeeAboveMax.selector, 1000e6 + 1, 1000e6));
        vault.sendToSpoke(0, 100_000e6, 0, _q(99_000e6 - 1, 0, address(0)));
    }
}
