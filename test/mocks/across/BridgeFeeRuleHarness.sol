// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BridgeFeeRule} from "../../../src/libraries/BridgeFeeRule.sol";

/// @notice One route of `BridgeFeeRule` with numbers chosen by the test, so doc 12's tables can be replayed at other
///         bands than the Across adapter's constants.
contract BridgeFeeRuleHarness {
    BridgeFeeRule.Params internal _p;
    BridgeFeeRule.Route internal _route;

    constructor(uint256 initialRate, uint256 floorRate, uint256 capRate, uint256 band) {
        _p = BridgeFeeRule.Params({initialRate: initialRate, floorRate: floorRate, capRate: capRate, band: band});
    }

    function nextRate() external view returns (uint256) {
        return BridgeFeeRule.nextRate(_route, _p);
    }

    function referenceRate() external view returns (uint256) {
        return BridgeFeeRule.referenceRate(_route, _p);
    }

    function fee(uint256 amount, uint256 rate, uint256 fixedFee) external pure returns (uint256) {
        return BridgeFeeRule.fee(amount, rate, fixedFee);
    }

    /// @notice Prices and records one send at the rule's next rate.
    function send() external returns (uint64 serial, uint256 rate) {
        rate = BridgeFeeRule.nextRate(_route, _p);
        serial = BridgeFeeRule.record(_route, rate);
    }

    function noteExpiry(uint64 serial, uint256 rate) external {
        BridgeFeeRule.noteExpiry(_route, serial, SafeCast.toUint64(rate));
    }

    function window() external view returns (uint64[3] memory rates, uint64 sends, uint64 expiredRate) {
        return (_route.rates, _route.sends, _route.expiredRate);
    }
}
