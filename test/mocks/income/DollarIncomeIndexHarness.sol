// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {DollarIncomeIndex} from "../../../src/libraries/DollarIncomeIndex.sol";

/// @dev Minimal share book around `DollarIncomeIndex`: the harness plays the Core Vault, settling a holder with the
///      balance before every mint and burn and applying the open-interval adjustment before the balance changes.
///      Unlike a vault, which settles once and lets the hooks revert on a settlement left unfinished by the step
///      bound, the harness repeats `settle` until it completes, so random sequences never stop on the bound.
contract DollarIncomeIndexHarness {
    using DollarIncomeIndex for DollarIncomeIndex.State;

    DollarIncomeIndex.State internal s;
    mapping(address holder => uint256) public sharesOf;
    uint256 public totalShares;

    constructor(uint8 source) {
        s.source = source;
    }

    function registerToken(address token) external {
        s.registerToken(token);
    }

    function mint(address holder, uint256 shares) external {
        _settle(holder);
        s.onMint(holder, shares);
        sharesOf[holder] += shares;
        totalShares += shares;
    }

    function burn(address holder, uint256 shares) external {
        _settle(holder);
        s.onBurn(holder, shares);
        sharesOf[holder] -= shares;
        totalShares -= shares;
    }

    function recognize(address token, uint256 amount) external returns (bool) {
        return s.recognize(token, amount, totalShares);
    }

    function collect(uint256[] calldata sold, uint256[] calldata obtained) external returns (uint256) {
        return s.collect(sold, obtained);
    }

    function settle(address holder) external {
        _settle(holder);
    }

    function take(address holder, uint256 maxDollars) external returns (uint256) {
        _settle(holder);
        return s.take(holder, maxDollars);
    }

    /// @dev Raw hooks, for misuse and bound tests (one call, no balance change).
    function settleRaw(address holder, uint256 shares) external returns (bool) {
        return s.settle(holder, shares);
    }

    function onMintRaw(address holder, uint256 minted) external {
        s.onMint(holder, minted);
    }

    function onBurnRaw(address holder, uint256 burned) external {
        s.onBurn(holder, burned);
    }

    function takeRaw(address holder, uint256 maxDollars) external returns (uint256) {
        return s.take(holder, maxDollars);
    }

    function owedDollars(address holder) external view returns (uint256) {
        return s.owedDollars(holder, sharesOf[holder]);
    }

    function tokenOwed(address holder, address token) external view returns (uint256) {
        return s.tokenOwed(holder, sharesOf[holder], token);
    }

    function tokens() external view returns (address[] memory) {
        return s.incomeTokens();
    }

    function isRegistered(address token) external view returns (bool) {
        return s.isRegistered(token);
    }

    function incomeToken(address token) external view returns (DollarIncomeIndex.IncomeToken memory) {
        return s.token[token];
    }

    function interval() external view returns (uint64) {
        return s.interval;
    }

    function dollarIndex() external view returns (uint256) {
        return s.dollarIndex;
    }

    function rateAt(uint256 tokenInterval, address token) external view returns (uint256) {
        return s.rate[tokenInterval][token];
    }

    function carryAt(uint256 tokenInterval, address token) external view returns (uint256) {
        return s.carry[tokenInterval][token];
    }

    function holderState(address account)
        external
        view
        returns (uint256 dollars, uint256 mark, uint64 settledInterval, bool adjusted)
    {
        DollarIncomeIndex.Holder storage h = s.holders[account];
        return (h.dollars, h.mark, h.interval, h.adjusted);
    }

    function adjustment(address account, address token) external view returns (int256) {
        return s.holders[account].adjustment[token].amount;
    }

    function adjustmentInterval(address account, address token) external view returns (uint64) {
        return s.holders[account].adjustment[token].interval;
    }

    function totals() external view returns (uint256 obtained, uint256 attributed, uint256 taken) {
        return (s.dollarsObtained, s.dollarsAttributed, s.dollarsTaken);
    }

    function _settle(address holder) internal {
        while (!s.settle(holder, sharesOf[holder])) {}
    }
}
