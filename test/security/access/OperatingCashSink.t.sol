// SPDX-License-Identifier: MIT
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
    function test_POC_managerSinksFreeIdleIntoOperatingCash() public {
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        CoreVault core = CoreVault(a.coreVault);
        _deposit(core, alice, 600_000e6);
        _deposit(core, bob, 400_000e6);
        uint256 idleBefore = core.idle();
        assertEq(idleBefore, SEED_IDLE + 997_500e6, "both deposits, net of the flow fee, sit in Idle");
        assertEq(core.sharePrice(), 1e24, "1.00 USDC per share");

        // The manager: one setter call, then any guarded verb. Everything but 1 USDC of Free Idle becomes Operating
        // Cash.
        vm.startPrank(manager);
        core.setOperatingCashParameters(type(uint256).max, idleBefore - 1e6);
        core.allocateToHubSpokeVault(1e6);
        vm.stopPrank();

        assertEq(core.operatingCash(), idleBefore - 1e6, "997,499 USDC of customer money is now Operating Cash");
        assertEq(core.idle(), 0);
        assertEq(core.shareAssets(), 1e6, "Share Assets: the 1 USDC that reached the hub Spoke Vault");
        assertLt(core.sharePrice(), uint256(1e24) / 900_000, "Share Price fell by more than 99.9998%");

        // Nothing brings it back: not the manager lowering the parameters again, not the garbage collector.
        vm.prank(manager);
        core.setOperatingCashParameters(0, 0);
        assertEq(core.sweepExcess(address(usdc)), 0, "Operating Cash is ledger value, never swept");
        assertEq(core.operatingCash(), idleBefore - 1e6);

        // Both shareholders exit in full. They burn every share and receive less than 1 USDC together.
        uint256 alicePaid = _exitAll(core, alice);
        uint256 bobPaid = _exitAll(core, bob);
        assertLt(alicePaid + bobPaid, 1e6, "1,000,000 USDC deposited, under 1 USDC paid out");
        assertEq(_shares(core, alice) + _shares(core, bob), 0, "no share is left");

        // The customers' USDC is still in the Core Vault, owned by nobody, reachable by no function.
        assertGe(core.operatingCash(), 997_499e6);
        assertGe(_balance(usdc, address(core)), 997_499e6);
        assertLt(core.shareAssets(), 1e6, "under 1 USDC of Share Assets is left");
    }

    function test_POC_anyArrivalSinksSpokeUnallocatedBalanceIntoOperatingCash() public {
        // The fund's spoke, created by the real spoke factory from the hub's Mandate.
        FundFactory spokeFactory = _spokeFactory();
        bytes32 fundId = spokeFactory.fundIdOf(HUB, 1, manager);
        Mandate memory m = _buildMandate(spokeFactory, fundId, _plan());
        vm.prank(manager);
        IFundFactory.ChainAddresses memory c = spokeFactory.createSpoke(1, m, _spokeParams(MandateLib.hash(m), _plan()));
        SpokeVault spoke = SpokeVault(c.spokeVault);

        // 500,000 USDG of fund principal arrives from the hub (the Mandate's creation values top up 10 USDG).
        _arrive(spoke, fundId, 500_000e6, keccak256("hub transit 1"));
        assertEq(spoke.unallocatedBalance(address(usdg)), 499_990e6);
        assertEq(spoke.operatingCash(), 10e6);

        // One manager transaction...
        vm.prank(manager);
        spoke.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        // ...then any arrival, here a stranger's 1 USDG Across fill (Across passes no depositor, OQ-01).
        _arrive(spoke, fundId, 1e6, keccak256("a stranger's dust"));

        assertEq(spoke.unallocatedBalance(address(usdg)), 0, "the whole Unallocated Balance is gone");
        assertEq(spoke.operatingCash(), 500_001e6, "frozen as Operating Cash: outside Share Assets, no exit");
        assertEq(spoke.sweepExcess(address(usdg)), 0);
        // The value report the hub prices Share Assets from now carries no principal for this spoke.
        assertEq(spoke.buildReport().unallocated[0].amount, 0);
        assertEq(spoke.buildReport().operatingCash, 500_001e6);
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
