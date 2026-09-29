// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
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
import {ICoreVaultExtensions as X} from "./ICoreVaultExtensions.sol";

/// @title CoreVaultLogic
/// @notice Value bases, income recognition, report application, sends to spokes and transit outcomes of the Core
///         Vault, as an external library that runs in the Core Vault's context (DELEGATECALL into the fund's own linked
///         library, never into an adapter).
/// @dev Exists only to keep the Core Vault's runtime bytecode under the 24,576-byte limit without changing compiler
///      settings. The Core Vault applies access control, the reentrancy guard and the Operating Cash top-up before
///      calling in. Events are emitted with the Core Vault as their address; the library's own events and errors are
///      declared in ICoreVaultExtensions, which the Core Vault inherits, so they are in the Core Vault's ABI.
/// @dev Deployment (reported as an assumption): the factory deploys this library once per chain and links its
///      address into the Core Vault's creation code, so the library address is part of every CREATE2 init code hash
///      and of each fund's trust surface (immutable: no proxy, no upgrade path, DEC-022, DEC-058). ARCHITECTURE §6
///      forbids DELEGATECALL into adapters; this is the fund's own code, never an adapter (DEC-054).
library CoreVaultLogic {
    using SafeERC20 for IERC20;
    using IncomeAccumulator for IncomeAccumulator.State;

    /// @dev Source id of the hub Spoke Vault in the accumulator (Q60 per-source counters).
    bytes32 internal constant HUB_INCOME_SOURCE = keccak256("HUB_SPOKE_VAULT");

    /// @dev DEC-106: default protocol slice when the registry cannot be read.
    uint16 internal constant DEFAULT_PROTOCOL_SLICE_BPS = 5000;

    uint256 private constant BPS = 10_000;

    // ---------------------------------------------------------------------------------------------------------------
    // Value bases (DEC-042, DEC-083, DEC-084, DEC-085, DEC-098, DEC-104)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Reads the hub Spoke Vault, recognizes its income (Q60, before any checkpoint) and returns Share Assets
    ///         with their consolidation (DEC-083). With `mint` true, stale reports and prices revert (Q57 reading).
    function recognizeAndValue(CoreVaultState storage s, CoreVaultWiring memory w, bool mint)
        public
        returns (uint256 assets, ICoreVault.NavConsolidation memory consolidation)
    {
        ReportCodec.Report memory hub = ISpokeVault(w.hubSpokeVault).buildReport();
        _recognizeHub(s, w, hub.cumulativeIncome);
        return _valuation(s, w, hub, mint);
    }

    /// @notice Share Assets and In-flight Value now, with the last prices and reports (never reverts on age).
    function shareAssets(CoreVaultState storage s, CoreVaultWiring memory w)
        public
        view
        returns (uint256 assets, uint256 inFlight)
    {
        ICoreVault.NavConsolidation memory consolidation;
        (assets, consolidation) = _valuation(s, w, ISpokeVault(w.hubSpokeVault).buildReport(), false);
        inFlight = consolidation.inFlightValue;
    }

    /// @notice DEC-098, DEC-103: Gross Assets, informational. Share Assets + Operating Cash + Attributed Income:
    ///         collected here, plus the hub Spoke Vault's collected bucket and uncollected position income, plus spoke
    ///         position income from the last reports. External rewards are 0 (no Collector in the MVP).
    function grossAssets(CoreVaultState storage s, CoreVaultWiring memory w) public view returns (uint256 total) {
        ReportCodec.Report memory hub = ISpokeVault(w.hubSpokeVault).buildReport();
        (total,) = _valuation(s, w, hub, false);
        total += s.operatingCash + _positionsIncome(w, hub);
        address[] memory tokens = s.income.tokens;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 held = s.collectedIncome[tokens[i]] + ISpokeVault(w.hubSpokeVault).collectedIncome(tokens[i]);
            total += _usdcValue(w, tokens[i], held, false);
        }
        IValueReportReceiver receiver = IValueReportReceiver(w.reportReceiver);
        for (uint256 i; i < s.mandate.spokes.length; ++i) {
            if (!receiver.hasReport(i)) continue;
            (ReportCodec.Report memory r,,) = receiver.latestReport(i);
            total += _positionsIncome(w, r);
        }
    }

    /// @notice Spoke Cap usage (DEC-037, DEC-066, DEC-095). `inFlightSent` includes both legs whose outcome is unknown:
    ///         hub-to-spoke sends still Sent, at the amount sent (C1), and the pending return leg the spoke reports in
    ///         `inFlightToHub` that the hub has not yet credited (B1).
    function spokeCapUsage(CoreVaultState storage s, CoreVaultWiring memory w, uint256 spokeIndex)
        public
        view
        returns (uint256 spokeValue, uint256 inFlightSent, uint256 spokeCap)
    {
        if (spokeIndex >= s.mandate.spokes.length) revert ICoreVault.UnknownSpoke(spokeIndex);
        SpokeConfig storage spoke = s.mandate.spokes[spokeIndex];
        inFlightSent = s.spokeBooks[spokeIndex].inFlightSent;
        IValueReportReceiver receiver = IValueReportReceiver(w.reportReceiver);
        if (receiver.hasReport(spokeIndex)) {
            (ReportCodec.Report memory r,,) = receiver.latestReport(spokeIndex);
            spokeValue = _spokePrincipal(s, w, spokeIndex, r, false);
            inFlightSent += _returnLeg(s, spoke.chainId, r);
        }
        spokeCap = spoke.spokeCap;
    }

    /// @notice Share Assets = Idle (Payout Reserve included) + hub Spoke Vault Unallocated Balance and position principal
    ///         + In-flight Value at the amount that will arrive + each spoke's principal and Unallocated Balance from its
    ///         last accepted report. Operating Cash, Attributed Income, unmatched arrivals and income are excluded
    ///         (DEC-013, DEC-078, DEC-080, DEC-092).
    /// @dev Q57 reading, OQ-10: with `mint` true a spoke report past its lifetime reverts with `StaleSpokeReport` and a
    ///      stale price with `StalePrice`; otherwise the last report and price are used and nothing reverts on age.
    function _valuation(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        ReportCodec.Report memory hubReport,
        bool mint
    ) private view returns (uint256 assets, ICoreVault.NavConsolidation memory consolidation) {
        assets = s.idle + _positionsPrincipal(w, hubReport, mint);
        uint256 n = s.mandate.spokes.length;
        consolidation.chainsSummed = 1;
        consolidation.reportBlockNumbers = new uint64[](n);
        consolidation.reportSequences = new uint64[](n);
        uint256 inFlight;
        IValueReportReceiver receiver = IValueReportReceiver(w.reportReceiver);
        for (uint256 i; i < n; ++i) {
            SpokeConfig storage spoke = s.mandate.spokes[i];
            inFlight += _usdcValue(w, spoke.spokeToken, s.spokeBooks[i].inFlightToArrive, mint);
            if (!receiver.hasReport(i)) continue;
            if (mint && !receiver.isReportFresh(i)) revert ICoreVault.StaleSpokeReport(i);
            (ReportCodec.Report memory r,,) = receiver.latestReport(i);
            assets += _spokePrincipal(s, w, i, r, mint);
            inFlight += _returnLeg(s, spoke.chainId, r);
            ++consolidation.chainsSummed;
            consolidation.reportBlockNumbers[i] = r.blockNumber;
            consolidation.reportSequences[i] = r.sequence;
            uint256 age = block.timestamp > r.timestamp ? block.timestamp - r.timestamp : 0;
            if (age > consolidation.oldestReportAge) consolidation.oldestReportAge = age;
        }
        consolidation.inFlightValue = inFlight;
        assets += inFlight;
    }

    /// @notice Unallocated Balance plus position principal of a report, in USDC (DEC-079: income excluded).
    function _positionsPrincipal(CoreVaultWiring memory w, ReportCodec.Report memory r, bool mint)
        private
        view
        returns (uint256 value)
    {
        for (uint256 i; i < r.unallocated.length; ++i) {
            value += _usdcValue(w, r.unallocated[i].token, r.unallocated[i].amount, mint);
        }
        for (uint256 i; i < r.positions.length; ++i) {
            ReportCodec.PositionReport memory p = r.positions[i];
            value += _usdcValue(w, p.token0, p.principal0, mint) + _usdcValue(w, p.token1, p.principal1, mint);
        }
    }

    function _positionsIncome(CoreVaultWiring memory w, ReportCodec.Report memory r)
        private
        view
        returns (uint256 value)
    {
        for (uint256 i; i < r.positions.length; ++i) {
            ReportCodec.PositionReport memory p = r.positions[i];
            value += _usdcValue(w, p.token0, p.income0, false) + _usdcValue(w, p.token1, p.income1, false);
        }
    }

    /// @notice A spoke's principal from its report, minus the arrivals it credited that the hub never sent.
    /// @dev DEC-080, OQ-01: `cumulativeReceived` above the amount of the transits the hub confirmed arrived is value of
    ///      unknown origin (a stranger's bridge deposit); it is priced in the spoke token and deducted, never below 0.
    function _spokePrincipal(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        ReportCodec.Report memory r,
        bool mint
    ) private view returns (uint256) {
        uint256 gross = _positionsPrincipal(w, r, mint);
        uint256 confirmed = s.spokeBooks[spokeIndex].confirmedArrived;
        if (r.cumulativeReceived <= confirmed) return gross;
        uint256 unknown = _usdcValue(w, s.mandate.spokes[spokeIndex].spokeToken, r.cumulativeReceived - confirmed, mint);
        return gross > unknown ? gross - unknown : 0;
    }

    /// @notice The pending return leg of a spoke: `inFlightToHub` entries of its last report not yet credited on the
    ///         hub, at the amount that will arrive in hub USDC (DEC-066 B1, DEC-085).
    /// @dev DEC-085, DEC-104: a Principal transfer home has left the spoke's Unallocated Balance and has not reached
    ///      Idle, so it must count here or it would sit outside every base. OPEN (raised in the module report as an
    ///      interface change): a ReportCodec.TransitAmount entry carries no TransferKind, so an Income transfer home is
    ///      counted here too until it arrives, against DEC-092 (collected income is outside Share Assets); the Share
    ///      Price is overstated by that amount during the transit and falls back at the fill. Counting every entry keeps
    ///      the Principal flow exact (the dominant one) and bounds the error to income in flight; once the report
    ///      carries the kind, only Principal entries count here while both keep counting toward the Spoke Cap (DEC-066
    ///      B1).
    function _returnLeg(CoreVaultState storage s, uint256 spokeChainId, ReportCodec.Report memory r)
        private
        view
        returns (uint256 value)
    {
        for (uint256 i; i < r.inFlightToHub.length; ++i) {
            uint256 amount = r.inFlightToHub[i].amount;
            uint256 credited = s.hubBound[hubBoundKey(spokeChainId, r.inFlightToHub[i].transitId)].credited;
            if (amount > credited) value += amount - credited;
        }
    }

    /// @notice USDC value of `amount` of `token`: USDC at face value, anything else through IPriceSource (OPEN, §5).
    /// @dev Q57 / OQ-10 reading: a mint reverts with `StalePrice` when the price is older than `maxPriceAge()`.
    function _usdcValue(CoreVaultWiring memory w, address token, uint256 amount, bool mint)
        private
        view
        returns (uint256 value)
    {
        if (amount == 0) return 0;
        if (token == w.usdc) return amount;
        uint256 updatedAt;
        (value, updatedAt) = IPriceSource(w.priceSource).usdcValue(token, amount);
        if (mint && updatedAt + IPriceSource(w.priceSource).maxPriceAge() < block.timestamp) {
            revert ICoreVault.StalePrice(token, updatedAt);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Income recognition (Q60, OQ-02 / OQ-03 stance, DEC-106, DEC-107, DEC-109, DEC-110)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Reads the hub Spoke Vault's counters and recognizes them. Never reverts (Q60).
    function recognizeHubIncome(CoreVaultState storage s, CoreVaultWiring memory w) public {
        try ISpokeVault(w.hubSpokeVault).buildReport() returns (ReportCodec.Report memory r) {
            _recognizeHub(s, w, r.cumulativeIncome);
        } catch {
            emit X.HubIncomeReadFailed();
        }
    }

    /// @notice Q60: advances the hub source counter per income token and books the delta. A regressed, anomalous or
    ///         unknown-token counter is skipped by the accumulator with an event, never reverted.
    function _recognizeHub(CoreVaultState storage s, CoreVaultWiring memory w, ReportCodec.TokenAmount[] memory list)
        private
    {
        uint256 supply = IERC20(w.shareToken).totalSupply();
        for (uint256 i; i < list.length; ++i) {
            uint256 delta = s.income.advanceSource(HUB_INCOME_SOURCE, list[i].token, list[i].amount);
            if (delta != 0) _bookIncome(s, w, HUB_INCOME_SOURCE, list[i].token, delta, supply);
        }
    }

    /// @notice Q60 stance for spoke income: on report acceptance each cumulative counter's delta, in the spoke token,
    ///         is priced into hub USDC through IPriceSource and recognized in the USDC index, because spoke income can
    ///         only come home as USDC through the Transport Route (DEC-031, DEC-055). Never reverts: a regressed or
    ///         anomalous counter is skipped; an unpriceable delta leaves the counter where it was.
    function _recognizeSpokeIncome(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        ReportCodec.TokenAmount[] memory list
    ) private {
        bytes32 source = keccak256(abi.encode("SPOKE", spokeIndex));
        uint256 supply = IERC20(w.shareToken).totalSupply();
        for (uint256 i; i < list.length; ++i) {
            address token = list[i].token;
            uint256 reported = list[i].amount;
            uint256 previous = s.spokeIncomeCounter[spokeIndex][token];
            if (reported == previous) continue;
            if (reported < previous || reported - previous > IncomeAccumulator.MAX_STEP) {
                emit X.SpokeIncomeCounterSkipped(spokeIndex, token, previous, reported);
                continue;
            }
            uint256 delta = reported - previous;
            try IPriceSource(w.priceSource).usdcValue(token, delta) returns (uint256 value, uint256) {
                if (value > IncomeAccumulator.MAX_STEP) {
                    emit X.SpokeIncomeCounterSkipped(spokeIndex, token, previous, reported);
                    continue;
                }
                s.spokeIncomeCounter[spokeIndex][token] = reported;
                emit X.SpokeIncomeRecognized(spokeIndex, token, delta, value);
                if (value != 0) _bookIncome(s, w, source, w.usdc, value, supply);
            } catch {
                emit X.SpokeIncomePriceUnavailable(spokeIndex, token, delta);
            }
        }
    }

    /// @notice DEC-107: the performance fee comes out of recognized income before it enters the shareholders'
    ///         accumulator; DEC-106, DEC-110: the protocol slice of that fee is read from the ManagerRegistry at this
    ///         charge. Both are booked as owed, in kind (DEC-109), and paid from the collected balance.
    function _bookIncome(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        bytes32 source,
        address token,
        uint256 delta,
        uint256 supply
    ) private {
        uint16 sliceBps = protocolSliceBps(w);
        uint256 managerFee = delta * s.performanceFeeBps / BPS;
        uint256 slice = managerFee * sliceBps / BPS;
        managerFee -= slice;
        s.managerOwed[token] += managerFee;
        s.protocolOwed[token] += slice;
        emit X.IncomeFeesBooked(source, token, delta, managerFee, slice, sliceBps);
        s.income.distribute(token, delta - managerFee - slice, supply);
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

    /// @notice Applies a newly accepted report: confirms arrived transits, credits matched spoke-to-hub arrivals and
    ///         recognizes spoke income. Never reverts because of income or of an unknown or repeated transit id.
    function applyReport(CoreVaultState storage s, CoreVaultWiring memory w, uint256 spokeIndex) public {
        if (spokeIndex >= s.mandate.spokes.length) revert ICoreVault.UnknownSpoke(spokeIndex);
        (ReportCodec.Report memory r,,) = IValueReportReceiver(w.reportReceiver).latestReport(spokeIndex);
        if (r.fundId != w.fundId) revert ICoreVault.WrongFund(r.fundId);
        uint256 arrived = _confirmArrivals(s, spokeIndex, r.arrivedTransits, r.sequence);
        _matchReturnLeg(s, w, s.mandate.spokes[spokeIndex].chainId, r.inFlightToHub);
        _recognizeSpokeIncome(s, w, spokeIndex, r.cumulativeIncome);
        emit ICoreVault.ReportAccepted(spokeIndex, r.sequence, r.blockNumber, r.timestamp, arrived);
    }

    /// @notice DEC-066, DEC-090: Sent or ExpiryAttested becomes ArrivalConfirmed when a report of the destination spoke
    ///         lists the id. The amount leaves In-flight Value because the report now carries it in the spoke's
    ///         balances. A RefundRecognized transit (its escrow held the full amount sent, DEC-063) that a report still
    ///         lists is confirmed too, without touching In-flight Value again: the escrow's amount was then a donation
    ///         already in Idle, and the arrival must not be deducted as unknown value (DEC-080).
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
            if (state == TransitState.Sent) book.inFlightSent -= t.amountSent;
            if (state != TransitState.RefundRecognized) book.inFlightToArrive -= t.amountToArrive;
            book.confirmedArrived += t.amountToArrive;
            t.state = TransitState.ArrivalConfirmed;
            ++count;
            emit ICoreVault.TransitArrived(id, spokeIndex, t.amountToArrive, sequence);
        }
    }

    /// @notice OQ-01, DEC-080: records the report's hub-bound transfers and credits whatever already arrived for them,
    ///         up to the listed amount; anything above is held apart for good.
    function _matchReturnLeg(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 originChainId,
        ReportCodec.TransitAmount[] memory list
    ) private {
        for (uint256 i; i < list.length; ++i) {
            bytes32 id = list[i].transitId;
            HubBoundTransfer storage h = s.hubBound[hubBoundKey(originChainId, id)];
            if (h.listed == 0) h.listed = list[i].amount;
            uint256 principal = h.pendingPrincipal;
            uint256 income = h.pendingIncome;
            if (principal == 0 && income == 0) continue;
            h.pendingPrincipal = 0;
            h.pendingIncome = 0;
            s.unmatchedArrivals -= principal + income;
            creditHubBound(s, w.usdc, h, id, originChainId, TransferKind.Principal, principal);
            creditHubBound(s, w.usdc, h, id, originChainId, TransferKind.Income, income);
        }
    }

    /// @notice Credits up to the listed amount not yet credited: Principal to Idle, Income to the USDC collected income
    ///         bucket with no second fee split (OQ-02/03); the rest is held apart for good (DEC-080).
    function creditHubBound(
        CoreVaultState storage s,
        address usdc,
        HubBoundTransfer storage h,
        bytes32 transitId,
        uint256 originChainId,
        TransferKind kind,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        uint256 room = h.listed - h.credited;
        uint256 credit = amount < room ? amount : room;
        if (credit != 0) {
            h.credited += credit;
            if (kind == TransferKind.Principal) s.idle += credit;
            else s.collectedIncome[usdc] += credit;
            emit ICoreVault.TransitReceived(transitId, originChainId, kind, credit, true);
        }
        if (amount > credit) {
            s.unmatchedArrivals += amount - credit;
            emit X.ArrivalHeldApart(transitId, originChainId, kind, amount - credit);
        }
    }

    /// @notice DEC-066: non-arrival is proven by a spoke report built after the fill deadline that does not list the
    ///         transit, or by the deadline plus the spoke's report lifetime having passed.
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
        if (r.timestamp <= deadline) return false;
        for (uint256 i; i < r.arrivedTransits.length; ++i) {
            if (r.arrivedTransits[i].transitId == transitId) return false;
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
        ) revert X.BridgeCallMismatch(adapter);

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
        if (debited != usdcAmount) revert X.BalanceChangeMismatch(usdcAmount, debited);
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
        if (adapter.codehash != s.bridgeCodehash[adapter]) revert X.BridgeAdapterCodehashMismatch(adapter);

        // QA19: the quote's fee is at most maxBridgeFeeBps of the amount sent.
        uint256 maxFee = usdcAmount * w.maxBridgeFeeBps / BPS;
        uint256 fee = outputAmount < usdcAmount ? usdcAmount - outputAmount : 0;
        if (fee > maxFee) revert ICoreVault.BridgeFeeAboveMax(fee, maxFee);

        // DEC-037, DEC-095, DEC-066 B1/C1: spoke value + in flight (both legs) + amount <= Spoke Cap.
        (uint256 spokeValue, uint256 inFlight, uint256 cap) = spokeCapUsage(s, w, spokeIndex);
        if (spokeValue + inFlight + usdcAmount > cap) {
            revert ICoreVault.SpokeCapExceeded(spokeIndex, spokeValue + inFlight, usdcAmount, cap);
        }
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
        if (received != held) revert X.BalanceChangeMismatch(held, received);
    }

    function _knownTransit(CoreVaultState storage s, bytes32 transitId) private view returns (Transit storage t) {
        t = s.transits[transitId];
        if (t.state == TransitState.None) revert ICoreVault.UnknownTransit(transitId);
    }
}
