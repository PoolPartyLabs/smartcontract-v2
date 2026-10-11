// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ShareToken} from "../../src/core/ShareToken.sol";
import {DollarIncomeIndex} from "../../src/libraries/DollarIncomeIndex.sol";

library IncomeSettlementHistory {
    using DollarIncomeIndex for DollarIncomeIndex.State;

    function prepare(DollarIncomeIndex.State storage index, address shareToken, address holder, uint256 balance)
        external
        returns (uint256 dollars)
    {
        index.activate(uint64(block.timestamp + 1));
        index.activate(uint64(block.timestamp + 2));
        while (!index.settle(holder, balance)) {}
        index.wait(holder, balance / 2, block.timestamp + 3);
        index.activate(uint64(block.timestamp + 4));
        index.activate(uint64(block.timestamp + 5));
        uint256[] memory sold = new uint256[](15);
        for (uint256 collection; collection < 64; ++collection) {
            for (uint256 token; token < 15; ++token) {
                assert(index.recognize(index.tokens[token], 1000, ShareToken(shareToken).totalSupply()));
                sold[token] = 1000;
            }
            uint64 frozen = index.freeze(sold);
            index.finalizeFrozen(frozen, sold);
            dollars += 15_000;
        }
    }
}
