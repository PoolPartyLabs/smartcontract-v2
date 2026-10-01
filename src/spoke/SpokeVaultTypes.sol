// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {Transit} from "../interfaces/FundTypes.sol";
import {UnwindStep} from "../mandate/Mandate.sol";

/// @title SpokeVaultTypes
/// @notice Storage layout, wiring and caller-encoded types of the Spoke Vault, shared by `SpokeVault` and
///         `SpokeCrossChainLib`, plus the errors the Spoke Vault raises beyond ISpokeVault.
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
    ///      non-arrival (`CoreVaultLogic.nonArrivalProvable`). Only Principal arrivals are counted per id and listed,
    ///      at their monotonic credited total, and the hub confirms an id only when that total reaches the amount it
    ///      expects to arrive, so a stranger listing a real id below it cannot confirm the transit (OQ-01, OQ-09,
    ///      consolidation verifier round 2).
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
    ///      Wormhole Core) and visited by the automatic unwind. Unbounded, about 145 dust positions pushed a delivery
    ///      past Arbitrum's 32M gas per transaction, which froze the hub's view of the spoke, and about 110 exhausted an
    ///      unwind. At 32, a full arrival window, 64 sends home and 32 positions stay well under the limit. OPEN value.
    uint256 internal constant MAX_OPEN_POSITIONS = 32;

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

    /// @notice The claimant's optional tightening of the swap of one non-USDC token an unwind exit returned, into hub
    ///         USDC. Final verification (DEC-069, DEC-081, DEC-097, QA3 OPEN): a hint can never widen what the vault
    ///         would do on its own.
    /// @param adapter Mandate position adapter on the Hub Chain that runs the swap. When the position's own pool pairs
    ///        `tokenIn` with USDC the vault swaps there and a hint must name that same route; otherwise the hint names
    ///        the route (a Mandate pool of a Mandate adapter holding `tokenIn` and USDC) and is required.
    /// @param poolKey Mandate pool of that adapter.
    /// @param tokenIn Token the exit returned as principal; the whole amount the exit returned is swapped.
    /// @param minAmountOut Minimum USDC output; used only when above the vault's floor (the route's spot quote less
    ///        `SpokeVault.MAX_UNWIND_SLIPPAGE_BPS`).
    /// @param params Adapter-specific swap parameters (Uniswap V4: price limit and deadline, which can only make the
    ///        swap revert); empty for the adapter's defaults.
    struct UnwindSwap {
        address adapter;
        bytes32 poolKey;
        address tokenIn;
        uint256 minAmountOut;
        bytes params;
    }

    /// @notice The claimant's optional hint for one position the automatic unwind visits (DEC-069 order): only swap
    ///         tightenings. The vault sizes every exit itself (`IAdapter.unwindExitParams`) and never takes exit
    ///         parameters from the claimant (final verification).
    /// @param swaps Tightenings of the swaps of the non-USDC principal this exit returns, matched by `tokenIn`.
    struct UnwindHint {
        UnwindSwap[] swaps;
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
        uint16 maxBridgeFeeBps;
        uint32 maxReportAge;
    }

    /// @notice Every mutable and pinned value of a Spoke Vault.
    /// @dev Chain-local Mandate copy pinned at creation (DEC-030, DEC-053, DEC-069, DEC-087, DEC-088, Q17-4), the
    ///      internal ledger (DEC-080), Operating Cash (DEC-096) and the cross-chain books (DEC-066, DEC-090, OQ-09).
    struct State {
        // Pinned at creation.
        address[] adapters;
        address[] bridgeAdapters;
        mapping(address => bool) isPositionAdapter;
        mapping(address => bytes32) codehash;
        mapping(address => address) bridgeTarget;
        mapping(address => mapping(bytes32 => PoolTokens)) pools;
        UnwindStep[] unwindOrder;
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
    error ZeroBridgeTarget(address bridgeAdapter);
    error UnknownBridgeRank(uint256 bridgeRank);
    error BridgeTargetMismatch(address bridgeAdapter, address pinned, address built);
    error BridgeAmountMismatch(uint256 quoted, uint256 built);

    /// @notice The bridge adapter built a call whose fill deadline is not in the future (independent review L-09,
    ///         parity with the Core Vault's `BridgeCallMismatch`).
    error BridgeDeadlineNotInFuture(uint32 fillDeadline);
    error BridgeDebitMismatch(uint256 expected, uint256 debited);
    error InvalidQuoteAmount(uint256 amount, uint256 outputAmount);
    /// @notice A quote named an exclusive relayer or an exclusivity period (security review S-9).
    error ExclusiveRelayerNotAllowed(address exclusiveRelayer);
    error AdapterUsedAboveInput(address adapter, address token, uint256 sent, uint256 used);
    error LedgerExceedsBalance(address token, uint256 balance, uint256 ledger);
    error PositionAlreadyRegistered(address adapter, bytes32 positionKey);
    error SwapOutputBelowMinimum(uint256 amountOut, uint256 minAmountOut);
    error UnexpectedOriginChain(uint256 originChainId);
    /// @notice An unwind exit returns `token`, the position's own pool does not pair it with USDC and no hint names a
    ///         route for it (final verification: the unwind is never sized or swapped without a price).
    error MissingUnwindSwap(address token);
    error InvalidUnwindSwap(address adapter, bytes32 poolKey, address tokenIn);
    /// @notice The vault did not receive exactly what a refund escrow held when it was released (DEC-066, DEC-080).
    error RefundReleaseMismatch(uint256 held, uint256 received);
    /// @notice Only Operating Cash above the floor can be returned (security review S-5).
    error OperatingCashNotReleasable(uint256 amount, uint256 releasable);
    /// @notice `MAX_HUB_BOUND_IN_FLIGHT` sends home are already listed (security review S-11).
    error HubBoundInFlightLimit(uint256 limit);
    /// @notice `MAX_OPEN_POSITIONS` positions are already open (independent review H-04).
    error OpenPositionLimit(uint256 limit);

    /// @notice Encodes the `unwindHints` argument of `ISpokeVault.unwindForPayout`.
    function encodeHints(UnwindHint[] memory hints) internal pure returns (bytes memory) {
        return abi.encode(hints);
    }
}
