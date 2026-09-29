// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ShareMath
/// @notice Whole-share arithmetic, Share Price and the protocol flow fee.
/// @dev Representation of Share Price: USDC base units (6 decimals) per WHOLE share (1e18 share base units),
///      multiplied by `PRICE_SCALE` (1e18) for precision. So 1.00 USDC per share is 1e6 * 1e18 = 1e24 and 1.09 USDC
///      per share is 1.09e24. A price computed from Share Assets and total shares is rounded down; the error is below
///      1e-18 USDC base units per whole share, which cannot change a whole-share count or a USDC amount for any
///      realistic fund size.
/// @dev DEC-035, DEC-061, DEC-077, DEC-091: only whole shares are minted or burned; share counts are rounded down on
///      both ends; the USDC value of whole shares is truncated to 6 decimals; the payout never exceeds the request.
library ShareMath {
    /// @notice Base units of one whole share (DEC-091: 18 decimals).
    uint256 internal constant WHOLE_SHARE = 1e18;

    /// @notice Extra precision carried by a Share Price.
    uint256 internal constant PRICE_SCALE = 1e18;

    /// @notice Share Price at every fund's first issuance: 1 whole share = 1.00 USDC (DEC-061, DEC-091).
    uint256 internal constant INITIAL_SHARE_PRICE = 1e6 * PRICE_SCALE;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Protocol flow fee default for new funds: 0.25% (DEC-106).
    uint16 internal constant DEFAULT_FLOW_FEE_BPS = 25;

    /// @notice Protocol flow fee cap: 1%, a core constant (DEC-106, DEC-110).
    uint16 internal constant MAX_FLOW_FEE_BPS = 100;

    /// @dev WHOLE_SHARE * PRICE_SCALE.
    uint256 private constant PRICE_DENOMINATOR = 1e36;

    /// @notice A mint or burn amount is not a multiple of 1e18 (DEC-091).
    error NotWholeShares(uint256 shares);

    /// @notice Share Price is zero (Share Assets are zero while shares exist); no share can be priced.
    error ZeroSharePrice();

    /// @notice The flow fee rate is above the 1% core cap (DEC-110).
    error FlowFeeAboveCap(uint256 bps);

    /// @notice A rate above 100%.
    error BpsAboveMax(uint256 bps);

    /// @notice Whether `shares` is a whole number of shares (DEC-091).
    function isWholeShares(uint256 shares) internal pure returns (bool) {
        return shares % WHOLE_SHARE == 0;
    }

    /// @notice Reverts with `NotWholeShares` unless `shares` is a multiple of 1e18 (DEC-091).
    function requireWholeShares(uint256 shares) internal pure {
        if (shares % WHOLE_SHARE != 0) revert NotWholeShares(shares);
    }

    /// @notice Share Price = Share Assets / total shares, scaled (see the library notes).
    /// @dev DEC-061: with no shares outstanding the price is the initial price, fixed in the contract.
    /// @param shareAssets Share Assets in USDC base units (DEC-083, DEC-084).
    /// @param totalShares Share supply in base units (always a multiple of 1e18).
    function sharePrice(uint256 shareAssets, uint256 totalShares) internal pure returns (uint256) {
        if (totalShares == 0) return INITIAL_SHARE_PRICE;
        return Math.mulDiv(shareAssets, PRICE_DENOMINATOR, totalShares);
    }

    /// @notice Whole shares a net deposit buys, in base units (a multiple of 1e18), rounded down.
    /// @dev DEC-035: `floor(net / price)` whole shares; the depositor pays only `usdcFor(shares, price)`. Returns 0
    ///      when `usdcNet` is below one share's price; the Core Vault rejects that deposit (DEC-035).
    function sharesForDeposit(uint256 usdcNet, uint256 price) internal pure returns (uint256 shares) {
        if (price == 0) revert ZeroSharePrice();
        shares = Math.mulDiv(usdcNet, PRICE_SCALE, price) * WHOLE_SHARE;
    }

    /// @notice USDC value of whole shares, truncated to 6 decimals (USDC base units, rounded down).
    /// @dev DEC-061: rounding applies only to shares; the USDC value is truncated at the 6th decimal. DEC-091: reverts
    ///      with `NotWholeShares` for a fractional amount.
    function usdcFor(uint256 shares, uint256 price) internal pure returns (uint256) {
        requireWholeShares(shares);
        return Math.mulDiv(shares, price, PRICE_DENOMINATOR);
    }

    /// @notice Whole shares to burn for a USDC amount, in base units (a multiple of 1e18), rounded down.
    /// @dev DEC-077: `floor(usdc / price)` whole shares, so the payout `usdcFor(burned)` never exceeds the request.
    ///      DEC-020: the caller caps the result at the holder's balance (insufficient shares burn all and pay what
    ///      they are worth).
    function sharesToBurn(uint256 usdcRequested, uint256 price) internal pure returns (uint256 shares) {
        if (price == 0) revert ZeroSharePrice();
        shares = Math.mulDiv(usdcRequested, PRICE_SCALE, price) * WHOLE_SHARE;
    }

    /// @notice `amount * bps / 10_000`, rounded down. Reverts above 100%.
    function bpsOf(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (bps > BPS) revert BpsAboveMax(bps);
        return Math.mulDiv(amount, bps, BPS);
    }

    /// @notice Protocol flow fee on a flow amount, rounded down.
    /// @dev DEC-106, DEC-110: charged on entry and exit, capped at 1% as a core constant. On a deposit it is deducted
    ///      before shares are computed; on a payout it is deducted from the amount paid (LC-143 reading, OPEN). It is
    ///      never charged on Income Withdrawal. Rounding direction is not decided; the MVP rounds the fee down, which
    ///      never overcharges the shareholder.
    function flowFee(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (bps > MAX_FLOW_FEE_BPS) revert FlowFeeAboveCap(bps);
        return Math.mulDiv(amount, bps, BPS);
    }

    /// @notice Arithmetic of a deposit of `usdcAmount` at `price` with a flow fee of `flowFeeBps`.
    /// @dev DEC-106: the flow fee is taken from the deposited amount before pricing (the MVP reading stated in
    ///      docs/ARCHITECTURE.md §4.1; whether the fee is taken from the amount or on top is OPEN). DEC-035: shares are
    ///      whole and rounded down; the depositor pays `fee + usdcForShares`, and the remainder
    ///      `usdcAmount - fee - usdcForShares` never leaves the wallet (DEC-061).
    /// @return shares Whole shares to mint, in base units; 0 when the net amount buys less than one share.
    /// @return usdcForShares USDC that buys `shares`, credited to Idle.
    /// @return fee Flow fee on `usdcAmount`, paid to the protocol.
    function previewDeposit(uint256 usdcAmount, uint256 flowFeeBps, uint256 price)
        internal
        pure
        returns (uint256 shares, uint256 usdcForShares, uint256 fee)
    {
        fee = flowFee(usdcAmount, flowFeeBps);
        shares = sharesForDeposit(usdcAmount - fee, price);
        usdcForShares = usdcFor(shares, price);
    }
}
