// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {HubFundFixture} from "../../security/integrations/HubFundFixture.sol";

/// @notice Third-party code that runs in the middle of the hub Spoke Vault's swap, as a hop token's transfer hook does
///         under SwapRouter02 on an API route through a token outside the Mandate (DEC-173). It deposits into the Core
///         Vault, or claims its open Payout Request.
contract MidSwapActor {
    ICoreVault public immutable core;
    IERC20 public immutable usdc;
    bool public claims;
    bool public catchRevert;
    bool public fired;
    bytes public revertData;
    uint256 public minted;
    uint256 public sharesBurned;
    uint256 public claimSharePrice;
    uint256 public requestedAmount;

    constructor(ICoreVault core_, IERC20 usdc_) {
        core = core_;
        usdc = usdc_;
    }

    function setClaims(bool claims_) external {
        claims = claims_;
    }

    function setCatchRevert(bool catchRevert_) external {
        catchRevert = catchRevert_;
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        usdc.approve(address(core), amount);
        (shares,) = core.deposit(amount, 0);
    }

    function request(uint256 usdcAmount) external {
        requestedAmount = usdcAmount;
    }

    function onMidSwap() external {
        fired = true;
        if (claims) {
            ICoreVaultPayouts.PayoutReceipt memory r =
                core.requestPayout(requestedAmount, ICoreVaultPayouts.PayoutMode.Instant, 0);
            (sharesBurned, claimSharePrice) = (r.sharesBurned, r.sharePrice);
            return;
        }
        uint256 amount = usdc.balanceOf(address(this));
        usdc.approve(address(core), amount);
        if (!catchRevert) {
            (minted,) = core.deposit(amount, 0);
            return;
        }
        try core.deposit(amount, 0) returns (uint256 shares, uint256) {
            minted = shares;
        } catch (bytes memory reason) {
            revertData = reason;
        }
    }
}

/// @title Regression (PR #13 review, M-1): no share is minted or burned at a mid-swap Share Price
/// @notice DEC-173 lets an API-signed route pass through a token outside the Mandate, and SwapRouter02 calls that
///         token between hops, while the hub Spoke Vault's ledger shows the input gone and the output not yet credited.
///         The Core Vault values the hub by calling `buildReport()` directly, so a deposit made from that hook was
///         priced without the swapped amount (measured on an Arbitrum fork: Share Price 1.00 seen as 0.21, 4.86x the
///         fair shares minted; `HopTokenReentrantMintFork.t.sol`).
/// @dev Fix: `SpokeVault.buildReport()` reverts while a guarded entry of the vault runs. A mint then reverts and a
///      payout falls back to the last known hub value (DEC-056), which still counts the amount being swapped. The hook
///      here is the swap adapter stand-in's `midSwapHook`, called where SwapRouter02 calls a hop token.
contract MidSwapReentrantMintTest is HubFundFixture {
    uint256 internal constant HOLDER_DEPOSIT = 10_000e6;
    uint256 internal constant HUB_ALLOCATION = 8000e6;
    uint256 internal constant SWAPPED = 6000e6;
    uint256 internal constant ATTACK = 5000e6;

    address internal holder = makeAddr("holder");
    MidSwapActor internal actor;

    function setUp() public override {
        super.setUp();
        _deposit(holder, HOLDER_DEPOSIT);
        vm.prank(manager);
        core.allocateToHubSpokeVault(HUB_ALLOCATION);
        hubSwap.setPrice(address(usdc), address(weth), 1e18, WETH_PRICE * 1e6);
        actor = new MidSwapActor(core, IERC20(address(usdc)));
        hubSwap.setMidSwapHook(address(actor));
    }

    /// @dev The attack as reported: the hook's deposit reverts, so the route (and the manager's swap) reverts.
    function test_REVIEW_PR13_M1_aMidSwapDepositRevertsTheSwap() public {
        usdc.mint(address(actor), ATTACK);
        uint256 priceBefore = core.sharePrice();
        vm.prank(manager);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hubVault.swap(address(hubSwap), address(usdc), address(weth), SWAPPED, 0, "");
        assertEq(shares.balanceOf(address(actor)), 0, "nothing minted");
        assertEq(core.sharePrice(), priceBefore);
        assertEq(hubVault.unallocatedBalance(address(usdc)), HUB_ALLOCATION, "the swap never happened");
    }

    /// @dev A hook that catches its own revert lets the swap complete, and still mints nothing.
    function test_REVIEW_PR13_M1_aHookThatCatchesTheRevertMintsNothing() public {
        usdc.mint(address(actor), ATTACK);
        actor.setCatchRevert(true);
        uint256 priceBefore = core.sharePrice();
        vm.prank(manager);
        uint256 wethOut = hubVault.swap(address(hubSwap), address(usdc), address(weth), SWAPPED, 0, "");

        assertTrue(actor.fired(), "the hook ran mid-swap");
        assertEq(actor.revertData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(actor.minted(), 0);
        assertEq(shares.balanceOf(address(actor)), 0);
        assertEq(usdc.balanceOf(address(actor)), ATTACK, "the deposit never left the hook");
        assertEq(wethOut, Math.mulDiv(SWAPPED, 1e18, WETH_PRICE * 1e6));
        assertEq(core.sharePrice(), priceBefore, "a swap at the external price leaves the Share Price unchanged");
        // Outside any call the report serves the Core Vault again, and a deposit is priced in full.
        (uint256 fair,,) = ShareMath.previewDeposit(ATTACK, core.flowFeeBps(), priceBefore);
        assertEq(actor.deposit(ATTACK), fair);
    }

    /// @dev Payout liveness (DEC-021, DEC-056): a claim from the hook is not blocked; it is priced at the last known hub
    ///      value, which still counts the USDC being swapped, never at the mid-swap ledger.
    function test_REVIEW_PR13_M1_aMidSwapClaimIsPricedAtTheLastKnownHubValue() public {
        usdc.mint(address(actor), ATTACK);
        actor.deposit(ATTACK);
        actor.request(1000e6);
        uint256 priceBefore = core.sharePrice();
        actor.setClaims(true);

        vm.expectEmit(address(core));
        emit ICoreVault.HubValuationFallback(HUB_ALLOCATION);
        vm.prank(manager);
        hubVault.swap(address(hubSwap), address(usdc), address(weth), SWAPPED, 0, "");

        assertTrue(actor.fired());
        assertEq(actor.claimSharePrice(), priceBefore, "the pre-swap Share Price, not the mid-swap one");
        assertEq(actor.sharesBurned(), ShareMath.sharesToBurn(1000e6, priceBefore));
    }
}
