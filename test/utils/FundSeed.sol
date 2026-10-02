// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {ICoreVaultLifecycle} from "../../src/interfaces/ICoreVaultLifecycle.sol";

/// @notice The manager's seed (DEC-127) in fixtures. Fixtures that deploy a Core Vault themselves play its `factory`
///         (`CoreVaultConfig.factory`): the test contract pays the seed and the manager receives the shares, as in
///         `FundFactory.createFund`. Fixtures that go through the factory give the manager the seed and the approval.
/// @dev Fixtures seed the smallest amount that buys one whole share at 1.00 after the flow fee, so a fund starts with
///      `SEED_SHARES` held by the manager and `SEED_IDLE` in Idle, and their Mandate minimum is 1 USDC.
abstract contract FundSeed is Test {
    /// @dev What a fixture seed leaves in the fund: one share, backed by 1 USDC of Idle.
    uint256 internal constant SEED_SHARES = 1e18;
    uint256 internal constant SEED_IDLE = 1e6;
    /// @dev The Mandate minimum fixtures use, so the one-share seed reaches it (DEC-061).
    uint256 internal constant FIXTURE_MIN_FIRST_DEPOSIT = 1e6;

    /// @dev The gross seed that buys exactly one whole share at 1.00 after a flow fee of `flowFeeBps`.
    function _oneShareSeed(uint256 flowFeeBps) internal pure returns (uint256) {
        return Math.mulDiv(SEED_IDLE, 10_000, 10_000 - flowFeeBps, Math.Rounding.Ceil);
    }

    /// @dev Seeds `coreVault` with one share for its manager, paying `usdc` from this contract.
    function _seedFund(address coreVault, address usdc, uint256 flowFeeBps) internal returns (uint256 minted) {
        minted = _seedFundWith(coreVault, usdc, _oneShareSeed(flowFeeBps));
    }

    /// @dev Seeds `coreVault` with `amount` (gross, the flow fee included).
    function _seedFundWith(address coreVault, address usdc, uint256 amount) internal returns (uint256 minted) {
        deal(usdc, address(this), IERC20(usdc).balanceOf(address(this)) + amount);
        IERC20(usdc).approve(coreVault, amount);
        minted = ICoreVaultLifecycle(coreVault).seed(amount);
        IERC20(usdc).approve(coreVault, 0);
    }

    /// @dev DEC-127: the manager holds `amount` of `usdc` and approves `factory` for it before `createFund`.
    function _fundManagerSeed(address usdc, address manager, address factory, uint256 amount) internal {
        deal(usdc, manager, IERC20(usdc).balanceOf(manager) + amount);
        vm.prank(manager);
        IERC20(usdc).approve(factory, amount);
    }
}
