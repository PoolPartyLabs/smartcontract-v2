// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAcrossMessageHandler} from "./external/IAcrossMessageHandler.sol";
import {ISpokeVaultUnwind} from "./ISpokeVaultUnwind.sol";
import {ISpokeVaultIncome} from "./ISpokeVaultIncome.sol";
import {IAdapter} from "./IAdapter.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {Transit, TransferKind, ExpensePayer} from "./FundTypes.sol";

/// @title ISpokeVault
/// @notice The fund's account on one chain, the Hub Chain included: holds positions, drives the Mandate's adapters,
///         keeps an internal ledger and publishes value reports (Spoke Chains) or exposes the same data to the Core
///         Vault (Hub Chain).
/// @dev DEC-054: every position lives in a Spoke Vault, including on the Hub Chain. DEC-055: money here that is not in
///      a position is Unallocated Balance, never Idle. DEC-080: an internal per-token ledger, credited only from
///      amounts adapters, the bridge and the Core Vault report; no base ever derives from `balanceOf`; excess over
///      the ledger is swept (DEC-096, DEC-101). DEC-058: not upgradeable.
/// @dev Adapter calls: only Mandate adapters on this chain (DEC-053), only Mandate pools (DEC-030), plain CALL, never
///      DELEGATECALL. Q17-4 (OPEN, reading O2): the vault stores each adapter's `codehash` at creation and reverts
///      with `AdapterCodehashMismatch` if it changed. The vault updates its ledger from what the adapter returns
///      (DEC-079, DEC-080).
/// @dev Every value-moving entry point is `nonReentrant` (OpenZeppelin ReentrancyGuard) and follows
///      checks-effects-interactions.
/// @dev WP-07 A4: the automatic unwind lives in ISpokeVaultUnwind and the collected income verbs in ISpokeVaultIncome;
///      this interface inherits both, so it still describes the whole Spoke Vault. A member declared in one of them is
///      named through it in expressions (`ISpokeVaultUnwind.UnwoundForPayout`).
interface ISpokeVault is IAcrossMessageHandler, ISpokeVaultUnwind, ISpokeVaultIncome {
    /// @notice An open position and the adapter that holds it.
    struct PositionRef {
        address adapter;
        bytes32 positionKey;
        bytes32 poolKey;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------------------------

    event PositionOpened(
        address indexed adapter, bytes32 indexed positionKey, bytes32 indexed poolKey, uint256 used0, uint256 used1
    );
    event PositionIncreased(
        address indexed adapter,
        bytes32 indexed positionKey,
        uint256 used0,
        uint256 used1,
        uint256 income0,
        uint256 income1
    );
    event PositionDecreased(address indexed adapter, bytes32 indexed positionKey, IAdapter.Amounts amounts);
    event PositionClosed(address indexed adapter, bytes32 indexed positionKey, IAdapter.Amounts amounts);
    event IncomeCollected(address indexed adapter, bytes32 indexed positionKey, uint256 income0, uint256 income1);

    /// @notice Unallocated Balance of `tokenIn` was swapped into `tokenOut` (DEC-079, DEC-080): by the manager through
    ///         a Mandate swap adapter (DEC-136, DEC-142), or by the automatic unwind (see `SpokeUnwindLib`).
    /// @dev Checklist doc 15, gap 4: the event carries the limit the swap was accepted under. For the automatic
    ///      unwind's interim sale in a Mandate pool (until WP-09 moves it to the swap adapter, DEC-136 item 4),
    ///      `adapter` is the position adapter, `maxLossBps` is `SpokeVault.MAX_UNWIND_SLIPPAGE_BPS`, measured from the
    ///      higher of `spotOut` and the price source, and `minOut` also counts the claimant's hint.
    /// @param adapter The swap adapter (a position adapter for an automatic unwind sale).
    /// @param spotOut Mid value of `amountIn` before the trade, without fee or price impact: the reference of the loss
    ///        (DEC-118, DEC-141).
    /// @param maxLossBps The caller's maximum loss against `spotOut`, in bps; 0 or >= 10,000 for none (D-23).
    /// @param minOut The minimum output the swap was held to: the stricter of `spotOut` less `maxLossBps` and the
    ///        signed API route's minimum (DEC-142), 0 when neither applies.
    event Swapped(
        address indexed adapter,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 spotOut,
        uint16 maxLossBps,
        uint256 minOut
    );

    /// @notice A bridge transfer arrived through `handleV3AcrossMessage` and was credited (DEC-090).
    event TransitArrived(
        bytes32 indexed transitId, uint256 indexed originChainId, address token, uint256 amount, TransferKind kind
    );

    /// @notice A transfer to the Core Vault was submitted. Cross-chain event fields: hub chain id, origin chain id and
    ///         the transfer id.
    event SentToHub(bytes32 indexed transitId, Transit transit, uint256 hubChainId, uint256 originChainId);

    /// @notice An expired transfer's refund was pulled back from its escrow into the ledger (DEC-066).
    event TransitRefundRecognized(bytes32 indexed transitId, uint256 amount);

    /// @notice A value report was published through Wormhole (DEC-070, DEC-086, DEC-093).
    event ReportPublished(uint64 indexed reportSequence, uint64 wormholeSequence, uint64 blockNumber);

    /// @notice An order of the Core Vault was executed here (DEC-120 item 2, DEC-139); the report published in the same
    ///         transaction (`ReportPublished`) carries its results. `orderId` (`OrderCodec.orderId`) and
    ///         `wormholeSequence` (the order message's) are those of the Core Vault's `ICoreVault.OrderPublished`.
    event OrderExecuted(uint8 indexed kind, bytes32 indexed orderId, uint64 wormholeSequence);

    /// @notice An Operating Expense was paid, with its funding source (DEC-041). `shareholder` is zero for a
    ///         fund-level expense.
    event OperatingExpensePaid(
        uint256 indexed chainId, address indexed shareholder, bytes32 indexed kind, uint256 amount, ExpensePayer payer
    );

    /// @notice Operating Cash was topped up from Share Assets (DEC-096, DEC-100).
    event OperatingCashToppedUp(uint256 amount, uint256 balance);

    /// @notice The manager changed the Operating Cash floor and top-up (DEC-096).
    event OperatingCashParametersSet(uint256 floor, uint256 topUp);

    /// @notice Hub only: the Core Vault allocated USDC to this vault's Unallocated Balance (DEC-017, DEC-072).
    event ReceivedFromCoreVault(uint256 amount);

    /// @notice Hub only: USDC Unallocated Balance was returned to the Core Vault's Idle.
    event ReturnedToCoreVault(uint256 amount);

    /// @notice Balance above the ledger was swept (DEC-080, DEC-096, DEC-101).
    event ExcessSwept(address indexed token, address indexed recipient, uint256 amount);

    // ---------------------------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------------------------

    error NotManager(address caller);
    error NotCoreVault(address caller);
    error NotAcrossSpokePool(address caller);
    error NotOnHubChain();
    error NotOnSpokeChain();
    error ZeroAmount();
    error AdapterNotInMandate(address adapter);
    error PoolNotInMandate(address adapter, bytes32 poolKey);
    error AdapterCodehashMismatch(address adapter, bytes32 expected, bytes32 actual);
    error UnknownPosition(address adapter, bytes32 positionKey);
    error InsufficientUnallocatedBalance(address token, uint256 available, uint256 requested);
    error InsufficientCollectedIncome(address token, uint256 available, uint256 requested);
    error UnexpectedToken(address token);
    /// @notice A swap's input or output is not a Mandate token of this chain (DEC-136 item 2).
    error TokenNotInMandate(address token);
    error WrongFund(bytes32 fundId);
    error BridgeFeeAboveMax(uint256 fee, uint256 maxFee);
    error UnknownTransit(bytes32 transitId);
    error FillDeadlineNotReached(bytes32 transitId, uint32 fillDeadline);
    error NoRefund(bytes32 transitId);
    /// @notice This vault cannot execute orders of `kind` yet (`OrderCodec.UNWIND`, `CLOSE` or `COLLECT`): the order
    ///         is refused whole and the order cursor does not move.
    error OrderKindNotSupported(uint8 kind);

    // ---------------------------------------------------------------------------------------------------------------
    // Identity and configuration
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Fund identifier shared by every contract of the fund.
    function fundId() external view returns (bytes32);

    /// @notice Hash of the fund's Mandate (`MandateLib.hash`).
    function mandateHash() external view returns (bytes32);

    /// @notice The fund manager (DEC-002).
    function manager() external view returns (address);

    /// @notice EVM chain id of the Hub Chain.
    function hubChainId() external view returns (uint256);

    /// @notice Whether this vault is the Hub Chain Spoke Vault.
    function onHubChain() external view returns (bool);

    /// @notice The fund's Core Vault on the Hub Chain (the bridge recipient of sends home).
    function coreVault() external view returns (address);

    /// @notice Token of this chain's principal ledger and Transport Route: USDC on the hub, the spoke's
    ///         `spokeToken` (USDG on Robinhood Chain) elsewhere (DEC-031, DEC-055).
    function baseToken() external view returns (address);

    /// @notice Across SpokePool on this chain, the only caller accepted by `handleV3AcrossMessage`.
    function acrossSpokePool() external view returns (address);

    /// @notice Wormhole Core Bridge on this chain (address(0) on the hub, where no report is published).
    function wormholeCore() external view returns (address);

    /// @notice Mandate position adapters on this chain.
    function adapters() external view returns (address[] memory);

    /// @notice Codehash pinned for `adapter` at creation (Q17-4); zero for an address that is not an adapter here.
    function adapterCodehash(address adapter) external view returns (bytes32);

    /// @notice The Mandate swap adapters of this chain, in Mandate order, each pinned with its codehash (DEC-136).
    function swapAdapters() external view returns (address[] memory);

    /// @notice Whether `token` is a Mandate token of this chain (DEC-136): the closed list of the ledger.
    function isMandateToken(address token) external view returns (bool);

    /// @notice Address that receives swept excess balances: the Protocol Recipient, the fee wallet (DEC-116).
    function excessRecipient() external view returns (address);

    // ---------------------------------------------------------------------------------------------------------------
    // Manager verbs (DEC-002, DEC-030, DEC-053)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Opens a position in a Mandate pool with `amount0`/`amount1` taken from Unallocated Balance. Manager
    ///         only. The adapter returns unused amounts, which go back to Unallocated Balance.
    function openPosition(address adapter, bytes32 poolKey, uint256 amount0, uint256 amount1, bytes calldata params)
        external
        returns (bytes32 positionKey, uint256 used0, uint256 used1);

    /// @notice Adds to a position. Manager only. Income realized by the protocol goes to the collected income bucket.
    function increasePosition(
        address adapter,
        bytes32 positionKey,
        uint256 amount0,
        uint256 amount1,
        bytes calldata params
    ) external returns (uint256 used0, uint256 used1, uint256 income0, uint256 income1);

    /// @notice Removes part of a position. Manager only. Principal returns to Unallocated Balance, income to the
    ///         collected income bucket (DEC-079, DEC-092).
    function decreasePosition(address adapter, bytes32 positionKey, bytes calldata params)
        external
        returns (IAdapter.Amounts memory amounts);

    /// @notice Closes a position. Manager only.
    function closePosition(address adapter, bytes32 positionKey, bytes calldata params)
        external
        returns (IAdapter.Amounts memory amounts);

    /// @notice Collects a position's income into the collected income bucket. Manager only.
    function collectIncome(address adapter, bytes32 positionKey) external returns (IAdapter.Amounts memory amounts);

    /// @notice Swaps `amountIn` of Unallocated Balance of `tokenIn` into `tokenOut` through a Mandate swap adapter of
    ///         this chain; the output is credited to Unallocated Balance. Manager only; on every chain.
    /// @dev DEC-136 (founder, 2026-10-02: "swaps are not done in the fund pools"): never in a Mandate position pool.
    ///      Both tokens must be Mandate tokens of this chain (DEC-136 item 2). Who chooses the route (DEC-143,
    ///      DEC-153): with an empty `route` the adapter swaps in the best direct Uniswap V3 fee tier; otherwise `route`
    ///      is an API route the Pool Party API signed, which anyone may relay (D-01, D-02). `maxLossBps` is the
    ///      manager's optional maximum loss against the pool mid before the trade, without a protocol cap; with a
    ///      signed route the stricter of it and the API minimum applies (DEC-142). Custody: the vault approves exactly
    ///      `amountIn`, resets the approval to zero, and checks from its own balances that exactly `amountIn` left and
    ///      at least the returned `amountOut` arrived, then credits `amountOut` (DEC-079, DEC-080). Quarantine and
    ///      deprecation are the adapter's: a swap into the base token always runs (DEC-056).
    /// @param swapAdapter A Mandate swap adapter of this chain (codehash pinned, Q17-4).
    /// @param maxLossBps Maximum loss in bps against the mid before the trade; 0 or >= 10,000 for none (D-23).
    /// @param route Empty, or `abi.encode(ISwapAdapter.ApiRoute)` signed by the adapter's route signer.
    function swap(
        address swapAdapter,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint16 maxLossBps,
        bytes calldata route
    ) external returns (uint256 amountOut);

    /// @notice Sets the Operating Cash floor and top-up of this chain. Manager only (DEC-096; no protocol cap on the
    ///         floor, DEC-100).
    function setOperatingCashParameters(uint256 floor, uint256 topUp) external;

    // ---------------------------------------------------------------------------------------------------------------
    // Cross-chain (Spoke Chains)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Sends base token to the Core Vault through the Mandate bridge adapter of priority `bridgeRank`. Manager
    ///         only; Spoke Chains only.
    /// @dev The vault fixes the recipient (the Core Vault), the token pair (base token to hub USDC) and the message
    ///      (TransitMessage); the bridge adapter fixes the amount to arrive and every other bridge term, and the manager
    ///      passes no bridge parameter (DEC-087, DEC-158, DEC-162; DEC-176: no signed quote in the MVP). Only
    ///      `Principal`, which debits Unallocated Balance: income goes home only through a collection order, with the
    ///      sale record the Hub converts it by (DEC-122, DEC-124, DEC-161), so `Income` reverts
    ///      `IncomeSentOnlyByCollection`. Every send is in the base token (the spoke token, USDG on Robinhood Chain) and
    ///      lands on the hub as USDC (CV-OQ-2). A per-send TransitEscrow is the depositor (DEC-066, QA6). The exit path is
    ///      never blocked by the bridge adapter's pause or deprecation (DEC-056). Custody: the vault executes the call
    ///      `IBridgeAdapter.buildSend` returns against the pinned target, with an exact approval reset to zero; the
    ///      adapter never holds the base token (DEC-087).
    function sendToHub(uint256 amount, TransferKind kind, uint256 bridgeRank) external returns (bytes32 transitId);

    /// @notice Pulls an expired send's refund from its escrow back into the ledger. Permissionless.
    /// @dev Only for a transit in state Sent after its fill deadline, and only once the escrow holds at least
    ///      `amountSent` (DEC-063: Across refunds the full input amount; DEC-066, QA6); reverts `NoRefund` otherwise,
    ///      and the transit stays Sent and in flight. Exactly `amountSent` is credited to the bucket the send debited;
    ///      any surplus the escrow held is released too and is sweepable excess (DEC-080, DEC-101). Same guard as
    ///      `ICoreVault.recognizeRefund` (CV-OQ-6).
    function recognizeRefund(bytes32 transitId) external returns (uint256 amount);

    /// @notice Builds the report and publishes it through Wormhole with finalized consistency. Permissionless; Spoke
    ///         Chains only (DEC-070, DEC-086, DEC-093; Q66 keeper cadence is off-chain).
    /// @dev `msg.value` pays the Wormhole message fee (0 on Arbitrum and Robinhood Chain today).
    function report() external payable returns (uint64 reportSequence, uint64 wormholeSequence);

    /// @notice Executes an order of the Core Vault delivered as a signed Wormhole VAA, then publishes this vault's
    ///         report in the same transaction. Permissionless; Spoke Chains only.
    /// @dev DEC-111, DEC-120 item 2, DEC-139: anyone delivers the order. It is accepted only if this chain's Wormhole
    ///      Core verifies it, its emitter is the fund's Core Vault on the Hub's Wormhole chain (the Mandate's
    ///      `hubWormholeChainId`, D-15), its sequence is above every order accepted before (DEC-093), it belongs to
    ///      this fund and its deadline has not passed (`OrderVerifier`); the order cursor then moves past it, so it
    ///      executes once. It runs by kind (unwind, closure or income collection) and the post-order report is
    ///      published with finalized consistency (DEC-093), `msg.value` paying the Wormhole message fee (DEC-120
    ///      item 2: the report after the unwind in the same transaction). DEC-157: no inactivity switch; an order is
    ///      the only Hub-to-spoke instruction. Until the order work exists every kind reverts `OrderKindNotSupported`.
    /// @return reportSequence Sequence of the report published after the order.
    function executeOrder(bytes calldata vaa) external payable returns (uint64 reportSequence);

    /// @notice The data a report would carry now (sequence = the next report sequence). On the hub this is the
    ///         reader the Core Vault uses for the hub Spoke Vault's principal and income (same chain, no message).
    /// @dev Reverts `ReentrancyGuardReentrantCall` while any guarded call of this vault is in progress, when the ledger
    ///      is mid-update.
    function buildReport() external view returns (ReportCodec.Report memory);

    /// @notice Across fill callback. Only the Across SpokePool; only the base token.
    /// @dev Decodes TransitMessage, rejects another fund's id, credits Unallocated Balance (Principal) or the collected
    ///      income bucket (Income). A Principal arrival also increases `cumulativeReceived` and is recorded per transit
    ///      id for the next report; an Income arrival is not, because the hub only ever sends Principal (DEC-085,
    ///      OQ-09). Across passes no depositor, so an arrival is recorded as a claim that the hub confirms by transit id
    ///      only when the listed total reaches the amount it expects to arrive (OQ-01, OQ-09).
    function handleV3AcrossMessage(address tokenSent, uint256 amount, address relayer, bytes memory message) external;

    // ---------------------------------------------------------------------------------------------------------------
    // Hub Chain interplay with the Core Vault
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Credits USDC the Core Vault transferred to this vault's Unallocated Balance. Core Vault only; hub only.
    function receiveFromCoreVault(uint256 amount) external;

    /// @notice Moves USDC Unallocated Balance back to the Core Vault's Idle (`ICoreVault.returnToIdle`). Manager only;
    ///         hub only.
    function returnToCoreVault(uint256 amount) external;

    // ---------------------------------------------------------------------------------------------------------------
    // Garbage collector
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Sends `balanceOf(token)` minus every ledger amount of `token` to `excessRecipient()`. Permissionless.
    /// @dev DEC-080, DEC-096, DEC-101. Never sweeps ledger value, including income dust.
    function sweepExcess(address token) external returns (uint256 amount);

    // ---------------------------------------------------------------------------------------------------------------
    // Ledger views (DEC-080)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Unallocated Balance of `token` (DEC-055).
    function unallocatedBalance(address token) external view returns (uint256);

    /// @notice The closed list of tokens the ledger tracks: this chain's Mandate tokens, base token first (DEC-136).
    function ledgerTokens() external view returns (address[] memory);

    /// @notice Collected income of `token` held here, outside Share Assets (DEC-092).
    function collectedIncome(address token) external view returns (uint256);

    /// @notice Income in `token` since inception across all adapters of this vault, including closed positions;
    ///         monotonic (Q60).
    function cumulativeIncome(address token) external view returns (uint256);

    /// @notice Every open position.
    function positions() external view returns (PositionRef[] memory);

    /// @notice Operating Cash of this chain (DEC-096). On the hub, Operating Cash lives in the Core Vault and this
    ///         returns 0.
    function operatingCash() external view returns (uint256);

    /// @notice Current Operating Cash floor (DEC-096).
    function operatingCashFloor() external view returns (uint256);

    /// @notice Current Operating Cash top-up amount (DEC-096).
    function operatingCashTopUp() external view returns (uint256);

    /// @notice Total principal ever credited from hub transfers, in base token units.
    function cumulativeReceived() external view returns (uint256);

    /// @notice Total ever sent to the hub, in base token units.
    function cumulativeSentHome() external view returns (uint256);

    /// @notice Sequence of the last published report (0 before the first).
    function reportSequence() external view returns (uint64);

    /// @notice A transfer this vault sent to the hub.
    function hubBoundTransit(bytes32 transitId) external view returns (Transit memory);

    /// @notice Whether a Principal hub-to-spoke transit id was credited here (OQ-09: Income arrivals are not tracked).
    function hasArrived(bytes32 transitId) external view returns (bool);
}
