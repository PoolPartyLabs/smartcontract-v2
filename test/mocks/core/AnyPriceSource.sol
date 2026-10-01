// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Price source that prices every token at 1.00 USDC per base unit, now. For fixtures that only need the
///         Core Vault's creation-time price-coverage check (independent review M-03) to pass.
contract AnyPriceSource {
    function priceInUsdc(address) external view returns (uint256, uint256) {
        return (1e18, block.timestamp);
    }

    function usdcValue(address, uint256 amount) external view returns (uint256, uint256) {
        return (amount, block.timestamp);
    }

    function maxPriceAge(address) external pure returns (uint256) {
        return 1 hours;
    }
}
