// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {IncomeAccumulator} from "../../../src/libraries/IncomeAccumulator.sol";

/// @title Model fund for Medusa: ShareMath and IncomeAccumulator composed the way the Core Vault composes them
/// @notice A stateful property harness with no tokens and no external calls: four holders deposit, take payouts and
///         withdraw income against one Share Assets number that only losses lower, and income is distributed through
///         the accumulator. Medusa calls the public functions in random sequences and checks the `property_`
///         functions after every call and the `assert`s inside the actions (assertion testing).
/// @dev Run from a project that holds src/libraries and this file (docs/security/reports/dynamic-analysis.md):
///      `medusa fuzz --config test/security/medusa/medusa.json`. Foundry compiles the file but never runs it.
/// @dev The model stays in the regime the rounding bounds are stated for: deposits up to 1e15 USDC base units and a
///      Share Price of at least 1e20 (0.0001 USDC per whole share), so one step never moves more than two base units
///      of rounding between holders (DEC-035, DEC-061, DEC-077).
contract LibraryPropertiesMedusa {
    using IncomeAccumulator for IncomeAccumulator.State;

    uint256 internal constant HOLDERS = 4;
    uint256 internal constant WHOLE = 1e18;
    uint256 internal constant MAX_FLOW = 1e15;
    uint256 internal constant MIN_PRICE = 1e20;
    uint16 internal constant FLOW_FEE_BPS = 25;
    address internal constant TOKEN = address(0xA11CE);

    IncomeAccumulator.State internal acc;

    uint256 public shareAssets;
    uint256 public totalShares;
    uint256[HOLDERS] public balance;
    uint256[HOLDERS] public paidIn;
    uint256[HOLDERS] public paidOut;
    uint256 public valueOps;
    uint256 public distributed;
    uint256 public taken;
    uint256 public highestIndex;

    constructor() {
        acc.registerToken(TOKEN);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------------------------

    function deposit(uint8 who, uint256 usdcAmount) public {
        uint256 h = who % HOLDERS;
        usdcAmount = 1 + usdcAmount % MAX_FLOW;
        uint256 price = ShareMath.sharePrice(shareAssets, totalShares);
        if (price < MIN_PRICE) return;
        (uint256 shares, uint256 usdcForShares, uint256 fee) = ShareMath.previewDeposit(usdcAmount, FLOW_FEE_BPS, price);
        if (shares == 0) return;
        // DEC-035, DEC-061, DEC-106: whole shares, never charged above the amount offered.
        assert(shares % WHOLE == 0);
        assert(usdcForShares + fee <= usdcAmount);
        assert(fee * 100 <= usdcAmount);

        acc.checkpoint(_holder(h), balance[h]);
        bool firstMint = totalShares == 0;
        shareAssets += usdcForShares;
        totalShares += shares;
        balance[h] += shares;
        paidIn[h] += usdcForShares;
        ++valueOps;
        // DEC-084: a mint never raises the Share Price. Not so for the first mint after every share was burned: it
        // prices at 1.00 and captures whatever Share Assets were left (rounding dust here), the DEC-061 residual that
        // docs/OPEN-QUESTIONS.md flags for a ruling. Medusa found it in five calls (see the report).
        if (!firstMint) assert(ShareMath.sharePrice(shareAssets, totalShares) <= price);
    }

    function payout(uint8 who, uint256 usdcRequested) public {
        uint256 h = who % HOLDERS;
        if (balance[h] == 0) return;
        uint256 price = ShareMath.sharePrice(shareAssets, totalShares);
        if (price < MIN_PRICE) return;
        usdcRequested = 1 + usdcRequested % MAX_FLOW;
        uint256 shares = ShareMath.sharesToBurn(usdcRequested, price);
        if (shares > balance[h]) shares = balance[h];
        uint256 gross = ShareMath.usdcFor(shares, price);
        // DEC-077: whole shares, never paid above the request; DEC-084: never above Share Assets.
        assert(shares % WHOLE == 0);
        assert(gross <= usdcRequested);
        assert(gross <= shareAssets);

        acc.checkpoint(_holder(h), balance[h]);
        shareAssets -= gross;
        totalShares -= shares;
        balance[h] -= shares;
        paidOut[h] += gross;
        ++valueOps;
        // DEC-077: a burn never lowers the Share Price of those who stay.
        if (totalShares != 0) assert(ShareMath.sharePrice(shareAssets, totalShares) >= price);
    }

    /// @notice A market loss: Share Assets only ever go down in this model, and the price stays above the floor.
    function lose(uint256 bps) public {
        if (totalShares == 0) return;
        uint256 loss = shareAssets * (bps % 5001) / 10_000;
        if (ShareMath.sharePrice(shareAssets - loss, totalShares) < MIN_PRICE) return;
        shareAssets -= loss;
    }

    function distributeIncome(uint256 amount) public {
        amount = amount % 1e24;
        uint256 indexBefore = acc.tokenIncome[TOKEN].index;
        bool accepted = acc.distribute(TOKEN, amount, totalShares);
        // Q60: never reverts, never lowers the index, carries a remainder below the supply.
        assert(accepted);
        assert(acc.tokenIncome[TOKEN].index >= indexBefore);
        if (totalShares != 0) {
            distributed += amount;
            if (amount != 0) assert(acc.tokenIncome[TOKEN].remainder < totalShares);
        }
    }

    function withdrawIncome(uint8 who, uint256 cap) public {
        uint256 h = who % HOLDERS;
        acc.checkpoint(_holder(h), balance[h]);
        uint256 owedBefore = acc.owed(_holder(h), TOKEN, balance[h]);
        uint256 amount = acc.takeOwed(_holder(h), TOKEN, cap);
        // LC-100: min(owed, cap).
        assert(amount == (owedBefore < cap ? owedBefore : cap));
        taken += amount;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Properties
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-091: the supply and every balance are whole shares, and the balances add up to the supply.
    function property_supplyIsWholeAndSumsUp() public view returns (bool) {
        uint256 sum;
        for (uint256 h; h < HOLDERS; ++h) {
            if (balance[h] % WHOLE != 0) return false;
            sum += balance[h];
        }
        return sum == totalShares && totalShares % WHOLE == 0;
    }

    /// DEC-084: the whole supply valued at the Share Price never exceeds Share Assets.
    function property_supplyValueNeverExceedsShareAssets() public view returns (bool) {
        if (totalShares == 0) return true;
        return ShareMath.usdcFor(totalShares, ShareMath.sharePrice(shareAssets, totalShares)) <= shareAssets;
    }

    /// No holder ends with more than they put in: payouts received plus the value of the shares held never exceed
    /// what the holder paid for shares, beyond two base units of rounding per deposit or payout executed by anyone.
    function property_noHolderEndsWithMoreThanTheyPutIn() public view returns (bool) {
        uint256 price = ShareMath.sharePrice(shareAssets, totalShares);
        for (uint256 h; h < HOLDERS; ++h) {
            if (paidOut[h] + ShareMath.usdcFor(balance[h], price) > paidIn[h] + 2 * valueOps) return false;
        }
        return true;
    }

    /// DEC-014, Q60: owed plus taken never exceeds what was distributed, and the accumulator's totals are exact.
    function property_owedPlusTakenNeverExceedsDistributed() public view returns (bool) {
        IncomeAccumulator.TokenIncome storage t = acc.tokenIncome[TOKEN];
        uint256 owed;
        for (uint256 h; h < HOLDERS; ++h) {
            owed += acc.owed(_holder(h), TOKEN, balance[h]);
        }
        return owed + t.taken <= t.distributed && t.distributed == distributed && t.taken == taken;
    }

    function _holder(uint256 h) internal pure returns (address) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(0x1000 + h));
    }
}
