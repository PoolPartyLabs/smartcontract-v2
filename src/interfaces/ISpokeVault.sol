// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAcrossMessageHandler} from "./external/IAcrossMessageHandler.sol";
import {ISpokeVaultUnwind} from "./ISpokeVaultUnwind.sol";
import {ISpokeVaultIncome} from "./ISpokeVaultIncome.sol";
import {IAdapter} from "./IAdapter.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {Transit, TransferKind, ExpensePayer, BridgeQuote} from "./FundTypes.sol";

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
    event Swapped(
        address indexed adapter,
        bytes32 indexed poolKey,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
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
    error WrongFund(bytes32 fundId);
    error BridgeFeeAboveMax(uint256 fee, uint256 maxFee);
    error UnknownTransit(bytes32 transitId);
    error FillDeadlineNotReached(bytes32 transitId, uint32 fillDeadline);
    error NoRefund(bytes32 transitId);

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

    /// @notice Address that receives swept excess balances. OPEN (LC-132): whether it is the Protocol Recipient.
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

    /// @notice Swaps Unallocated Balance in a Mandate pool. Manager only. See `IAdapter.swapExactInput` for the OPEN
    ///         points.
    function swapExactInput(
        address adapter,
        bytes32 poolKey,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata params
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
    ///      (TransitMessage) and rejects a quote whose fee exceeds `maxBridgeFeeBps` (DEC-087, QA19). `Principal`
    ///      debits Unallocated Balance; `Income` debits the collected income bucket of the base token (who pays
    ///      bridging of income is OPEN, LC-22 / LC-37 / LC-49). Every send is in the base token (the spoke token, USDG
    ///      on Robinhood Chain) and lands on the hub as USDC (CV-OQ-2): an `Income` send is credited on the hub as
    ///      collected USDC income and split there (ruling 2026-09-29, DEC-107); income collected in another token is
    ///      first turned into the base token with `swapCollectedIncome`. A per-send TransitEscrow is the depositor (DEC-066, QA6). The exit path is
    ///      never blocked by the bridge adapter's pause or deprecation (DEC-056). Custody: the vault executes the call
    ///      `IBridgeAdapter.buildSend` returns against the pinned target, with an exact approval reset to zero; the
    ///      adapter never holds the base token (DEC-087).
    function sendToHub(uint256 amount, TransferKind kind, uint256 bridgeRank, BridgeQuote calldata quote)
        external
        returns (bytes32 transitId);

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

    /// @notice The data a report would carry now (sequence = the next report sequence). On the hub this is the
    ///         reader the Core Vault uses for the hub Spoke Vault's principal and income (same chain, no message).
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

    /// @notice Tokens that ever had an Unallocated Balance entry.
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
