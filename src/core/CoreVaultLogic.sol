// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {IValueReportReceiver} from "../interfaces/IValueReportReceiver.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {IManagerRegistry} from "../interfaces/IManagerRegistry.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {ITransitEscrow} from "../interfaces/ITransitEscrow.sol";
import {Transit, TransitState, TransferKind, BridgeQuote} from "../interfaces/FundTypes.sol";
import {SpokeConfig, BridgeAdapterConfig} from "../mandate/Mandate.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {IncomeAccumulator} from "../libraries/IncomeAccumulator.sol";
import {TransitMessage} from "../libraries/TransitMessage.sol";
import {CoreVaultState, CoreVaultWiring, SpokeBook, HubBoundTransfer} from "./CoreVaultTypes.sol";

/// @title CoreVaultLogic
/// @notice Value bases, collected income, report application, sends to spokes and transit outcomes of the Core
///         Vault, as an external library that runs in the Core Vault's context (DELEGATECALL into the fund's own linked
///         library, never into an adapter).
/// @dev Exists only to keep the Core Vault's runtime bytecode under the 24,576-byte limit without changing compiler
///      settings. The Core Vault applies access control, the reentrancy guard and the Operating Cash top-up before
///      calling in. Events are emitted with the Core Vault as their address; the library's own events and errors are
///      declared in ICoreVault, which the Core Vault implements, so they are in the Core Vault's ABI.
/// @dev Deployment (reported as an assumption): the operator deploys this library once per chain and links its
///      address into the Core Vault's creation code, whose hash the FundFactory pins, so the library address is part
///      of each fund's trust surface (immutable: no proxy, no upgrade path, DEC-022, DEC-058). ARCHITECTURE §6
///      forbids DELEGATECALL into adapters; this is the fund's own code, never an adapter (DEC-054).
library CoreVaultLogic {
    using SafeERC20 for IERC20;
    using IncomeAccumulator for IncomeAccumulator.State;

    /// @dev DEC-106: default protocol slice when the registry cannot be read.
    uint16 internal constant DEFAULT_PROTOCOL_SLICE_BPS = 5000;

    uint256 private constant BPS = 10_000;

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
    // Collected income (ruling 2026-09-29; DEC-092, DEC-106, DEC-107, DEC-109, DEC-110)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Splits income that reached the Core Vault and advances the index (ruling 2026-09-29: fee split and
    ///         attribution at collection).
    /// @dev DEC-107: performance fee = `amount * performanceFeeBps`, on income only, no high-water mark. DEC-106,
    ///      DEC-110: its protocol slice is read from the ManagerRegistry at this charge. DEC-109: both are paid in the
    ///      collected token at once, the slice to the Protocol Recipient and the rest of the fee to the ManagerFeeVault,
    ///      so no fee ever waits in the Core Vault. The net enters the shareholders' accumulator (DEC-014, Q60; with no
    ///      shares outstanding it is kept ownerless, LC-32) and the collected balance (LC-100). The caller checked the
    ///      token is an income token and that `amount` is held above the ledger (DEC-080). Rounding: the fee rounds
    ///      down (in the holders' favour), the slice rounds down (in the manager's favour).
    function collectIncome(CoreVaultState storage s, CoreVaultWiring memory w, address token, uint256 amount) public {
        _collectIncome(s, w, token, amount);
    }

    function _collectIncome(CoreVaultState storage s, CoreVaultWiring memory w, address token, uint256 amount) private {
        uint16 sliceBps = protocolSliceBps(w);
        uint256 managerFee = amount * s.performanceFeeBps / BPS;
        uint256 slice = managerFee * sliceBps / BPS;
        managerFee -= slice;
        uint256 net = amount - managerFee - slice;
        s.collectedIncome[token] += net;
        s.income.distribute(token, net, IERC20(w.shareToken).totalSupply());
        emit ICoreVault.CollectedIncomeReceived(token, amount, managerFee, slice, sliceBps);
        if (slice != 0) IERC20(token).safeTransfer(w.protocolRecipient, slice);
        if (managerFee != 0) IERC20(token).safeTransfer(w.managerFeeVault, managerFee);
    }

    /// @notice DEC-106, DEC-110: the registry is read at every charge. A failed read or a value above 100% never blocks
    ///         recognition (DEC-107 reading 3): the DEC-106 default of 50% applies; values are capped at 100%.
    function protocolSliceBps(CoreVaultWiring memory w) public view returns (uint16 bps) {
        try IManagerRegistry(w.managerRegistry).protocolSliceBps(w.manager) returns (uint16 value) {
            // forge-lint: disable-next-line(unsafe-typecast)
            bps = value > BPS ? uint16(BPS) : value;
        } catch {
            bps = DEFAULT_PROTOCOL_SLICE_BPS;
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Report application (DEC-066, DEC-080, DEC-090, Q60)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Applies a newly accepted report: confirms arrived transits and credits matched spoke-to-hub arrivals.
    ///         Never reverts because of an unknown or repeated transit id. The report's cumulative income counters are
    ///         informational (ruling 2026-09-29: spoke income is attributed only when it arrives as Income).
    function applyReport(CoreVaultState storage s, CoreVaultWiring memory w, uint256 spokeIndex) public {
        if (spokeIndex >= s.mandate.spokes.length) revert ICoreVault.UnknownSpoke(spokeIndex);
        (ReportCodec.Report memory r,,) = IValueReportReceiver(w.reportReceiver).latestReport(spokeIndex);
        if (r.fundId != w.fundId) revert ICoreVault.WrongFund(r.fundId);
        uint256 arrived = _confirmArrivals(s, spokeIndex, r.arrivedTransits, r.sequence);
        _matchReturnLeg(s, w, s.mandate.spokes[spokeIndex].chainId, r.inFlightToHub);
        emit ICoreVault.ReportAccepted(spokeIndex, r.sequence, r.blockNumber, r.timestamp, arrived);
    }

    /// @notice DEC-066, DEC-090: Sent or ExpiryAttested becomes ArrivalConfirmed when a report of the destination spoke
    ///         lists the id. The amount leaves In-flight Value because the report now carries it in the spoke's
    ///         balances. A RefundRecognized transit (its escrow held the full amount sent, DEC-063) that a report still
    ///         lists is confirmed too, without touching In-flight Value again: the escrow's amount was then a donation
    ///         already in Idle, and the arrival must not be deducted as unknown value (DEC-080).
    /// @dev OQ-09, OQ-01, DEC-080, DEC-104: an id is confirmed only when the listed amount reaches the transit's
    ///      `amountToArrive`. Across passes no depositor and transit ids are public (`SentToSpoke`), so a listing below
    ///      that amount may be a stranger's donation carrying a real id; confirming on id presence would release the
    ///      transit from In-flight Value and leave a later expiry refund stranded in its escrow. The spoke lists the
    ///      monotonic credited total per id, so a genuine arrival is never under-listed; a stranger who lists an id at
    ///      or above the amount has made the fund whole, and any excess is deducted as unknown-origin value.
    function _confirmArrivals(
        CoreVaultState storage s,
        uint256 spokeIndex,
        ReportCodec.TransitAmount[] memory list,
        uint64 sequence
    ) private returns (uint256 count) {
        SpokeBook storage book = s.spokeBooks[spokeIndex];
        for (uint256 i; i < list.length; ++i) {
            bytes32 id = list[i].transitId;
            Transit storage t = s.transits[id];
            TransitState state = t.state;
            if (state == TransitState.None || state == TransitState.ArrivalConfirmed) continue;
            if (s.transitSpoke[id] != spokeIndex) continue;
            if (list[i].amount < t.amountToArrive) continue;
            if (state == TransitState.Sent) book.inFlightSent -= t.amountSent;
            if (state != TransitState.RefundRecognized) book.inFlightToArrive -= t.amountToArrive;
            book.confirmedArrived += t.amountToArrive;
            t.state = TransitState.ArrivalConfirmed;
            ++count;
            emit ICoreVault.TransitArrived(id, spokeIndex, t.amountToArrive, sequence);
        }
    }

    /// @notice OQ-01, DEC-080: records the report's hub-bound transfers (amount and kind, first listing kept) and
    ///         credits whatever already arrived for them, up to the listed amount; anything above is held apart for
    ///         good.
    function _matchReturnLeg(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 originChainId,
        ReportCodec.HubBoundAmount[] memory list
    ) private {
        for (uint256 i; i < list.length; ++i) {
            bytes32 id = list[i].transitId;
            HubBoundTransfer storage h = s.hubBound[hubBoundKey(originChainId, id)];
            if (h.listed == 0) {
                h.listed = list[i].amount;
                h.kind = list[i].kind;
            }
            uint256 pending = h.pending;
            if (pending == 0) continue;
            h.pending = 0;
            s.unmatchedArrivals -= pending;
            _creditHubBound(s, w, h, id, originChainId, pending);
        }
    }

    /// @notice ICoreVault.handleV3AcrossMessage after the caller, token, amount and fund checks: holds the amount apart
    ///         until a report lists the transfer, else credits it against what the report listed (DEC-080, OQ-01).
    /// @dev `kind` is the Across message's claim; it is only logged for an unmatched arrival. Once listed, an arrival
    ///      is credited by the kind the report carries (CV-OQ-1), so a stranger's message cannot relabel income as
    ///      principal or the reverse.
    function receiveHubBound(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 originChainId,
        bytes32 transitId,
        TransferKind kind,
        uint256 amount
    ) public {
        HubBoundTransfer storage h = s.hubBound[hubBoundKey(originChainId, transitId)];
        if (h.listed == 0) {
            h.pending += amount;
            s.unmatchedArrivals += amount;
            emit ICoreVault.TransitReceived(transitId, originChainId, kind, amount, false);
            return;
        }
        _creditHubBound(s, w, h, transitId, originChainId, amount);
    }

    /// @notice Credits up to the listed amount not yet credited, by the listed kind: Principal to Idle; Income is
    ///         collected income that reached the Core Vault, split at once (ruling 2026-09-29, `collectIncome`); the
    ///         rest is held apart for good (DEC-080).
    function _creditHubBound(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        HubBoundTransfer storage h,
        bytes32 transitId,
        uint256 originChainId,
        uint256 amount
    ) private {
        TransferKind kind = h.kind;
        uint256 room = h.listed - h.credited;
        uint256 credit = amount < room ? amount : room;
        if (credit != 0) {
            h.credited += credit;
            emit ICoreVault.TransitReceived(transitId, originChainId, kind, credit, true);
            if (kind == TransferKind.Principal) s.idle += credit;
            else _collectIncome(s, w, w.usdc, credit);
        }
        if (amount > credit) {
            s.unmatchedArrivals += amount - credit;
            emit ICoreVault.ArrivalHeldApart(transitId, originChainId, kind, amount - credit);
        }
    }

    /// @notice DEC-066: non-arrival is proven by a spoke report built after the fill deadline that does not list the
    ///         transit, or by the deadline plus the spoke's report lifetime having passed.
    /// @dev OQ-09 (Spoke Vault and Core Vault verifier findings): the report lists only the last
    ///      `ReportCodec.ARRIVAL_WINDOW` arrivals, so its silence proves non-arrival only while it lists fewer than
    ///      that; a full window may have evicted the id (dust spam), and then only the deadline plus report lifetime
    ///      path applies. OQ-09, OQ-01: a listing below the transit's `amountToArrive` is not an arrival (see
    ///      `_confirmArrivals`), so a report built after the deadline that lists the id only below that amount proves
    ///      non-arrival as well: once the deadline has passed Across can no longer fill the deposit.
    function nonArrivalProvable(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        bytes32 transitId,
        uint32 deadline
    ) public view returns (bool) {
        if (block.timestamp > uint256(deadline) + s.mandate.spokes[spokeIndex].maxReportAge) {
            return true;
        }
        IValueReportReceiver receiver = IValueReportReceiver(w.reportReceiver);
        if (!receiver.hasReport(spokeIndex)) return false;
        (ReportCodec.Report memory r,,) = receiver.latestReport(spokeIndex);
        if (r.timestamp <= deadline || r.arrivedTransits.length >= ReportCodec.ARRIVAL_WINDOW) return false;
        uint256 expected = s.transits[transitId].amountToArrive;
        for (uint256 i; i < r.arrivedTransits.length; ++i) {
            if (r.arrivedTransits[i].transitId == transitId && r.arrivedTransits[i].amount >= expected) return false;
        }
        return true;
    }

    /// @notice Key of a spoke-to-hub transfer: transit ids are unique per sending vault, so the origin chain is part of
    ///         the key.
    function hubBoundKey(uint256 originChainId, bytes32 transitId) internal pure returns (bytes32) {
        return keccak256(abi.encode(originChainId, transitId));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Send to a spoke (DEC-037, DEC-066, DEC-085, DEC-087, DEC-088, DEC-095, QA19)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice ICoreVault.sendToSpoke after access control, the guard and the Operating Cash top-up.
    /// @dev DEC-087 and IBridgeAdapter custody: the vault fixes recipient, token pair, amounts and message; the adapter
    ///      only builds the call; the vault requires the pinned target, approves exactly the amount, makes a plain CALL
    ///      without value, requires the exact debit and resets the approval.
    function sendToSpoke(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        uint256 usdcAmount,
        uint256 bridgeRank,
        BridgeQuote calldata quote
    ) public returns (bytes32 transitId) {
        SpokeConfig memory spoke = s.mandate.spokes[spokeIndex];
        address adapter = _checkSend(s, w, spokeIndex, spoke.chainId, usdcAmount, bridgeRank, quote.outputAmount);

        transitId = keccak256(abi.encode(block.chainid, address(this), ++s.transitNonce));
        // DEC-066, QA6: a keyless per-send escrow is the depositor of record, so a refund is recognizable.
        address escrow = Clones.clone(w.escrowImplementation);
        ITransitEscrow(escrow).initialize(address(this), w.usdc);

        IBridgeAdapter.BridgeCall memory call =
            IBridgeAdapter(adapter).buildSend(_sendRequest(w, spoke, usdcAmount, quote, transitId), escrow);
        if (
            call.target != s.bridgeTarget[adapter] || call.amountToArrive != quote.outputAmount
                || call.fillDeadline <= block.timestamp
        ) revert ICoreVault.BridgeCallMismatch(adapter);

        // Effects: DEC-066 state Sent; Spoke Cap at the amount sent (C1); Share Assets at the amount to arrive (DEC-085).
        s.idle -= usdcAmount;
        SpokeBook storage book = s.spokeBooks[spokeIndex];
        book.inFlightSent += usdcAmount;
        book.inFlightToArrive += call.amountToArrive;
        Transit memory t = Transit({
            destinationChainId: spoke.chainId,
            bridgeAdapter: adapter,
            escrow: escrow,
            inputToken: w.usdc,
            outputToken: spoke.spokeToken,
            amountSent: usdcAmount,
            amountToArrive: call.amountToArrive,
            bridgeRef: call.transitRef,
            sentAt: uint64(block.timestamp),
            fillDeadline: call.fillDeadline,
            kind: TransferKind.Principal,
            state: TransitState.Sent
        });
        s.transits[transitId] = t;
        s.transitSpoke[transitId] = spokeIndex;
        emit ICoreVault.SentToSpoke(transitId, spokeIndex, t, w.hubChainId);

        // Interaction: IBridgeAdapter custody rule 3.
        IERC20 token = IERC20(w.usdc);
        uint256 before = token.balanceOf(address(this));
        token.forceApprove(call.target, usdcAmount);
        (bool ok, bytes memory ret) = call.target.call(call.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        uint256 debited = before - token.balanceOf(address(this));
        if (debited != usdcAmount) revert ICoreVault.BalanceChangeMismatch(usdcAmount, debited);
        token.forceApprove(call.target, 0);
    }

    /// @notice Checks of a send; returns the bridge adapter to use.
    function _checkSend(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        uint256 spokeChainId,
        uint256 usdcAmount,
        uint256 bridgeRank,
        uint256 outputAmount
    ) private view returns (address adapter) {
        // DEC-017, DEC-072: only Free Idle leaves the Core Vault.
        uint256 free = s.idle - s.payoutReserve;
        if (usdcAmount > free) revert ICoreVault.InsufficientFreeIdle(usdcAmount, free);

        // DEC-088: the Mandate's bridge adapter of that rank on the hub side; DEC-021, DEC-056, DEC-058: never a
        // paused or deprecated one for an entry toward a spoke.
        adapter = _hubBridgeAdapter(s, w.hubChainId, spokeChainId, bridgeRank);
        if (IBridgeAdapter(adapter).paused() || IBridgeAdapter(adapter).deprecated()) {
            revert ICoreVault.BridgeAdapterUnavailable(adapter);
        }
        if (adapter.codehash != s.bridgeCodehash[adapter]) revert ICoreVault.BridgeAdapterCodehashMismatch(adapter);

        // QA19: the quote's fee is at most maxBridgeFeeBps of the amount sent.
        uint256 maxFee = usdcAmount * w.maxBridgeFeeBps / BPS;
        uint256 fee = outputAmount < usdcAmount ? usdcAmount - outputAmount : 0;
        if (fee > maxFee) revert ICoreVault.BridgeFeeAboveMax(fee, maxFee);

        // DEC-037, DEC-095, DEC-066 B1/C1: spoke value + in flight (both legs) + amount <= Spoke Cap.
        (uint256 spokeValue, uint256 inFlightSent, uint256 inFlightToHub, uint256 cap) = spokeCapUsage(s, w, spokeIndex);
        uint256 used = spokeValue + inFlightSent + inFlightToHub;
        if (used + usdcAmount > cap) revert ICoreVault.SpokeCapExceeded(spokeIndex, used, usdcAmount, cap);
    }

    function _sendRequest(
        CoreVaultWiring memory w,
        SpokeConfig memory spoke,
        uint256 usdcAmount,
        BridgeQuote calldata quote,
        bytes32 transitId
    ) private pure returns (IBridgeAdapter.SendRequest memory) {
        return IBridgeAdapter.SendRequest({
            inputToken: w.usdc,
            outputToken: spoke.spokeToken,
            inputAmount: usdcAmount,
            outputAmount: quote.outputAmount,
            destinationChainId: spoke.chainId,
            recipient: spoke.spokeVault,
            quoteTimestamp: quote.quoteTimestamp,
            exclusivityDeadline: quote.exclusivityDeadline,
            exclusiveRelayer: quote.exclusiveRelayer,
            message: TransitMessage.encode(w.fundId, w.hubChainId, transitId, TransferKind.Principal)
        });
    }

    /// @notice DEC-088: the bridge adapter of priority `rank` serving `spokeChainId` from the hub.
    function _hubBridgeAdapter(CoreVaultState storage s, uint256 hubChainId, uint256 spokeChainId, uint256 rank)
        private
        view
        returns (address)
    {
        BridgeAdapterConfig[] storage list = s.mandate.bridgeAdapters;
        uint256 seen;
        for (uint256 i; i < list.length; ++i) {
            if (list[i].spokeChainId == spokeChainId && list[i].chainId == hubChainId) {
                if (seen == rank) return list[i].adapter;
                ++seen;
            }
        }
        revert ICoreVault.BridgeAdapterUnavailable(address(0));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Transit outcomes (DEC-066, DEC-090; QB11 / QB10 OPEN)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice ICoreVault.attestExpiry: Sent becomes ExpiryAttested after the fill deadline with proof of non-arrival;
    ///         the Spoke Cap is released while Share Assets keep counting the transit until its refund (DEC-066).
    function attestExpiry(CoreVaultState storage s, CoreVaultWiring memory w, bytes32 transitId) public {
        Transit storage t = _knownTransit(s, transitId);
        if (t.state != TransitState.Sent) revert ICoreVault.InvalidTransitState(transitId, uint8(t.state));
        uint32 deadline = t.fillDeadline;
        if (block.timestamp <= deadline) revert ICoreVault.FillDeadlineNotReached(transitId, deadline);
        uint256 spokeIndex = s.transitSpoke[transitId];
        if (!nonArrivalProvable(s, w, spokeIndex, transitId, deadline)) revert ICoreVault.ExpiryNotProvable(transitId);
        t.state = TransitState.ExpiryAttested;
        s.spokeBooks[spokeIndex].inFlightSent -= t.amountSent;
        emit ICoreVault.TransitExpiryAttested(transitId, spokeIndex, msg.sender);
    }

    /// @notice ICoreVault.recognizeRefund (DEC-066, QA6): pulls an attested-expired transit's refund from its escrow
    ///         back into Idle.
    /// @dev DEC-066, DEC-090: the only path is Sent -> ExpiryAttested -> RefundRecognized, so the non-arrival proof of
    ///      `attestExpiry` always comes first; a transit still Sent (possibly filled, its report not yet delivered) is
    ///      refused. DEC-063 (docs/DECISIONS.md, Across expired-deposit refund): Across refunds the full `inputAmount`
    ///      to the depositor, so an escrow holding less than `amountSent` holds no refund and nothing changes
    ///      (`NoRefund`). DEC-080, DEC-104: exactly `amountSent` enters Idle as the transit leaves In-flight Value;
    ///      anything above it (a donation) reaches the Core Vault unledgered and only `sweepExcess` moves it. A dust
    ///      donation therefore can neither move the state nor Share Assets.
    function recognizeRefund(CoreVaultState storage s, CoreVaultWiring memory w, bytes32 transitId)
        public
        returns (uint256 amount)
    {
        Transit storage t = _knownTransit(s, transitId);
        if (t.state != TransitState.ExpiryAttested) revert ICoreVault.InvalidTransitState(transitId, uint8(t.state));
        address escrow = t.escrow;
        IERC20 token = IERC20(w.usdc);
        uint256 held = token.balanceOf(escrow);
        amount = t.amountSent;
        if (held < amount) revert ICoreVault.NoRefund(transitId);
        uint256 spokeIndex = s.transitSpoke[transitId];
        // The Spoke Cap was released at the attested expiry; Share Assets release the transit now (QB11/QB10 stance).
        s.spokeBooks[spokeIndex].inFlightToArrive -= t.amountToArrive;
        t.state = TransitState.RefundRecognized;
        s.idle += amount;
        emit ICoreVault.TransitRefundRecognized(transitId, spokeIndex, amount);
        uint256 before = token.balanceOf(address(this));
        ITransitEscrow(escrow).release(address(this));
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != held) revert ICoreVault.BalanceChangeMismatch(held, received);
    }

    function _knownTransit(CoreVaultState storage s, bytes32 transitId) private view returns (Transit storage t) {
        t = s.transits[transitId];
        if (t.state == TransitState.None) revert ICoreVault.UnknownTransit(transitId);
    }
}
