// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {Mandate, OperatingCashConfig} from "../../../src/mandate/Mandate.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice DEC-127, DEC-061, DEC-113, DEC-121: the manager seeds the fund at creation; the fund is born with shares,
///         the first ones the manager's, at 1.00, after the flow fee; a fund with no shares never takes a deposit.
/// @dev The test contract plays the factory (`CoreVaultConfig.factory`).
contract CoreVaultSeedTest is CoreVaultFixture {
    /// @dev A fund as the factory leaves it before the seed, with the register's 100 USDC minimum.
    function _unseeded() internal returns (CoreVault v) {
        Mandate memory m = _mandate(2000);
        m.minFirstDeposit = 100e6;
        v = _deployUnseeded(m, _config(25));
    }

    function _fundFactory(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(vault), amount);
    }

    /// @dev DEC-113 example on the seed (D-34): 100,000 pays 250 and mints 99,750 shares at 1.00 to the manager.
    function test_DEC127_seedPaysTheFlowFeeAndMintsToTheManagerAtOne() public {
        _unseeded();
        _fundFactory(100_000e6);
        uint256 protocolBefore = usdc.balanceOf(protocol);

        vm.expectEmit(address(vault));
        emit ICoreVaultLifecycle.FundSeeded(manager, 99_750e6, 250e6, 99_750e18);
        uint256 minted = vault.seed(100_000e6);

        assertEq(minted, 99_750e18);
        assertEq(shares.balanceOf(manager), 99_750e18, "the first shares are the manager's");
        assertEq(shares.totalSupply(), 99_750e18);
        assertEq(vault.idle(), 99_750e6);
        assertEq(usdc.balanceOf(protocol) - protocolBefore, 250e6, "DEC-113: the seed pays the flow fee");
        assertEq(vault.sharePrice(), ONE, "DEC-061: 1.00 per share");
        assertEq(vault.managerPeakShares(), 99_750e18, "DEC-146: the seed is the first peak");
        assertEq(usdc.allowance(address(this), address(vault)), 0, "pulled exactly what was approved");
    }

    /// @dev DEC-035: the remainder below one share never leaves the payer.
    function test_DEC127_seedChargesOnlyWholeShares() public {
        _unseeded();
        _fundFactory(100.5e6);
        uint256 before = usdc.balanceOf(address(this));
        uint256 minted = vault.seed(100.5e6); // fee 0.25125, net 100.24875: 100 shares
        assertEq(minted, 100e18);
        assertEq(vault.idle(), 100e6);
        assertEq(before - usdc.balanceOf(address(this)), 100e6 + 0.25125e6, "the 0.24875 remainder stays");
    }

    /// @dev DEC-061, DEC-127: the Mandate minimum binds the seed.
    function test_DEC061_seedBelowTheMinimumReverts() public {
        _unseeded();
        _fundFactory(100e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BelowMinFirstDeposit.selector, 99_999_999, 100e6));
        vault.seed(99_999_999);
        vault.seed(100e6);
        assertEq(shares.balanceOf(manager), 99e18, "100 USDC less 0.25 of flow fee buys 99 whole shares");
    }

    function test_DEC127_onlyTheFactorySeeds() public {
        _unseeded();
        usdc.mint(manager, 100e6);
        vm.startPrank(manager);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.NotFactory.selector, manager));
        vault.seed(100e6);
        vm.stopPrank();
        assertEq(vault.factory(), address(this));
    }

    function test_DEC127_seedRunsOnce() public {
        // The fixture's vault is already seeded.
        _fundFactory(100e6);
        vm.expectRevert(ICoreVaultLifecycle.AlreadySeeded.selector);
        vault.seed(100e6);
    }

    /// @dev DEC-121, DEC-127: a fund with no shares takes no deposit, so it never re-opens at 1.00.
    function test_DEC121_depositIntoAFundWithoutSharesReverts() public {
        _unseeded();
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(ICoreVaultLifecycle.FundNotSeeded.selector);
        vault.deposit(1000e6, 0);
        vm.stopPrank();
    }

    /// @dev DEC-121: after the last share is burned neither a deposit nor a second seed re-opens the fund at 1.00. While
    ///      Open the manager's burn stops at half of the peak (DEC-147, D-27; CoreVaultManagerBase.t.sol), so a supply
    ///      of 0 belongs to the closure (DEC-150, WP-13), which does not exist yet; the supply is forced to 0 here.
    function test_DEC121_aFundWhoseSharesWereAllBurnedNeverReopens() public {
        _deposit(alice, 1000e6);
        vm.mockCall(address(shares), abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));

        usdc.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(ICoreVaultLifecycle.FundNotSeeded.selector);
        vault.deposit(1000e6, 0);
        vm.stopPrank();

        _fundFactory(100e6);
        vm.expectRevert(ICoreVaultLifecycle.AlreadySeeded.selector);
        vault.seed(100e6);
    }

    function test_DEC127_constructorRequiresTheFactory() public {
        CoreVaultConfig memory c = _config(25);
        c.factory = address(0);
        vm.expectRevert(ICoreVault.ZeroAddress.selector);
        new CoreVault(_mandate(2000), c);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The seed and hub Operating Cash (DEC-096): the first value-moving operation tops it up out of the seed's Idle
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A seed of the Mandate minimum with hub Operating Cash live from creation (floor 1, top-up 3): 100 USDC buys
    ///      99 shares; the first deposit tops up 3 out of the seed's Idle before pricing, so the entrant pays 96 / 99.
    function test_DEC096_theFirstDepositTopsUpOperatingCashOutOfTheSeed() public {
        Mandate memory m = _mandate(2000);
        m.minFirstDeposit = 100e6;
        m.operatingCash = new OperatingCashConfig[](1);
        m.operatingCash[0] = OperatingCashConfig(HUB, 1e6, 3e6);
        _deployUnseeded(m, _config(25));
        _fundFactory(100e6);
        vault.seed(100e6);
        assertEq(vault.idle(), 99e6);
        assertEq(vault.operatingCash(), 0, "the seed does not top up");
        assertEq(vault.sharePrice(), ONE);

        (uint256 minted,) = _deposit(alice, 1003e6); // 1,000.49 after the flow fee
        assertEq(vault.operatingCash(), 3e6, "topped up out of the seed's Idle");
        assertEq(
            minted, ShareMath.sharesForDeposit(1003e6 - ShareMath.flowFee(1003e6, 25), uint256(96e6) * 1e36 / 99e18)
        );
        assertEq(minted, 1031e18, "1,000.49 at 0.9697");
    }

    /// @dev Review round 1 (low): a seed whose Idle is at or below the top-up leaves a Share Price of 0 once the top-up
    ///      runs, so every deposit reverts, the manager's too; the top-up reverts with the deposit, so nothing is lost,
    ///      and once the manager lowers the parameters the fund takes deposits. Documented on `seed`, not refused:
    ///      the manager can move Free Idle into Operating Cash at any time anyway (security review S-5).
    function test_DEC096_aSeedAtOrBelowTheTopUpBlocksDepositsUntilTheManagerLowersIt() public {
        Mandate memory m = _mandate(2000);
        m.minFirstDeposit = 25e6;
        m.operatingCash = new OperatingCashConfig[](1);
        m.operatingCash[0] = OperatingCashConfig(HUB, 10e6, 30e6);
        _deployUnseeded(m, _config(25));
        _fundFactory(25e6);
        vault.seed(25e6); // 24 shares, 24 USDC of Idle
        assertEq(vault.idle(), 24e6);

        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000_000e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SharePriceBelowOneUnit.selector, 0));
        vault.deposit(1_000_000e6, 0);
        vm.stopPrank();
        usdc.mint(manager, 1000e6);
        vm.startPrank(manager);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SharePriceBelowOneUnit.selector, 0));
        vault.deposit(1000e6, 0);
        vm.stopPrank();
        assertEq(vault.idle(), 24e6, "the top-up reverted with the deposit");
        assertEq(vault.operatingCash(), 0);

        vm.prank(manager);
        vault.setOperatingCashParameters(1e6, 3e6);
        (uint256 minted,) = _deposit(alice, 1003e6);
        assertGt(minted, 0, "deposits resume");
        assertEq(vault.operatingCash(), 3e6);
    }

    /// @dev Below one share after the flow fee, the seed is refused (DEC-035).
    function test_DEC035_seedBelowOneShareReverts() public {
        Mandate memory m = _mandate(2000);
        m.minFirstDeposit = 0;
        _deployUnseeded(m, _config(25));
        _fundFactory(1e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.DepositBelowOneShare.selector, 997_500, ONE));
        vault.seed(1e6);
    }
}
