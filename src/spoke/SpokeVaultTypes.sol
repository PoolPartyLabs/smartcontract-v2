// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {Transit} from "../interfaces/FundTypes.sol";
import {OrderVerifier} from "../libraries/OrderVerifier.sol";
import {SpokeIncomeTypes} from "./SpokeIncomeTypes.sol";
import {SpokeUnwindTypes} from "./SpokeUnwindTypes.sol";

/// @title SpokeVaultTypes
/// @notice Storage layout and wiring of the Spoke Vault, shared by `SpokeVault` and its linked libraries, plus the
///         errors the Spoke Vault raises beyond ISpokeVault. The unwind's caller-encoded hints and errors are in
///         `SpokeUnwindTypes`.
library SpokeVaultTypes {
    /// @notice OQ-09 stance: the report carries the ids of the last 256 listed hub-to-spoke arrivals.
    /// @dev Must equal `ReportCodec.ARRIVAL_WINDOW`, which the hub reads (a literal here because it sizes a storage
    ///      array); a unit test pins the equality.
    uint256 internal constant ARRIVAL_WINDOW = 256;

    /// @notice Smallest credited total, in base token units, for which an arrival id is listed in the report: 1e6
    ///         (1 USDG on Robinhood Chain).
    /// @dev Spoke Vault verifier finding (dust eviction of the window). OQ-09 stance: the window serves liveness; value
    ///      rests on the hub's ledger, not on the window. Across passes no depositor, so anyone can reach
    ///      `handleV3AcrossMessage`; a smaller arrival is still credited to the ledger and to `cumulativeReceived`, but
    ///      not listed, so flushing the window costs at least `ARRIVAL_WINDOW` of these units instead of gas only. A
    ///      hub-to-spoke transit whose id is evicted before an accepted report lists it (or that is below this
    ///      minimum, CS-OQ-6) is never confirmed: it stays in the hub's In-flight Value for good, while the hub deducts
    ///      `cumulativeReceived` above what it confirmed as value of unknown origin (DEC-080, OQ-01). The two cancel
    ///      only because that deduction is taken from the fund total, not clamped per spoke, so it follows the value
    ///      when the spoke sends it home (`CoreVaultLogic._valuation`, consolidation verifier finding); the cost of a
    ///      flush is liveness (the transit keeps its Spoke Cap). The hub also refuses a full window as proof of
    ///      non-arrival (`CoreVaultTransitLogic.nonArrivalProvable`). Only Principal arrivals are counted per id and
    ///      listed, at their monotonic credited total, and the hub confirms an id only when that total reaches the
    ///      amount it expects to arrive, so a stranger listing a real id below it cannot confirm the transit (OQ-01,
    ///      OQ-09, consolidation verifier round 2).
    uint256 internal constant MIN_LISTED_ARRIVAL = 1e6;

    /// @notice Most sends home a Spoke Vault lists in `inFlightToHub` at once; `sendToHub` reverts above it.
    /// @dev Security review S-11: every send home adds an entry that `report()` walks and encodes, and the hub stores
    ///      and walks on every delivery, until its refund is recognized or `ReportCodec.HUB_BOUND_RETENTION` has
    ///      passed. Without a bound a few thousand dust sends made `report()` exceed the block gas limit for good. At
    ///      64 entries a report stays within a few million gas; the manager can still send home 64 times per retention
    ///      period (about 20 a day). OPEN value (security review parameter, to confirm with the founder).
    uint256 internal constant MAX_HUB_BOUND_IN_FLIGHT = 64;

    /// @notice Most positions a Spoke Vault holds open at once; `openPosition` reverts above it.
    /// @dev Independent review H-04 (security review S-11 residual): every open position is walked and encoded by
    ///      `report()` and `buildReport()`, stored by the hub on every delivery (about 0.2M gas each through the real
    ///      Wormhole Core) and visited by the automatic unwind. Unbounded, about 145 to 180 dust positions pushed a
    ///      delivery past Arbitrum's 32M gas per transaction, which froze the hub's view of the spoke, and about 110
    ///      exhausted an unwind. Measured through the real Cores (cross-check port), a full arrival window, 64 Income
    ///      sends home filled before their listing and 32 positions needed 30.28M, too close to the limit with the L1
    ///      data component left out; 16 positions take about 3.3M off that. OPEN value.
    uint256 internal constant MAX_OPEN_POSITIONS = 16;

    /// @notice Tokens of a Mandate pool on this chain, as the adapter's `poolTokens` returned them at creation
    ///         (OQ-12: a hooked Uniswap V4 pool makes that call revert, so it can never be listed).
    struct PoolTokens {
        address token0;
        address token1;
        bool listed;
    }

    /// @notice Which exit verb an internal exit runs (DEC-056: exit verbs are never gated by pause or deprecation).
    enum ExitKind {
        Decrease,
        Close,
        Collect
    }

    /// @notice Immutable wiring the cross-chain library needs, rebuilt in memory from the vault's immutables.
    struct Config {
        bytes32 fundId;
        bytes32 mandateHash;
        uint256 chainId;
        uint256 hubChainId;
        address coreVault;
        address baseToken;
        address hubChainUsdc;
        address transitEscrowImplementation;
        uint32 maxReportAge;
    }

    /// @notice Every mutable and pinned value of a Spoke Vault.
    /// @dev Chain-local Mandate copy pinned at creation (DEC-030, DEC-053, DEC-087, DEC-088, DEC-136, Q17-4), the
    ///      internal ledger (DEC-080), Operating Cash (DEC-096), the cross-chain books (DEC-066, DEC-090, OQ-09), the
    ///      unwind and income books (WP-07 D1: each grows only in its own types file) and the order cursor
    ///      (DEC-093, DEC-120: written only by `OrderVerifier.accept`).
    struct State {
        // Pinned at creation.
        address[] adapters;
        address[] bridgeAdapters;
        address[] swapAdapters;
        mapping(address => bool) isPositionAdapter;
        mapping(address => bool) isSwapAdapter;
        mapping(address => bytes32) codehash;
        mapping(address => address) bridgeTarget;
        mapping(address => mapping(bytes32 => PoolTokens)) pools;
        address[] tokens;
        mapping(address => bool) isLedgerToken;
        // Ledger.
        mapping(address => uint256) unallocated;
        mapping(address => uint256) collectedIncome;
        uint256 operatingCash;
        uint256 operatingCashFloor;
        uint256 operatingCashTopUp;
        ISpokeVault.PositionRef[] positions;
        mapping(address => mapping(bytes32 => uint256)) positionSlot;
        // Cross-chain books.
        uint256 cumulativeReceived;
        uint256 cumulativeSentHome;
        uint64 reportSequence;
        uint256 transitNonce;
        mapping(bytes32 => Transit) hubBoundTransits;
        bytes32[] inFlightIds;
        mapping(bytes32 => uint256) inFlightSlot;
        mapping(bytes32 => uint256) arrivals;
        uint256 arrivalCount;
        bytes32[ARRIVAL_WINDOW] recentArrivals;
        // Books of the order-driven flows.
        SpokeUnwindTypes.Book unwind;
        SpokeIncomeTypes.Book income;
        // The Core Vault's order stream (DEC-120, DEC-139).
        OrderVerifier.Cursor orders;
        uint256 refundCount;
        bytes32[ARRIVAL_WINDOW] recentRefunds;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Errors beyond ISpokeVault
    // ---------------------------------------------------------------------------------------------------------------

    error WrongChain(uint256 configured, uint256 actual);
    error ZeroFundId();
    error ZeroAddress();
    error BaseTokenMismatch(address baseToken, address expected);
    error UnexpectedWormholeCore(address wormholeCore);
    error AdapterHasNoCode(address adapter);
    /// @notice A Mandate pool of this chain holds a token that is not a Mandate token of this chain (WP-07 B1, DEC-136).
    error PoolTokenNotInMandate(address adapter, bytes32 poolKey, address token);
    error ZeroBridgeTarget(address bridgeAdapter);
    error UnknownBridgeRank(uint256 bridgeRank);
    error BridgeTargetMismatch(address bridgeAdapter, address pinned, address built);
    /// @notice The bridge adapter's amount to arrive is zero or above the amount sent (DEC-085, DEC-162).
    error BridgeAmountMismatch(uint256 amountSent, uint256 amountToArrive);

    /// @notice The bridge adapter built a call whose fill deadline is not in the future (independent review L-09,
    ///         parity with the Core Vault's `BridgeCallMismatch`).
    error BridgeDeadlineNotInFuture(uint32 fillDeadline);
    error BridgeDebitMismatch(uint256 expected, uint256 debited);
    error AdapterUsedAboveInput(address adapter, address token, uint256 sent, uint256 used);
    error LedgerExceedsBalance(address token, uint256 balance, uint256 ledger);
    error PositionAlreadyRegistered(address adapter, bytes32 positionKey);
    error SwapOutputBelowMinimum(uint256 amountOut, uint256 minAmountOut);
    /// @notice A swap adapter did not take exactly the input the vault approved (DEC-080, DEC-136).
    error SwapDebitMismatch(uint256 expected, uint256 debited);
    /// @notice The vault received less than the output the swap adapter returned (DEC-079, DEC-080).
    error SwapOutputNotReceived(uint256 amountOut, uint256 received);
    error UnexpectedOriginChain(uint256 originChainId);
    /// @notice The vault did not receive exactly what a refund escrow held when it was released (DEC-066, DEC-080).
    error RefundReleaseMismatch(uint256 held, uint256 received);
    /// @notice `MAX_HUB_BOUND_IN_FLIGHT` sends home are already listed (security review S-11).
    error HubBoundInFlightLimit(uint256 limit);
    /// @notice `MAX_OPEN_POSITIONS` positions are already open (independent review H-04).
    error OpenPositionLimit(uint256 limit);
}
