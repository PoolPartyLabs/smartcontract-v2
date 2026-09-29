// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {IncomeAccumulator} from "../../../src/libraries/IncomeAccumulator.sol";
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

    uint256 public forwarded;
    uint256 public feesOut;
    uint256 public lastIndex;
    bool public indexDecreased;
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

    modifier trackIndex() {
        _;
        uint256 index = vault.incomeState(address(usdc)).index;
        if (index < lastIndex) indexDecreased = true;
        lastIndex = index;
    }

    function deposit(uint256 seed, uint256 amount) external trackIndex {
        address who = actors[seed % 3];
        amount = bound(amount, 100e6, 50_000e6);
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        try vault.deposit(amount, 0) {} catch {}
        vm.stopPrank();
    }

    function requestPayout(uint256 seed, uint256 amount, bool standard) external trackIndex {
        address who = actors[seed % 3];
        if (shares.balanceOf(who) == 0 || vault.payoutRequest(who).open) return;
        // DEC-035 spirit (final verification): a request buys at least one share at the current Share Price.
        amount = bound(amount, (vault.sharePrice() + 1e18 - 1) / 1e18, 100_000e6);
        vm.prank(who);
        vault.requestPayout(amount, standard ? ICoreVault.PayoutMode.Standard : ICoreVault.PayoutMode.Instant);
    }

    function claim(uint256 seed) external trackIndex {
        address who = actors[seed % 3];
        ICoreVault.PayoutRequest memory req = vault.payoutRequest(who);
        if (!req.open) return;
        if (block.timestamp < req.termEndsAt) vm.warp(req.termEndsAt);
        vm.prank(who);
        try vault.claimPayout("") {} catch {}
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e6);
        uint256 before = vault.sharePrice();
        usdc.mint(address(vault), amount);
        donations += amount;
        if (vault.sharePrice() != before) donationMovedPrice = true;
    }

    /// @dev Ruling 2026-09-29: collected income reaching the Core Vault is split at once; the fee leaves it.
    function forwardIncome(uint256 amount) external trackIndex {
        amount = bound(amount, 1, 10_000e6);
        forwarded += amount;
        address protocol = vault.protocolRecipient();
        uint256 before = usdc.balanceOf(protocol) + usdc.balanceOf(vault.managerFeeVault());
        hubVault.forwardIncome(address(usdc), amount);
        feesOut += usdc.balanceOf(protocol) + usdc.balanceOf(vault.managerFeeVault()) - before;
    }

    function withdrawIncome(uint256 seed) external trackIndex {
        vm.prank(actors[seed % 3]);
        vault.withdrawIncome(address(usdc));
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

    function invariant_Q60_indexNeverDecreases() public view {
        assertFalse(handler.indexDecreased());
    }

    /// @dev Ruling 2026-09-29, DEC-107: every collected unit is either a fee transferred out at collection or in the
    ///      accumulator (index or ownerless); holders never take more than was distributed.
    function invariant_DEC107_everyCollectedUnitIsFeeOrAccumulated() public view {
        IncomeAccumulator.TokenIncome memory t = vault.incomeState(address(usdc));
        assertEq(t.distributed + t.ownerless + handler.feesOut(), handler.forwarded());
        assertLe(t.taken, t.distributed);
    }
}
