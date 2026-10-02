// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title BridgeFeeRule
/// @notice The bridge fee rule of a bridge adapter (DEC-162): the rate of a send comes from the fund's own last sends
///         on the route, never from whoever triggers it (DEC-158), with a hard ceiling and a step up after an expiry so
///         value is never held back by a fee too low for relayers (founder direction of 2026-10-02, checklist doc 12).
/// @dev Why the fund's own history: a contract cannot read other users' bridge transfers. An Across deposit writes
///      only the origin pool's deposit counter and a fill only `fillStatuses[relayHash]`; amounts live only in logs,
///      which the EVM cannot read (fork proof: test/fork/across/AcrossSpokePoolReadability.fork.t.sol).
/// @dev The rule, with rates as WAD fractions of the amount sent (8e14 = 0.08%):
///      - reference: mean of the window, the last `WINDOW` sends' rates on the route, each missing entry counted at
///        `initialRate`, clamped to [floorRate, capRate]. An expired send leaves the window when it is still the
///        route's latest send (the window rewinds, so the retry takes its place); an older send's expiry leaves the
///        window as it is (research prototype semantics, which reproduce checklist doc 12 §5's tables);
///      - next send: the reference; after an expiry was noted, `min(capRate, max(expiredRate, floorRate) * (1 + band))`
///        instead (one step up), consumed by that send;
///      - fee: `ceil(amount * rate) + fixedFee`, which must stay below the amount (a dust send waits in the vault).
///      Without signed API quotes (R-162-B, under evaluation) the rate never falls: it only rises through expiries, up
///      to the cap.
/// @dev Internal library (inlined into the adapter): no deployed code. Every number comes from the caller's `Params`,
///      so the adapter fixes them as constants and tests can replay doc 12's tables at other bands.
library BridgeFeeRule {
    /// @notice 100% as a rate.
    uint256 internal constant WAD = 1e18;

    /// @notice How many past sends the reference averages (the founder's "3 últimas").
    uint256 internal constant WINDOW = 3;

    /// @notice The rule's numbers, all WAD fractions of the amount sent.
    /// @param initialRate Rate counted for each missing entry of the window.
    /// @param floorRate Lowest rate ever used; above zero, so a step after an expiry always rises.
    /// @param capRate Hard ceiling of every send.
    /// @param band Step after an expiry, as a fraction of the expired rate (0.5e18 = +50%).
    struct Params {
        uint256 initialRate;
        uint256 floorRate;
        uint256 capRate;
        uint256 band;
    }

    /// @notice One route's history (one destination chain).
    /// @param rates Ring of the window's rates; zero marks an empty slot (a rate is never zero: the floor is above it).
    /// @param sends Sends recorded on the route; send `n` gets serial `n` (1-based), never reused.
    /// @param latest Serial of the route's latest send while it may still leave the window; zero once it left.
    /// @param expiredRate Highest rate among the expiries noted since the last send; zero when none is pending.
    /// @param next Ring slot the next send writes.
    struct Route {
        uint64[3] rates;
        uint64 sends;
        uint64 latest;
        uint64 expiredRate;
        uint8 next;
    }

    /// @notice The fee would reach the amount sent: nothing would arrive.
    error FeeNotBelowAmount(uint256 fee, uint256 amount);

    /// @notice Mean of the window's rates, each missing entry counted at `initialRate`, clamped to
    ///         [floorRate, capRate].
    function referenceRate(Route storage r, Params memory p) internal view returns (uint256) {
        uint256 sum;
        for (uint256 i; i < WINDOW; ++i) {
            uint256 rate = r.rates[i];
            sum += rate == 0 ? p.initialRate : rate;
        }
        return Math.min(Math.max(sum / WINDOW, p.floorRate), p.capRate);
    }

    /// @notice The rate the next send uses: one step above the highest expired rate when an expiry is pending, else
    ///         the reference.
    function nextRate(Route storage r, Params memory p) internal view returns (uint256) {
        uint256 expired = r.expiredRate;
        if (expired == 0) return referenceRate(r, p);
        return Math.min(Math.max(expired, p.floorRate) * (WAD + p.band) / WAD, p.capRate);
    }

    /// @notice `ceil(amount * rate) + fixedFee`; reverts `FeeNotBelowAmount` unless it stays below `amount`.
    function fee(uint256 amount, uint256 rate, uint256 fixedFee) internal pure returns (uint256 total) {
        total = Math.mulDiv(amount, rate, WAD, Math.Rounding.Ceil) + fixedFee;
        if (total >= amount) revert FeeNotBelowAmount(total, amount);
    }

    /// @notice Records a send's rate in the window and consumes a pending step.
    /// @return serial The send's 1-based number on the route, which `noteExpiry` needs.
    function record(Route storage r, uint256 rate) internal returns (uint64 serial) {
        uint8 slot = r.next;
        r.rates[slot] = SafeCast.toUint64(rate);
        r.next = uint8((slot + 1) % WINDOW);
        serial = r.sends + 1;
        r.sends = serial;
        r.latest = serial;
        r.expiredRate = 0;
    }

    /// @notice Notes that send `serial`, priced at `rate`, expired: the next send steps one band above the highest
    ///         expired rate, and the send leaves the window if it is still the route's latest (the window rewinds).
    function noteExpiry(Route storage r, uint64 serial, uint64 rate) internal {
        if (serial == r.latest) {
            uint8 slot = uint8((r.next + WINDOW - 1) % WINDOW);
            r.rates[slot] = 0;
            r.next = slot;
            r.latest = 0;
        }
        if (rate > r.expiredRate) r.expiredRate = rate;
    }
}
