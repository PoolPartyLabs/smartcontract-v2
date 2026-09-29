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

    /// @notice One swap of non-USDC principal an unwind exit returned, into hub USDC.
    /// @param adapter Mandate position adapter on the Hub Chain that runs the swap.
    /// @param poolKey Mandate pool of that adapter; it must hold `tokenIn` and USDC.
    /// @param tokenIn Token the exit returned as principal; the whole amount the exit returned is swapped.
    /// @param minAmountOut Per-step minimum USDC output (the caller's slippage bound).
    /// @param params Adapter-specific swap parameters (price limit, deadline).
    struct UnwindSwap {
        address adapter;
        bytes32 poolKey;
        address tokenIn;
        uint256 minAmountOut;
        bytes params;
    }

    /// @notice The caller's parameters for one position the automatic unwind visits (DEC-069 order).
    /// @param close `closePosition` when true, else `decreasePosition`.
    /// @param exitParams Adapter-specific exit parameters (amounts to remove, per-token minimums, deadline).
    /// @param swaps Swaps of the non-USDC principal this exit returns.
    struct UnwindHint {
        bool close;
        bytes exitParams;
        UnwindSwap[] swaps;
    }

    /// @notice Immutable wiring the cross-chain library needs, rebuilt in memory from the vault's immutables.
    struct Config {
        bytes32 fundId;
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
    error BridgeDebitMismatch(uint256 expected, uint256 debited);
    error InvalidQuoteAmount(uint256 amount, uint256 outputAmount);
    error AdapterUsedAboveInput(address adapter, address token, uint256 sent, uint256 used);
    error LedgerExceedsBalance(address token, uint256 balance, uint256 ledger);
    error PositionAlreadyRegistered(address adapter, bytes32 positionKey);
    error SwapOutputBelowMinimum(uint256 amountOut, uint256 minAmountOut);
    error UnexpectedOriginChain(uint256 originChainId);
    error MissingUnwindHint(address adapter, bytes32 positionKey);
    error InvalidUnwindSwap(address adapter, bytes32 poolKey, address tokenIn);

    /// @notice Encodes the `unwindHints` argument of `ISpokeVault.unwindForPayout`.
    function encodeHints(UnwindHint[] memory hints) internal pure returns (bytes memory) {
        return abi.encode(hints);
    }
}
