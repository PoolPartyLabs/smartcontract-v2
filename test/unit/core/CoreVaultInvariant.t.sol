// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice Drives a Core Vault through deposits, requests, claims, donations, income and allocations without reverting.
contract CoreVaultHandler is Test {
    CoreVault internal vault;
    CoreMockToken internal usdc;
    MockHubSpokeVault internal hubVault;
    ShareToken internal shares;
    address internal manager;
    address[3] internal actors;

    uint256 public converted;
    uint256 public feesOut;
    bool public donationMovedPrice;
    uint256 public donations;

    constructor(CoreVault vault_, CoreMockToken usdc_, MockHubSpokeVault hubVault_, address manager_) {
        vault = vault_;
        usdc = usdc_;
        hubVault = hubVault_;
        shares = ShareToken(vault_.shareToken());
        manager = manager_;
        actors = [makeAddr("actor0"), makeAddr("actor1"), makeAddr("actor2")];
    }

    function deposit(uint256 seed, uint256 amount) external {
        address who = actors[seed % 3];
        amount = bound(amount, 100e6, 50_000e6);
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        try vault.deposit(amount, 0) {} catch {}
        vm.stopPrank();
    }

    function requestPayout(uint256 seed, uint256 amount, bool standard) external {
        address who = actors[seed % 3];
        if (shares.balanceOf(who) == 0 || vault.payoutRequest(who).open) return;
        // With Share Assets at zero and shares outstanding no share can be priced and a request reverts with
        // `ZeroSharePrice` (found by the deep campaign of docs/security/reports/dynamic-analysis.md: every Idle unit
        // allocated, then `movePrice(0)`); the handler has nothing to request then.
        uint256 price = vault.sharePrice();
        if (price == 0) return;
        // DEC-035 spirit (final verification): a request buys at least one share at the current Share Price.
        amount = bound(amount, (price + 1e18 - 1) / 1e18, 100_000e6);
        vm.prank(who);
        vault.requestPayout(
            amount, standard ? ICoreVaultPayouts.PayoutMode.Standard : ICoreVaultPayouts.PayoutMode.Instant, 0
        );
    }

    function claim(uint256 seed) external {
        address who = actors[seed % 3];
        ICoreVault.PayoutRequest memory req = vault.payoutRequest(who);
        if (!req.open) return;
        if (block.timestamp < req.termEndsAt) vm.warp(req.termEndsAt);
        vm.prank(who);
        try vault.claimPayout(0) {} catch {}
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e6);
        uint256 before = vault.sharePrice();
        usdc.mint(address(vault), amount);
        donations += amount;
        if (vault.sharePrice() != before) donationMovedPrice = true;
    }

    /// @dev DEC-138: hub income is earned in the positions and recognized at the next mint, burn or request.
    function earnIncome(uint256 amount) external {
        hubVault.earn(address(usdc), bound(amount, 1, 10_000e6));
    }

    /// @dev DEC-122, DEC-161, DEC-172: a request converts the hub income; the fee leaves the Core Vault at once.
    function collectIncome(uint256 seed) external {
        address protocol = vault.protocolRecipient();
        uint256 before = usdc.balanceOf(protocol) + usdc.balanceOf(vault.managerFeeVault());
        converted += hubVault.collectable(address(usdc));
        vm.prank(actors[seed % 3]);
        vault.requestIncomeWithdrawal(0);
        feesOut += usdc.balanceOf(protocol) + usdc.balanceOf(vault.managerFeeVault()) - before;
    }

    function withdrawIncome(uint256 seed) external {
        vm.prank(actors[seed % 3]);
        vault.withdrawIncome();
    }

    function owedToHolders() external view returns (uint256 owed) {
        for (uint256 i; i < 3; ++i) {
            owed += vault.incomeOwed(actors[i]);
        }
        owed += vault.incomeOwed(manager);
    }

    function allocate(uint256 amount) external {
        uint256 free = vault.freeIdle();
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(manager);
        try vault.allocateToHubSpokeVault(amount) {
            hubVault.moveToPosition(amount);
        } catch {}
    }

    function movePrice(uint256 principal) external {
        principal = bound(principal, 0, 2 * hubVault.positionPrincipal() + 1000e6);
        hubVault.setPosition(address(usdc), principal);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 days));
    }
}

contract CoreVaultInvariantTest is CoreVaultFixture {
    CoreVaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Callback);
        handler = new CoreVaultHandler(vault, usdc, hubVault, manager);
        // The protocol's flow fees would otherwise be counted as fees paid.
        targetContract(address(handler));
    }

    function invariant_DEC072_payoutReserveWithinIdle() public view {
        assertLe(vault.payoutReserve(), vault.idle());
    }

    function invariant_DEC091_supplyIsWholeShares() public view {
        assertEq(shares.totalSupply() % 1e18, 0);
    }

    function invariant_DEC104_shareAssetsEqualBuckets() public view {
        assertEq(vault.shareAssets(), _bucketSum());
        assertEq(vault.shareAssets(), vault.idle() + hubVault.unallocatedUsdc() + hubVault.positionPrincipal());
    }

    function invariant_DEC080_balanceCoversLedger() public view {
        assertGe(usdc.balanceOf(address(vault)), _ledgerUsdc());
    }

    function invariant_DEC080_directTransferNeverMovesSharePrice() public view {
        assertFalse(handler.donationMovedPrice());
    }

    /// @dev DEC-161: the USDC held for income covers every holder's converted dollars, and the fees paid plus what is
    ///      held never exceed what the collections converted.
    function invariant_DEC161_heldIncomeCoversTheHoldersAndNeverExceedsTheConverted() public view {
        uint256 held = vault.incomeCollection().heldDollars;
        assertLe(handler.owedToHolders(), held);
        assertLe(handler.feesOut() + held, handler.converted());
    }
}
