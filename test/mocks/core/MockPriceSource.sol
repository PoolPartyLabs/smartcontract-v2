// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";

/// @notice IPriceSource with settable prices and update times.
contract MockPriceSource is IPriceSource {
    struct Price {
        uint256 price1e18;
        uint256 updatedAt;
        bool set;
        bool reverts;
    }

    mapping(address => Price) public prices;
    uint256 public maxPriceAge = 1 hours;

    function setPrice(address token, uint256 price1e18) external {
        prices[token] = Price(price1e18, block.timestamp, true, false);
    }

    function setPriceAt(address token, uint256 price1e18, uint256 updatedAt) external {
        prices[token] = Price(price1e18, updatedAt, true, false);
    }

    function setReverts(address token, bool reverts) external {
        prices[token].reverts = reverts;
    }

    function setMaxPriceAge(uint256 age) external {
        maxPriceAge = age;
    }

    function priceInUsdc(address token) public view returns (uint256, uint256) {
        Price memory p = prices[token];
        if (!p.set || p.reverts) revert UnsupportedToken(token);
        return (p.price1e18, p.updatedAt);
    }

    function usdcValue(address token, uint256 amount) external view returns (uint256 value, uint256 updatedAt) {
        (uint256 price, uint256 at) = priceInUsdc(token);
        return (amount * price / 1e18, at);
    }
}
