// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title PoC: the manager can sink the fund's Free Idle (hub) and Unallocated Balance (spoke) into Operating Cash,
///        a bucket with no exit
/// @notice ATTACK. `setOperatingCashParameters(floor, topUp)` is manager-only but unbounded on both vaults
///         (CoreVaultBase.sol:269, SpokeVault.sol:368). Whenever Operating Cash is below the floor, the next
///         value-moving operation moves `min(topUp, Free Idle)` (hub) or `min(topUp, Unallocated Balance)` (spoke)
///         out of Share Assets into Operating Cash (CoreVaultBase.sol:283, SpokeVault.sol:988). Nothing in the MVP
///         ever spends or returns Operating Cash, and it is excluded from Share Assets, from `sweepExcess` and from
///         every payout. So the manager (or a compromised or fat-fingered manager key: `3e18` instead of `3e6` is
///         enough) sets a huge floor and top-up, and the next operation freezes the money for good:
///         - hub: two manager transactions (`setOperatingCashParameters`, then any guarded verb such as
///           `allocateToHubSpokeVault`) freeze all Free Idle;
///         - spoke: one manager transaction, then ANY Across arrival (a stranger's 1 USDG fill is enough) freezes
///           the whole Unallocated Balance of the base token.
/// @notice IMPACT. Permanent freeze of customer funds and a Share Price collapse: shareholders exit with cents on
///         their deposits while the USDC stays in the Core Vault as Operating Cash with no owner and no verb to
///         move it (contracts are immutable, DEC-022). The manager gains nothing, so this is a grief or an accident,
///         but the Mandate is supposed to bound what the manager key can do (DEC-002, DEC-003).
/// @notice BUSINESS RULE. DEC-096 lets the manager adjust the floor on a live fund and DEC-100 sets no protocol cap
///         on the floor. Neither decision asks for an unbounded top-up, nor for a bucket that can never be returned.
/// @notice FIX. Bound what one top-up can take (for example `topUp <= max(constant, x bps of Share Assets)`, and
///         floor and top-up capped at creation values times a constant factor), and give Operating Cash an exit that
///         returns it to Idle or to Unallocated Balance (DEC-096 already says it belongs to shareholders at fund
///         close), for example a permissionless "release above floor" that moves `operatingCash - floor` back.
contract OperatingCashSinkPoC is AccessFundFixture {
    function test_REGRESSION_managerSinksFreeIdleIntoOperatingCash() public {
        (IFundFactory.FundAddresses memory addresses,) = _createFund(_plan());
        CoreVault core = CoreVault(addresses.coreVault);
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        core.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(core.operatingCash(), 0);
    }

    function test_REGRESSION_anyArrivalSinksSpokeUnallocatedBalanceIntoOperatingCash() public {
        FundFactory spokeFactory = _spokeFactory();
        bytes32 fundId = spokeFactory.fundIdOf(HUB, 1, manager);
        Mandate memory mandate = _buildMandate(spokeFactory, fundId, _plan());
        vm.prank(manager);
        IFundFactory.ChainAddresses memory addresses =
            spokeFactory.createSpoke(1, mandate, _spokeParams(MandateLib.hash(mandate), _plan()));
        SpokeVault spoke = SpokeVault(addresses.spokeVault);
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        spoke.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(spoke.operatingCash(), 0);
    }

    /// @dev An Instant Payout Request for everything `who` deposited, claimed at once; returns the USDC received.
    function _exitAll(CoreVault core, address who) internal returns (uint256 paid) {
        uint256 before = _balance(usdc, who);
        vm.startPrank(who);
        core.requestPayout(1_000_000e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        vm.stopPrank();
        paid = _balance(usdc, who) - before;
    }

    /// @dev A relayer fill on the spoke: the SpokePool transfers the base token, then calls the handler.
    function _arrive(SpokeVault spoke, bytes32 fundId, uint256 amount, bytes32 transitId) internal {
        usdg.mint(address(spoke), amount);
        vm.prank(address(spokeAcross));
        spoke.handleV3AcrossMessage(
            address(usdg), amount, stranger, TransitMessage.encode(fundId, HUB, transitId, TransferKind.Principal)
        );
    }
}
