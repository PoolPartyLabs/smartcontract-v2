// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DollarIncomeIndex} from "../../../src/libraries/DollarIncomeIndex.sol";

/// @dev Minimal share book around `DollarIncomeIndex`: the harness plays the Core Vault, settling a holder with the
///      balance before every mint and burn and applying the open-interval adjustment before the balance changes.
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
        s.settle(holder, sharesOf[holder]);
        s.onMint(holder, shares);
        sharesOf[holder] += shares;
        totalShares += shares;
    }

    function burn(address holder, uint256 shares) external {
        s.settle(holder, sharesOf[holder]);
        s.onBurn(holder, shares);
        sharesOf[holder] -= shares;
        totalShares -= shares;
    }

    function recognize(address token, uint256 amount) external returns (bool) {
        return s.recognize(token, amount, totalShares);
    }

    function collect(uint256[] calldata sold, uint256[] calldata obtained) external returns (uint256) {
        return s.collect(sold, obtained, totalShares);
    }

    function settle(address holder) external {
        s.settle(holder, sharesOf[holder]);
    }

    function take(address holder, uint256 maxDollars) external returns (uint256) {
        s.settle(holder, sharesOf[holder]);
        return s.take(holder, maxDollars);
    }

    /// @dev Raw hooks, for misuse tests (no settlement, no balance change).
    function settleRaw(address holder, uint256 shares) external {
        s.settle(holder, shares);
    }

    function onMintRaw(address holder, uint256 minted) external {
        s.onMint(holder, minted);
    }

    function onBurnRaw(address holder, uint256 burned) external {
        s.onBurn(holder, burned);
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

    function rateAt(uint256 closedInterval, address token) external view returns (uint256) {
        return s.rate[closedInterval][token];
    }

    function holderState(address account)
        external
        view
        returns (uint256 dollars, uint256 mark, uint64 adjustmentInterval, bool adjusted)
    {
        DollarIncomeIndex.Holder storage h = s.holders[account];
        return (h.dollars, h.mark, h.interval, h.adjusted);
    }

    function adjustment(address account, address token) external view returns (int256) {
        return s.holders[account].adjustment[token];
    }

    function totals() external view returns (uint256 obtained, uint256 attributed, uint256 taken) {
        return (s.dollarsObtained, s.dollarsAttributed, s.dollarsTaken);
    }
}
