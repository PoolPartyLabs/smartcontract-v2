// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {DollarIncomeReference} from "../DollarIncomeIndexModel.t.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

contract CoreVaultIncomeModelTest is CoreVaultFixture {
    DollarIncomeReference internal referenceModel;

    function setUp() public override {
        super.setUp();
        _deployAtMinimumFees();
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        address[] memory holders = new address[](3);
        holders[0] = manager;
        holders[1] = alice;
        holders[2] = bob;
        referenceModel = new DollarIncomeReference(tokens, holders);
        referenceModel.mint(manager, shares.balanceOf(manager));
        (uint256 minted,) = _deposit(alice, 100e6);
        referenceModel.mint(alice, minted);
    }

    function testFuzz_DEC161_vaultMatchesPerHolderReferenceAcrossMintsAndCollections(
        uint96 firstIncome,
        uint96 secondIncome,
        uint16 firstPrice,
        uint16 secondPrice,
        uint32 depositAmount
    ) public {
        uint256 first = bound(firstIncome, 1e12, 1e20);
        uint256 second = bound(secondIncome, 1e12, 1e20);
        uint256 priceOne = bound(firstPrice, 1000, 4000);
        uint256 priceTwo = bound(secondPrice, 1000, 4000);
        _earnHubIncome(address(weth), first);
        referenceModel.recognize(address(weth), _netOfMinimumFee(first));
        (uint256 minted,) = _deposit(bob, bound(depositAmount, 1e6, 1000e6));
        referenceModel.mint(bob, minted);
        hubVault.setSaleRate(address(weth), priceOne * 1e6, 1e18);
        _collectHubIncome();
        _convertReference(first, first * priceOne * 1e6 / 1e18);
        _compare();
        vm.prank(alice);
        uint256 paid = vault.withdrawIncome();
        _earnHubIncome(address(weth), second);
        hubVault.setSaleRate(address(weth), priceTwo * 1e6, 1e18);
        referenceModel.recognize(address(weth), _netOfMinimumFee(second));
        _collectHubIncome();
        _convertReference(second, second * priceTwo * 1e6 / 1e18);
        assertApproxEqAbs(_incomeOf(alice) + paid, referenceModel.dollars(alice), 4);
        assertApproxEqAbs(_incomeOf(bob), referenceModel.dollars(bob), 4);
        assertApproxEqAbs(_incomeOf(manager), referenceModel.dollars(manager), 4);
    }

    function _convertReference(uint256 gross, uint256 dollars) internal {
        uint256[] memory sold = new uint256[](2);
        uint256[] memory obtained = new uint256[](2);
        sold[1] = _netOfMinimumFee(gross);
        obtained[1] = dollars - dollars * (gross - sold[1]) / gross;
        referenceModel.collect(sold, obtained);
    }

    function _compare() internal view {
        assertApproxEqAbs(_incomeOf(alice), referenceModel.dollars(alice), 2);
        assertApproxEqAbs(_incomeOf(bob), referenceModel.dollars(bob), 2);
        assertApproxEqAbs(_incomeOf(manager), referenceModel.dollars(manager), 2);
    }
}
