// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {ICoreVaultIncome} from "../interfaces/ICoreVaultIncome.sol";
import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {IValueReportReceiver} from "../interfaces/IValueReportReceiver.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {TransferKind} from "../interfaces/FundTypes.sol";
import {SpokeConfig} from "../mandate/Mandate.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {CoreVaultState, CoreVaultWiring} from "./CoreVaultTypes.sol";

/// @title CoreVaultLogic
/// @notice Value bases of the Core Vault and the fee transfer helper, as an external library that runs in the Core
///         Vault's context (DELEGATECALL into the fund's own linked library, never into an adapter). Report
///         application, sends and transit outcomes live in `CoreVaultTransitLogic`, the income split in
///         `CoreVaultIncomeLogic` (DEC-131 pattern, D-43).
/// @dev Exists only to keep the Core Vault's runtime bytecode under the 24,576-byte limit without changing compiler
///      settings. The Core Vault applies access control, the reentrancy guard and the Operating Cash top-up before
///      calling in. Events are emitted with the Core Vault as their address; the library's own events and errors are
///      declared in ICoreVault (`FeeAccrued` in ICoreVaultIncome, which ICoreVault inherits), which the Core Vault
///      implements, so they are in the Core Vault's ABI.
/// @dev Deployment (reported as an assumption): the operator deploys this library once per chain and links its
///      address into the Core Vault's creation code, whose hash the FundFactory pins, so the library address is part
///      of each fund's trust surface (immutable: no proxy, no upgrade path, DEC-022, DEC-058). ARCHITECTURE §6
///      forbids DELEGATECALL into adapters; this is the fund's own code, never an adapter (DEC-054).
library CoreVaultLogic {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------------------------
    // Value bases (DEC-042, DEC-083, DEC-084, DEC-085, DEC-098, DEC-104)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Valuation modes. VIEW: a failing dependency reverts, age is ignored. MINT: a failing dependency reverts and
    ///      so does a stale report or price (Q57 reading, OQ-10). PAYOUT: nothing reverts on age (OQ-10) nor on a
    ///      failing dependency (payout liveness, DEC-021, DEC-056): the last known value is used with an event.
    uint8 private constant VIEW = 0;
    uint8 private constant MINT = 1;
    uint8 private constant PAYOUT = 2;

    /// @dev Prices read by one valuation (price1e18 per token), each token read once; `fellBack` marks a PAYOUT read
    ///      that failed and used `CoreVaultState.lastPrice`.
    struct Prices {
        uint8 mode;
        uint256 n;
        bool anyFallback;
        address[] tokens;
        uint256[] values;
        bool[] fellBack;
    }

    /// @notice Share Assets with their consolidation (DEC-083), for a view: a failing dependency reverts, age is
    ///         ignored. Income is never recognized here (ruling 2026-09-29: the index advances only at collection).
    function valuation(CoreVaultState storage s, CoreVaultWiring memory w)
        public
        view
        returns (uint256 assets, ICoreVault.NavConsolidation memory consolidation)
    {
        (assets, consolidation,,) = _valuation(s, w, _newPrices(VIEW));
    }

    /// @notice Share Assets for a mint (`mint` true) or a payout (`mint` false), keeping the last known valuation.
    /// @dev Mint (Q57 reading, OQ-10): every dependency must answer, reports and prices must be fresh, else the mint
    ///      reverts (`StaleSpokeReport`, `StalePrice`, or the dependency's own error). Payout (payout liveness, DEC-021
    ///      "investor exit is unblockable", DEC-056; Core Vault verifier finding): the hub Spoke Vault's report read and
    ///      every IPriceSource read are wrapped; a failure falls back to the last successfully computed value kept in
    ///      storage (`lastHubValue`, `lastPrice` per token), emitting `HubValuationFallback` or `PriceFallback`, so a
    ///      claim never reverts because a valuation dependency fails. A token never priced before falls back to 0
    ///      (only reachable for a token that appeared after the last deposit or payout). The last known values are
    ///      refreshed on every successful deposit or payout: prices that answered, and the hub value when the hub read
    ///      and all its prices answered. Between two valuations the last hub value follows the exact USDC moves between
    ///      Idle and the hub Spoke Vault (`allocateToHubSpokeVault` adds, `returnToIdle` subtracts, floored at 0), so
    ///      the fallback is the last read adjusted by those moves and never counts a returned amount in Idle and in
    ///      the hub value at once (consolidation verifier finding); market moves since the last read are not seen. Remote spokes need no value fallback: their last accepted report is kept by
    ///      the fund's own ValueReportReceiver and only their prices can fail.
    function recordValuation(CoreVaultState storage s, CoreVaultWiring memory w, bool mint)
        public
        returns (uint256 assets, ICoreVault.NavConsolidation memory consolidation)
    {
        Prices memory p = _newPrices(mint ? MINT : PAYOUT);
        uint256 hubValue;
        bool hubRead;
        (assets, consolidation, hubValue, hubRead) = _valuation(s, w, p);
        if (!hubRead) emit ICoreVault.HubValuationFallback(hubValue);
        else if (!p.anyFallback) s.lastHubValue = hubValue;
        for (uint256 i; i < p.n; ++i) {
            if (p.fellBack[i]) emit ICoreVault.PriceFallback(p.tokens[i], p.values[i]);
            else s.lastPrice[p.tokens[i]] = p.values[i];
        }
    }

    /// @notice Share Assets and In-flight Value now, with the last prices and reports (never reverts on age).
    function shareAssets(CoreVaultState storage s, CoreVaultWiring memory w)
        public
        view
        returns (uint256 assets, uint256 inFlight)
    {
        ICoreVault.NavConsolidation memory consolidation;
        (assets, consolidation,,) = _valuation(s, w, _newPrices(VIEW));
        inFlight = consolidation.inFlightValue;
    }

    /// @notice DEC-098, DEC-103: Gross Assets, informational. Share Assets + Operating Cash + Attributed Income:
    ///         collected here, plus the hub Spoke Vault's collected bucket and uncollected position income, plus each
    ///         spoke's uncollected position income, collected income bucket and Operating Cash from its last report.
    ///         External rewards are 0 (no Collector in the MVP).
    function grossAssets(CoreVaultState storage s, CoreVaultWiring memory w) public view returns (uint256 total) {
        Prices memory p = _newPrices(VIEW);
        (total,,,) = _valuation(s, w, p);
        total += s.operatingCash + _positionsIncome(s, w, p, ISpokeVault(w.hubSpokeVault).buildReport());
        address[] memory tokens = s.income.tokens;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 held = s.collectedIncome[tokens[i]] + ISpokeVault(w.hubSpokeVault).collectedIncome(tokens[i]);
            total += _usdcValue(s, w, p, tokens[i], held);
        }
        IValueReportReceiver receiver = IValueReportReceiver(w.reportReceiver);
        for (uint256 i; i < s.mandate.spokes.length; ++i) {
            if (!receiver.hasReport(i)) continue;
            (ReportCodec.Report memory r,,) = receiver.latestReport(i);
            total += _positionsIncome(s, w, p, r) + _usdcValue(s, w, p, s.mandate.spokes[i].spokeToken, r.operatingCash);
            for (uint256 j; j < r.collectedIncome.length; ++j) {
                total += _usdcValue(s, w, p, r.collectedIncome[j].token, r.collectedIncome[j].amount);
            }
        }
    }

    /// @notice Spoke Cap usage (DEC-037, DEC-066, DEC-095): both legs whose outcome is unknown count, hub-to-spoke
    ///         sends still Sent at the amount sent (`inFlightSent`, C1) and the pending return leg the spoke reports in
    ///         `inFlightToHub` that the hub has not yet credited, Principal and Income alike (`inFlightToHub`, B1).
    function spokeCapUsage(CoreVaultState storage s, CoreVaultWiring memory w, uint256 spokeIndex)
        public
        view
        returns (uint256 spokeValue, uint256 inFlightSent, uint256 inFlightToHub, uint256 spokeCap)
    {
        if (spokeIndex >= s.mandate.spokes.length) revert ICoreVault.UnknownSpoke(spokeIndex);
        SpokeConfig storage spoke = s.mandate.spokes[spokeIndex];
        inFlightSent = s.spokeBooks[spokeIndex].inFlightSent;
        IValueReportReceiver receiver = IValueReportReceiver(w.reportReceiver);
        if (receiver.hasReport(spokeIndex)) {
            (ReportCodec.Report memory r,,) = receiver.latestReport(spokeIndex);
            (spokeValue,) = _spokePrincipal(s, w, _newPrices(VIEW), spokeIndex, r);
            inFlightToHub = _returnLeg(s, spoke.chainId, r, false);
        }
        spokeCap = spoke.spokeCap;
    }

    /// @notice Share Assets = Idle (Payout Reserve included) + hub Spoke Vault Unallocated Balance and position principal
    ///         + In-flight Value at the amount that will arrive + each spoke's principal and Unallocated Balance from its
    ///         last accepted report. Operating Cash, Attributed Income, unmatched arrivals and income are excluded
    ///         (DEC-013, DEC-078, DEC-080, DEC-092).
    /// @dev Q57 reading, OQ-10: in MINT mode a spoke report past its lifetime reverts with `StaleSpokeReport` and a stale
    ///      price with `StalePrice`; otherwise the last report and price are used and nothing reverts on age.
    ///      DEC-080, DEC-104, OQ-09 (consolidation verifier finding): value of unknown origin a spoke credited is
    ///      deducted from the fund total, not clamped per spoke. A spoke whose principal no longer covers it (the
    ///      manager sent it home, or it went into a position) passes the shortfall here, where it is deducted from
    ///      wherever that value now sits (Idle, the return leg); only the total is floored at 0. This is what keeps a
    ///      hub-to-spoke transit the hub never confirmed (still in In-flight Value) counted once.
    function _valuation(CoreVaultState storage s, CoreVaultWiring memory w, Prices memory p)
        private
        view
        returns (uint256 assets, ICoreVault.NavConsolidation memory consolidation, uint256 hubValue, bool hubRead)
    {
        (hubValue, hubRead) = _hubValue(s, w, p);
        uint256 n = s.mandate.spokes.length;
        consolidation.chainsSummed = 1;
        consolidation.reportBlockNumbers = new uint64[](n);
        consolidation.reportSequences = new uint64[](n);
        uint256 shortfall;
        for (uint256 i; i < n; ++i) {
            (uint256 principal, uint256 spokeShortfall) = _spokeValue(s, w, p, i, consolidation);
            assets += principal;
            shortfall += spokeShortfall;
        }
        assets += s.idle + hubValue + consolidation.inFlightValue;
        assets = assets > shortfall ? assets - shortfall : 0;
    }

    /// @notice One spoke's principal from its last accepted report and the unknown-origin value its principal does not
    ///         cover (`shortfall`, see `_spokePrincipal`); adds its In-flight Value (both legs, DEC-085) and its report's
    ///         consolidation fields (DEC-083) to `consolidation`.
    function _spokeValue(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        Prices memory p,
        uint256 spokeIndex,
        ICoreVault.NavConsolidation memory consolidation
    ) private view returns (uint256 principal, uint256 shortfall) {
        SpokeConfig storage spoke = s.mandate.spokes[spokeIndex];
        consolidation.inFlightValue += _usdcValue(s, w, p, spoke.spokeToken, s.spokeBooks[spokeIndex].inFlightToArrive);
        IValueReportReceiver receiver = IValueReportReceiver(w.reportReceiver);
        if (!receiver.hasReport(spokeIndex)) return (0, 0);
        if (p.mode == MINT && !receiver.isReportFresh(spokeIndex)) revert ICoreVault.StaleSpokeReport(spokeIndex);
        (ReportCodec.Report memory r,,) = receiver.latestReport(spokeIndex);
        (principal, shortfall) = _spokePrincipal(s, w, p, spokeIndex, r);
        consolidation.inFlightValue += _returnLeg(s, spoke.chainId, r, true);
        ++consolidation.chainsSummed;
        consolidation.reportBlockNumbers[spokeIndex] = r.blockNumber;
        consolidation.reportSequences[spokeIndex] = r.sequence;
        uint256 age = block.timestamp > r.timestamp ? block.timestamp - r.timestamp : 0;
        if (age > consolidation.oldestReportAge) consolidation.oldestReportAge = age;
    }

    /// @notice The hub Spoke Vault's Unallocated Balance plus position principal, in USDC (same chain, read directly).
    /// @dev PAYOUT mode: a failing `buildReport` (a hub adapter's `positionValue` reverting, for instance) returns the
    ///      last known value with `read` false.
    function _hubValue(CoreVaultState storage s, CoreVaultWiring memory w, Prices memory p)
        private
        view
        returns (uint256 value, bool read)
    {
        if (p.mode != PAYOUT) {
            return (_positionsPrincipal(s, w, p, ISpokeVault(w.hubSpokeVault).buildReport()), true);
        }
        try ISpokeVault(w.hubSpokeVault).buildReport() returns (ReportCodec.Report memory r) {
            return (_positionsPrincipal(s, w, p, r), true);
        } catch {
            return (s.lastHubValue, false);
        }
    }

    /// @notice Unallocated Balance plus position principal of a report, in USDC (DEC-079: income excluded).
    /// @dev Security review S-1 (DEC-067 "guarded pool price", Q57 (b) alternative 2): a price-dependent position is
    ///      valued from its liquidity and range at the price the price source gives, never from the token amounts at
    ///      the pool's spot price (`_oracleComposition`).
    function _positionsPrincipal(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        Prices memory p,
        ReportCodec.Report memory r
    ) private view returns (uint256 value) {
        for (uint256 i; i < r.unallocated.length; ++i) {
            value += _usdcValue(s, w, p, r.unallocated[i].token, r.unallocated[i].amount);
        }
        for (uint256 i; i < r.positions.length; ++i) {
            ReportCodec.PositionReport memory pos = r.positions[i];
            (uint256 amount0, uint256 amount1) = _oracleComposition(s, w, p, pos);
            value += _usdcValue(s, w, p, pos.token0, amount0) + _usdcValue(s, w, p, pos.token1, amount1);
        }
    }

    /// @notice The token amounts a concentrated-liquidity position holds at the price-source price.
    /// @dev Security review S-1: the amounts a range position holds at pool price P, valued at an outside price P*,
    ///      are worth the least at P = P* (dV/dP = x'(P) (P* - P), x' < 0), so taking them at a spot price anyone can
    ///      move within a transaction (a Uniswap V4 `slot0` read by `positionValue`, on the hub inside `claimPayout`,
    ///      on a spoke inside the permissionless `report()`) and pricing them at the oracle only ever overstates Share
    ///      Assets. The position is recomputed instead from its `liquidity`, `tickLower` and `tickUpper` (which a price
    ///      move does not change) at sqrtPriceX96 = sqrt(price(token0) / price(token1)) * 2^96, with the pool's own
    ///      formulas (`SqrtPriceMath`, rounded down as on removal). A single-token or exact-value position (Aave V3:
    ///      `token1 == address(0)`, ticks 0) keeps its reported principal, which no pool price moves; so does a position
    ///      whose token was never priced in a PAYOUT fallback (value 0, CS-OQ-4).
    function _oracleComposition(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        Prices memory p,
        ReportCodec.PositionReport memory pos
    ) private view returns (uint256 amount0, uint256 amount1) {
        if (pos.token1 == address(0) || pos.tickLower >= pos.tickUpper || pos.liquidity == 0) {
            return (pos.principal0, pos.principal1);
        }
        uint256 price0 = _unitPrice(s, w, p, pos.token0);
        uint256 price1 = _unitPrice(s, w, p, pos.token1);
        if (price0 == 0 || price1 == 0) return (pos.principal0, pos.principal1);
        // price(token1 per token0) in Q96 under the root, then shifted to Q96: sqrt(r * 2^96) * 2^48 = sqrt(r) * 2^96.
        uint256 sqrtPrice = Math.sqrt(Math.mulDiv(price0, 1 << 96, price1)) << 48;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(pos.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(pos.tickUpper);
        if (sqrtPrice <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, pos.liquidity, false);
        } else if (sqrtPrice < sqrtUpper) {
            // casting to 'uint160' is safe because sqrtPrice < sqrtUpper, a uint160
            // forge-lint: disable-next-line(unsafe-typecast)
            uint160 sqrtP = uint160(sqrtPrice);
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtUpper, pos.liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtP, pos.liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, pos.liquidity, false);
        }
    }

    /// @notice price1e18 of `token` for this valuation; USDC is 1e18 by definition (IPriceSource scale).
    function _unitPrice(CoreVaultState storage s, CoreVaultWiring memory w, Prices memory p, address token)
        private
        view
        returns (uint256)
    {
        return token == w.usdc ? 1e18 : _price(s, w, p, token);
    }

    function _positionsIncome(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        Prices memory p,
        ReportCodec.Report memory r
    ) private view returns (uint256 value) {
        for (uint256 i; i < r.positions.length; ++i) {
            ReportCodec.PositionReport memory pos = r.positions[i];
            value += _usdcValue(s, w, p, pos.token0, pos.income0) + _usdcValue(s, w, p, pos.token1, pos.income1);
        }
    }

    /// @notice A spoke's principal from its report, minus the arrivals it credited that the hub never confirmed.
    /// @dev DEC-080, OQ-01: `cumulativeReceived` above the amount of the transits the hub confirmed arrived is value of
    ///      unknown origin (a stranger's bridge deposit, or a hub-to-spoke transit whose arrival no accepted report
    ///      listed: evicted from the arrival window or below its listing minimum, OQ-09, CS-OQ-6); it is priced in the
    ///      spoke token and deducted. When the spoke's gross principal does not cover it, `principal` is 0 and the rest
    ///      is returned as `shortfall` for `_valuation` to deduct from the fund total (DEC-104: the value left the
    ///      spoke, most likely home to Idle, and must not be counted there on top of an unconfirmed transit's
    ///      In-flight Value). Tradeoff: the deduction stays at the amount received, priced now, so a market loss the
    ///      spoke takes on unknown-origin funds lowers Share Assets.
    function _spokePrincipal(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        Prices memory p,
        uint256 spokeIndex,
        ReportCodec.Report memory r
    ) private view returns (uint256 principal, uint256 shortfall) {
        uint256 gross = _positionsPrincipal(s, w, p, r);
        uint256 confirmed = s.spokeBooks[spokeIndex].confirmedArrived;
        if (r.cumulativeReceived <= confirmed) return (gross, 0);
        uint256 unknown = _usdcValue(s, w, p, s.mandate.spokes[spokeIndex].spokeToken, r.cumulativeReceived - confirmed);
        if (gross > unknown) return (gross - unknown, 0);
        return (0, unknown - gross);
    }

    /// @notice The pending return leg of a spoke: `inFlightToHub` entries of its last report not yet credited on the
    ///         hub, at the amount that will arrive in hub USDC (DEC-066 B1, DEC-085).
    /// @dev DEC-085, DEC-104: a Principal transfer home has left the spoke's Unallocated Balance and has not reached
    ///      Idle, so it counts in Share Assets while in flight. DEC-092: an Income transfer home is collected income,
    ///      outside Share Assets, so with `principalOnly` (Share Assets) it is left out; without it (Spoke Cap, DEC-066
    ///      B1) both kinds count. The kind comes from the report (ReportCodec version 2, CV-OQ-1).
    function _returnLeg(CoreVaultState storage s, uint256 spokeChainId, ReportCodec.Report memory r, bool principalOnly)
        private
        view
        returns (uint256 value)
    {
        for (uint256 i; i < r.inFlightToHub.length; ++i) {
            if (principalOnly && r.inFlightToHub[i].kind != TransferKind.Principal) continue;
            uint256 amount = r.inFlightToHub[i].amount;
            uint256 credited = s.hubBound[hubBoundKey(spokeChainId, r.inFlightToHub[i].transitId)].credited;
            if (amount > credited) value += amount - credited;
        }
    }

    /// @notice USDC value of `amount` of `token`: USDC at face value, anything else through IPriceSource (OPEN, §5),
    ///         `amount * price1e18 / 1e18` rounded down.
    function _usdcValue(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        Prices memory p,
        address token,
        uint256 amount
    ) private view returns (uint256) {
        if (amount == 0) return 0;
        if (token == w.usdc) return amount;
        return Math.mulDiv(amount, _price(s, w, p, token), 1e18);
    }

    /// @notice Price of `token` for this valuation, read once.
    /// @dev MINT (Q57 / OQ-10 reading): reverts with `StalePrice` when the price is older than the token's own bound
    ///      (`IPriceSource.maxPriceAge(token)`).
    ///      PAYOUT: a reverting source falls back to `lastPrice[token]` (payout liveness); never checks age (OQ-10).
    function _price(CoreVaultState storage s, CoreVaultWiring memory w, Prices memory p, address token)
        private
        view
        returns (uint256 price)
    {
        for (uint256 i; i < p.n; ++i) {
            if (p.tokens[i] == token) return p.values[i];
        }
        bool fellBack;
        if (p.mode == PAYOUT) {
            try IPriceSource(w.priceSource).priceInUsdc(token) returns (uint256 value, uint256) {
                price = value;
            } catch {
                (price, fellBack) = (s.lastPrice[token], true);
                p.anyFallback = true;
            }
        } else {
            uint256 updatedAt;
            (price, updatedAt) = IPriceSource(w.priceSource).priceInUsdc(token);
            if (p.mode == MINT && updatedAt + IPriceSource(w.priceSource).maxPriceAge(token) < block.timestamp) {
                revert ICoreVault.StalePrice(token, updatedAt);
            }
        }
        if (p.n == p.tokens.length) _grow(p);
        (p.tokens[p.n], p.values[p.n], p.fellBack[p.n]) = (token, price, fellBack);
        ++p.n;
    }

    function _newPrices(uint8 mode) private pure returns (Prices memory p) {
        p.mode = mode;
        p.tokens = new address[](4);
        p.values = new uint256[](4);
        p.fellBack = new bool[](4);
    }

    function _grow(Prices memory p) private pure {
        uint256 size = p.tokens.length * 2;
        address[] memory tokens = new address[](size);
        uint256[] memory values = new uint256[](size);
        bool[] memory fellBack = new bool[](size);
        for (uint256 i; i < p.n; ++i) {
            (tokens[i], values[i], fellBack[i]) = (p.tokens[i], p.values[i], p.fellBack[i]);
        }
        (p.tokens, p.values, p.fellBack) = (tokens, values, fellBack);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fees (security review S-12)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Transfers a fee to its recipient, or books it as owed when the transfer fails.
    /// @dev Security review S-12: the Protocol Recipient and the ManagerFeeVault are immutable third-party addresses on
    ///      the path of every deposit, claim, income collection and report delivery. A USDC blocklist entry on either
    ///      (FiatToken reverts a transfer to a blacklisted address) or a reverting recipient must not freeze the fund:
    ///      the fee stays in the Core Vault, outside every value base and inside the ledger, until `claimOwedFees`.
    function payFee(CoreVaultState storage s, address token, address recipient, uint256 amount) internal {
        if (amount == 0 || IERC20(token).trySafeTransfer(recipient, amount)) return;
        s.owedFees[token][recipient] += amount;
        s.owedFeesTotal[token] += amount;
        emit ICoreVaultIncome.FeeAccrued(token, recipient, amount);
    }

    /// @notice Key of a spoke-to-hub transfer: transit ids are unique per sending vault, so the origin chain is part of
    ///         the key.
    function hubBoundKey(uint256 originChainId, bytes32 transitId) internal pure returns (bytes32) {
        return keccak256(abi.encode(originChainId, transitId));
    }
}
