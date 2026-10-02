// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";

import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {Transit, TransferKind, ExpensePayer, BridgeQuote} from "../interfaces/FundTypes.sol";
import {Mandate, MandateLib, SpokeConfig, PoolConfig, BridgeAdapterConfig} from "../mandate/Mandate.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {TransitMessage} from "../libraries/TransitMessage.sol";
import {SpokeVaultTypes} from "./SpokeVaultTypes.sol";
import {SpokeCrossChainLib} from "./SpokeCrossChainLib.sol";
import {SpokeLedger} from "./SpokeLedger.sol";
import {SpokeUnwindLib} from "./SpokeUnwindLib.sol";

/// @title SpokeVault
/// @notice The fund's account on one chain, the Hub Chain included. See ISpokeVault.
/// @dev DEC-054: one Spoke Vault per fund chain, the Hub Chain included; `onHubChain` selects the role. The hub role
///      talks to the Core Vault, publishes no report and holds no Operating Cash; the spoke role receives Across fills,
///      sends home and publishes value reports through the Wormhole Core Bridge.
/// @dev DEC-022, DEC-058: no proxy, no upgrade path, no selfdestruct. The constructor takes everything it needs, so the
///      FundFactory deploys it at a CREATE3 address that depends only on the factory and the salt (fund id, role,
///      chain id), never on this creation code (DEC-054). The Spoke Chain half (send home, refunds, report) lives in the
///      linked external library `SpokeCrossChainLib` and the automatic unwind in `SpokeUnwindLib` (DEC-131); both run
///      by DELEGATECALL over this vault's storage and hold none of their own: their addresses are part of this vault's
///      creation code and trust surface (immutable, no upgrade path). The operator deploys them once per chain at
///      chain-independent addresses (so the linked creation code and its hash are the same on every chain) and the
///      factory stores that code with its hash fixed at construction. These are the only DELEGATECALLs the vault
///      makes; adapters are always called with a plain CALL. The registry and ledger helpers both sides use are the
///      internal library `SpokeLedger`.
/// @dev DEC-080: every value that reaches a base comes from the internal ledger (`unallocated`, `collectedIncome`,
///      `operatingCash`), never from `balanceOf`. `balanceOf` is read only to assert the ledger is backed, to verify
///      an exact bridge debit and to size the excess sweep.
contract SpokeVault is ISpokeVault, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MandateLib for Mandate;
    using SpokeLedger for SpokeVaultTypes.State;

    /// @dev DEC-093: reports are published with finalized consistency.
    uint8 internal constant WORMHOLE_FINALIZED = 1;

    /// @dev Wormhole nonce: a batching tag only; replay protection is the (emitter, sequence) pair (DEC-093).
    uint32 internal constant WORMHOLE_NONCE = 0;

    /// @notice Kind tag of the Operating Expense booked by an Operating Cash top-up (DEC-041, DEC-096).
    bytes32 public constant OPERATING_CASH_TOP_UP = keccak256("OPERATING_CASH_TOP_UP");

    /// @notice Largest shortfall below the pool's current price, in bps, that an automatic unwind swap accepts: the
    ///         swap's minimum output is at least the route's `IAdapter.spotQuote` less this share.
    /// @dev OPEN parameter (QA3: the price guard of hub positions is undecided; final verification). Measured from the
    ///      higher of the route's spot quote and the Core Vault's price-source value (security review S-2: a spot price
    ///      can be moved within a block by the claimant); a claimant hint may only raise the minimum. Applied by the
    ///      linked `SpokeUnwindLib`, whose constant this is (DEC-131).
    uint256 public constant MAX_UNWIND_SLIPPAGE_BPS = SpokeUnwindLib.MAX_UNWIND_SLIPPAGE_BPS;

    // ---------------------------------------------------------------------------------------------------------------
    // Identity and wiring (immutable, DEC-053, DEC-058)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeVault
    bytes32 public immutable fundId;
    /// @inheritdoc ISpokeVault
    bytes32 public immutable mandateHash;
    /// @inheritdoc ISpokeVault
    address public immutable manager;
    /// @inheritdoc ISpokeVault
    uint256 public immutable hubChainId;
    /// @notice EVM chain id of this vault's chain.
    uint256 public immutable chainId;
    /// @inheritdoc ISpokeVault
    bool public immutable onHubChain;
    /// @inheritdoc ISpokeVault
    address public immutable coreVault;
    /// @inheritdoc ISpokeVault
    address public immutable baseToken;
    /// @notice USDC on the Hub Chain: the output token of every send home (DEC-011, DEC-087).
    address public immutable hubChainUsdc;
    /// @inheritdoc ISpokeVault
    address public immutable acrossSpokePool;
    /// @inheritdoc ISpokeVault
    address public immutable wormholeCore;
    /// @notice TransitEscrow implementation cloned once per send home (DEC-066, QA6).
    address public immutable transitEscrowImplementation;
    /// @inheritdoc ISpokeVault
    address public immutable excessRecipient;
    /// @notice Maximum bridge fee per send, in bps of the amount sent (QA19, value OPEN).
    uint16 public immutable maxBridgeFeeBps;
    /// @notice This spoke's report lifetime from the Mandate (DEC-099; value OPEN, Q57 / Q66). 0 on the hub.
    uint32 public immutable maxReportAge;

    /// @dev Pinned Mandate copy, ledger and cross-chain books.
    SpokeVaultTypes.State internal _s;

    // ---------------------------------------------------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev DEC-002: only the Manager opens exposure and drives the fund's positions.
    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager(msg.sender);
        _;
    }

    modifier onlyOnHubChain() {
        if (!onHubChain) revert NotOnHubChain();
        _;
    }

    modifier onlyOnSpokeChain() {
        if (onHubChain) revert NotOnSpokeChain();
        _;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------------------------

    /// @param mandate_ The fund's Mandate; validated with `MandateLib.validate` (DEC-053).
    /// @param fundId_ Fund identifier shared by every contract of the fund.
    /// @param chainId_ This chain's EVM id; must equal `block.chainid`.
    /// @param coreVault_ The Core Vault on the Hub Chain; on a spoke, the bridge recipient of every send home (DEC-087).
    /// @param baseToken_ USDC on the hub, the spoke's `spokeToken` elsewhere (DEC-031, DEC-055).
    /// @param acrossSpokePool_ Across SpokePool on this chain, the only `handleV3AcrossMessage` caller.
    /// @param wormholeCore_ Wormhole Core Bridge on a spoke; address(0) on the hub (no report is published there).
    /// @param transitEscrowImplementation_ TransitEscrow cloned per send home (DEC-066, QA6); unused on the hub.
    /// @param excessRecipient_ Destination of swept excess (DEC-096, DEC-101; LC-132 OPEN).
    /// @dev Q17-4 (OPEN, stance: pin in the vault, OQ-13): the codehash of every Mandate adapter on this chain is pinned
    ///      here and revalidated on every later call. OQ-12: `poolTokens` is called for every Mandate pool on this
    ///      chain, which rejects hooked Uniswap V4 pools (DEC-079 open) and fixes the token list of the ledger.
    ///      DEC-087, DEC-088: on a spoke, every spoke-side bridge adapter's `target()` is pinned in Mandate order.
    constructor(
        Mandate memory mandate_,
        bytes32 fundId_,
        uint256 chainId_,
        address coreVault_,
        address baseToken_,
        address acrossSpokePool_,
        address wormholeCore_,
        address transitEscrowImplementation_,
        address excessRecipient_
    ) {
        mandate_.validate();
        if (chainId_ != block.chainid) revert SpokeVaultTypes.WrongChain(chainId_, block.chainid);
        if (fundId_ == bytes32(0)) revert SpokeVaultTypes.ZeroFundId();
        if (coreVault_ == address(0) || acrossSpokePool_ == address(0) || excessRecipient_ == address(0)) {
            revert SpokeVaultTypes.ZeroAddress();
        }

        bool hub = chainId_ == mandate_.hubChainId;
        if (hub) {
            if (baseToken_ != mandate_.usdc) revert SpokeVaultTypes.BaseTokenMismatch(baseToken_, mandate_.usdc);
            if (wormholeCore_ != address(0)) revert SpokeVaultTypes.UnexpectedWormholeCore(wormholeCore_);
        } else {
            (, SpokeConfig memory spoke) = mandate_.spokeByChainId(chainId_);
            if (baseToken_ != spoke.spokeToken) revert SpokeVaultTypes.BaseTokenMismatch(baseToken_, spoke.spokeToken);
            if (wormholeCore_ == address(0) || transitEscrowImplementation_ == address(0)) {
                revert SpokeVaultTypes.ZeroAddress();
            }
            maxReportAge = spoke.maxReportAge;
            // DEC-096: the creation values; the manager may adjust them later.
            (_s.operatingCashFloor, _s.operatingCashTopUp) = mandate_.operatingCashFor(chainId_);
        }

        fundId = fundId_;
        mandateHash = mandate_.hash();
        manager = mandate_.manager;
        hubChainId = mandate_.hubChainId;
        chainId = chainId_;
        onHubChain = hub;
        coreVault = coreVault_;
        baseToken = baseToken_;
        hubChainUsdc = mandate_.usdc;
        acrossSpokePool = acrossSpokePool_;
        wormholeCore = wormholeCore_;
        transitEscrowImplementation = transitEscrowImplementation_;
        excessRecipient = excessRecipient_;
        maxBridgeFeeBps = mandate_.maxBridgeFeeBps;

        _registerToken(baseToken_);
        _pinAdapters(mandate_, chainId_);
        _pinPools(mandate_, chainId_);
        _copyUnwindOrder(mandate_, chainId_);
        if (!hub) _pinBridgeAdapters(mandate_, chainId_);
    }

    /// @dev DEC-053, DEC-058, Q17-4.
    function _pinAdapters(Mandate memory m, uint256 chainId_) private {
        for (uint256 i; i < m.adapters.length; ++i) {
            if (m.adapters[i].chainId != chainId_) continue;
            address adapter = m.adapters[i].adapter;
            _s.codehash[adapter] = _requireCode(adapter);
            _s.isPositionAdapter[adapter] = true;
            _s.adapters.push(adapter);
        }
    }

    /// @dev DEC-030 (closed pool list), OQ-12 (hooked pools rejected by `poolTokens`).
    function _pinPools(Mandate memory m, uint256 chainId_) private {
        for (uint256 i; i < m.pools.length; ++i) {
            PoolConfig memory p = m.pools[i];
            if (p.chainId != chainId_) continue;
            (address token0, address token1) = IAdapter(p.adapter).poolTokens(p.poolKey);
            _s.pools[p.adapter][p.poolKey] = SpokeVaultTypes.PoolTokens(token0, token1, true);
            _registerToken(token0);
            _registerToken(token1);
        }
    }

    /// @dev DEC-069: the Mandate unwind order restricted to this chain, in Mandate order.
    function _copyUnwindOrder(Mandate memory m, uint256 chainId_) private {
        for (uint256 i; i < m.unwindOrder.length; ++i) {
            if (m.unwindOrder[i].chainId == chainId_) _s.unwindOrder.push(m.unwindOrder[i]);
        }
    }

    /// @dev DEC-087, DEC-088: the spoke-side bridge adapters of this spoke, in Mandate priority order, each with its
    ///      pinned `target()` and codehash (Q17-4).
    function _pinBridgeAdapters(Mandate memory m, uint256 chainId_) private {
        for (uint256 i; i < m.bridgeAdapters.length; ++i) {
            BridgeAdapterConfig memory b = m.bridgeAdapters[i];
            if (b.chainId != chainId_ || b.spokeChainId != chainId_) continue;
            _s.codehash[b.adapter] = _requireCode(b.adapter);
            address target = IBridgeAdapter(b.adapter).target();
            if (target == address(0)) revert SpokeVaultTypes.ZeroBridgeTarget(b.adapter);
            _s.bridgeTarget[b.adapter] = target;
            _s.bridgeAdapters.push(b.adapter);
        }
    }

    function _requireCode(address adapter) private view returns (bytes32) {
        if (adapter.code.length == 0) revert SpokeVaultTypes.AdapterHasNoCode(adapter);
        return adapter.codehash;
    }

    function _registerToken(address token) private {
        if (token == address(0) || _s.isLedgerToken[token]) return;
        _s.isLedgerToken[token] = true;
        _s.tokens.push(token);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Manager verbs (DEC-002, DEC-030, DEC-053, DEC-079)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeVault
    /// @dev DEC-030, DEC-053: Mandate adapter and pool on this chain only. DEC-079: the tokens move to the adapter first
    ///      and the ledger is updated from what the adapter returns; unused amounts return to Unallocated Balance.
    function openPosition(address adapter, bytes32 poolKey, uint256 amount0, uint256 amount1, bytes calldata params)
        external
        onlyManager
        nonReentrant
        returns (bytes32 positionKey, uint256 used0, uint256 used1)
    {
        IAdapter a = _s.positionAdapter(adapter);
        SpokeVaultTypes.PoolTokens memory p = _s.pool(adapter, poolKey);
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();
        _topUpOperatingCash();
        _s.sendToAdapter(adapter, p.token0, amount0);
        _s.sendToAdapter(adapter, p.token1, amount1);
        (positionKey, used0, used1) = a.openPosition(poolKey, params);
        _s.creditUnused(adapter, p, amount0, used0, amount1, used1);
        if (_s.positionSlot[adapter][positionKey] != 0) {
            revert SpokeVaultTypes.PositionAlreadyRegistered(adapter, positionKey);
        }
        if (_s.positions.length >= SpokeVaultTypes.MAX_OPEN_POSITIONS) {
            revert SpokeVaultTypes.OpenPositionLimit(SpokeVaultTypes.MAX_OPEN_POSITIONS);
        }
        _s.positions.push(PositionRef(adapter, positionKey, poolKey));
        _s.positionSlot[adapter][positionKey] = _s.positions.length;
        _s.requireBacked(baseToken, p);
        emit PositionOpened(adapter, positionKey, poolKey, used0, used1);
    }

    /// @inheritdoc ISpokeVault
    /// @dev DEC-079, DEC-092: income the protocol realized during the increase goes to the collected income bucket.
    function increasePosition(
        address adapter,
        bytes32 positionKey,
        uint256 amount0,
        uint256 amount1,
        bytes calldata params
    ) external onlyManager nonReentrant returns (uint256 used0, uint256 used1, uint256 income0, uint256 income1) {
        IAdapter a = _s.positionAdapter(adapter);
        SpokeVaultTypes.PoolTokens memory p = _s.pool(adapter, _s.positionPool(adapter, positionKey));
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();
        _topUpOperatingCash();
        _s.sendToAdapter(adapter, p.token0, amount0);
        _s.sendToAdapter(adapter, p.token1, amount1);
        (used0, used1, income0, income1) = a.increasePosition(positionKey, params);
        _s.creditUnused(adapter, p, amount0, used0, amount1, used1);
        _s.credit(p, IAdapter.Amounts(0, 0, income0, income1));
        _s.requireBacked(baseToken, p);
        emit PositionIncreased(adapter, positionKey, used0, used1, income0, income1);
    }

    /// @inheritdoc ISpokeVault
    /// @dev DEC-056: never blocked by the adapter's pause or deprecation (the adapter does not read its flags here).
    function decreasePosition(address adapter, bytes32 positionKey, bytes calldata params)
        external
        onlyManager
        nonReentrant
        returns (IAdapter.Amounts memory amounts)
    {
        _topUpOperatingCash();
        (amounts,) = _s.exit(baseToken, adapter, positionKey, SpokeVaultTypes.ExitKind.Decrease, params);
    }

    /// @inheritdoc ISpokeVault
    /// @dev DEC-056: exit verb. The position leaves the registry; the adapter's `cumulativeIncome` keeps its income.
    function closePosition(address adapter, bytes32 positionKey, bytes calldata params)
        external
        onlyManager
        nonReentrant
        returns (IAdapter.Amounts memory amounts)
    {
        _topUpOperatingCash();
        (amounts,) = _s.exit(baseToken, adapter, positionKey, SpokeVaultTypes.ExitKind.Close, params);
    }

    /// @inheritdoc ISpokeVault
    /// @dev DEC-092: income goes to the collected income bucket, outside Share Assets.
    function collectIncome(address adapter, bytes32 positionKey)
        external
        onlyManager
        nonReentrant
        returns (IAdapter.Amounts memory amounts)
    {
        _topUpOperatingCash();
        (amounts,) = _s.exit(baseToken, adapter, positionKey, SpokeVaultTypes.ExitKind.Collect, "");
    }

    /// @inheritdoc ISpokeVault
    /// @dev OQ-04 stance: manager only; the adapter reverts when deprecated, never when paused. Debits Unallocated
    ///      Balance of `tokenIn` and credits what the adapter returns in the other pool token (DEC-079, DEC-080).
    function swapExactInput(
        address adapter,
        bytes32 poolKey,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata params
    ) external onlyManager nonReentrant returns (uint256 amountOut) {
        IAdapter a = _s.positionAdapter(adapter);
        SpokeVaultTypes.PoolTokens memory p = _s.pool(adapter, poolKey);
        _topUpOperatingCash();
        amountOut = _s.swap(baseToken, a, p, poolKey, tokenIn, amountIn, minAmountOut, params, false);
    }

    /// @inheritdoc ISpokeVault
    /// @dev CV-OQ-2, ruling 2026-09-29, DEC-092: collected income in, base token out, both inside the collected income
    ///      bucket; DEC-079, DEC-080: credited from what the adapter returns.
    function swapCollectedIncome(
        address adapter,
        bytes32 poolKey,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata params
    ) external onlyOnSpokeChain onlyManager nonReentrant returns (uint256 amountOut) {
        IAdapter a = _s.positionAdapter(adapter);
        SpokeVaultTypes.PoolTokens memory p = _s.pool(adapter, poolKey);
        if (SpokeLedger.otherToken(p, tokenIn) != baseToken) revert UnexpectedToken(tokenIn);
        _topUpOperatingCash();
        amountOut = _s.swap(baseToken, a, p, poolKey, tokenIn, amountIn, minAmountOut, params, true);
    }

    /// @inheritdoc ISpokeVault
    /// @dev DEC-096: the floor and top-up are the first Mandate numbers the manager may change on a live fund;
    ///      DEC-100: no protocol cap on the floor. On the hub, Operating Cash lives in the Core Vault.
    function setOperatingCashParameters(uint256 floor, uint256 topUp) external onlyOnSpokeChain onlyManager {
        _s.operatingCashFloor = floor;
        _s.operatingCashTopUp = topUp;
        emit OperatingCashParametersSet(floor, topUp);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Cross-chain (Spoke Chains)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeVault
    /// @dev See `SpokeCrossChainLib.sendToHub`: DEC-056, DEC-066, DEC-085, DEC-087, DEC-088, QA6, QA19. Security review
    ///      S-3: the transit stays in `inFlightToHub` until its refund is recognized (by anyone, or at the next report
    ///      or send once it landed) or until `fillDeadline + ReportCodec.HUB_BOUND_RETENTION` has passed.
    ///      `cumulativeSentHome` grows by `amount`.
    function sendToHub(uint256 amount, TransferKind kind, uint256 bridgeRank, BridgeQuote calldata quote)
        external
        onlyOnSpokeChain
        onlyManager
        nonReentrant
        returns (bytes32 transitId)
    {
        _topUpOperatingCash();
        transitId = SpokeCrossChainLib.sendToHub(_s, _config(), amount, kind, bridgeRank, quote);
    }

    /// @inheritdoc ISpokeVault
    /// @dev DEC-066, QA6, DEC-080. See `SpokeCrossChainLib.recognizeRefund`.
    function recognizeRefund(bytes32 transitId) external onlyOnSpokeChain nonReentrant returns (uint256 amount) {
        _topUpOperatingCash();
        amount = SpokeCrossChainLib.recognizeRefund(_s, baseToken, transitId);
    }

    /// @inheritdoc ISpokeVault
    /// @dev DEC-070: built by the vault from its own ledger and its adapters' accounting. DEC-093: published with
    ///      finalized consistency; the sequence strictly increases by one per report. Permissionless (Q66: cadence
    ///      off-chain). `msg.value` is forwarded as the Wormhole message fee.
    function report()
        external
        payable
        onlyOnSpokeChain
        nonReentrant
        returns (uint64 sequence, uint64 wormholeSequence)
    {
        bytes memory payload;
        (sequence, payload) = SpokeCrossChainLib.nextReport(_s, _config());
        wormholeSequence =
            ICoreBridge(wormholeCore).publishMessage{value: msg.value}(WORMHOLE_NONCE, payload, WORMHOLE_FINALIZED);
        emit ReportPublished(sequence, wormholeSequence, uint64(block.number));
    }

    /// @inheritdoc ISpokeVault
    /// @dev Returns the report the linked library encodes: its payload is `abi.encode(VERSION, report)`, whose tail
    ///      from the second word is `abi.encode(report)` once that word holds the report's offset (0x20).
    function buildReport() external view returns (ReportCodec.Report memory) {
        bytes memory payload = SpokeCrossChainLib.encodedReport(_s, _config(), _s.reportSequence + 1);
        assembly ("memory-safe") {
            let start := add(payload, 0x40)
            mstore(start, 0x20)
            return(start, sub(mload(payload), 0x20))
        }
    }

    /// @inheritdoc ISpokeVault
    /// @dev DEC-080, OQ-01, OQ-09: only the Across SpokePool, only the base token, only this fund's messages from the
    ///      Hub Chain. The arrival is a claim: the id and amount travel in the next reports (the last
    ///      `ARRIVAL_WINDOW` listed ids plus `cumulativeReceived`) so the hub confirms what it sent (at or above the amount it expects) and excludes what it
    ///      did not. A repeated id adds to the same entry and is listed when its credited total first reaches
    ///      `MIN_LISTED_ARRIVAL` and again on every credit of at least that minimum (security review S-13); below it the arrival is credited but never listed (the hub then counts the transit
    ///      once through a fund-level deduction, at a liveness cost: see SpokeVaultTypes.MIN_LISTED_ARRIVAL). DEC-096: an arrival is a value-moving operation, so it runs the
    ///      Operating Cash top-up after crediting, like every other one (Spoke Vault verifier finding). OQ-09, OQ-01: only
    ///      a Principal-kind arrival feeds the per-id total and the listing, because the hub only ever sends Principal
    ///      (DEC-085); an Income-kind message carrying a real transit id is credited to the collected income bucket
    ///      (DEC-092) but can never help confirm that transit on the hub.
    function handleV3AcrossMessage(address tokenSent, uint256 amount, address, bytes memory message)
        external
        nonReentrant
    {
        if (msg.sender != acrossSpokePool) revert NotAcrossSpokePool(msg.sender);
        if (onHubChain) revert NotOnSpokeChain();
        if (tokenSent != baseToken) revert UnexpectedToken(tokenSent);
        if (amount == 0) revert ZeroAmount();
        (bytes32 messageFundId, uint256 originChainId, bytes32 transitId, TransferKind kind) =
            TransitMessage.decode(message);
        if (messageFundId != fundId) revert WrongFund(messageFundId);
        if (originChainId != hubChainId) revert SpokeVaultTypes.UnexpectedOriginChain(originChainId);

        SpokeCrossChainLib.creditArrival(_s, tokenSent, transitId, kind, amount);
        _s.requireBacked(baseToken, tokenSent);
        emit TransitArrived(transitId, originChainId, tokenSent, amount, kind);
        _topUpOperatingCash();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Hub Chain interplay with the Core Vault
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeVault
    /// @dev DEC-017, DEC-072, DEC-080: Unallocated Balance is credited from the Core Vault's allocation, which the
    ///      Core Vault transfers before calling.
    function receiveFromCoreVault(uint256 amount) external onlyOnHubChain nonReentrant {
        if (msg.sender != coreVault) revert NotCoreVault(msg.sender);
        if (amount == 0) revert ZeroAmount();
        _s.unallocated[baseToken] += amount;
        _s.requireBacked(baseToken, baseToken);
        emit ReceivedFromCoreVault(amount);
    }

    /// @inheritdoc ISpokeVault
    function returnToCoreVault(uint256 amount) external onlyOnHubChain onlyManager nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _s.debitUnallocated(baseToken, amount);
        SpokeLedger.payCoreVaultIdle(baseToken, coreVault, amount);
        emit ReturnedToCoreVault(amount);
    }

    /// @inheritdoc ISpokeVault
    /// @dev DEC-092: collected income is handed to the Core Vault's Attributed Income bucket; the destination is fixed.
    function forwardIncomeToCoreVault(address token) external onlyOnHubChain nonReentrant returns (uint256 amount) {
        amount = _s.collectedIncome[token];
        if (amount == 0) revert ZeroAmount();
        _s.collectedIncome[token] = 0;
        IERC20(token).safeTransfer(coreVault, amount);
        ICoreVault(coreVault).receiveCollectedIncome(token, amount);
        emit IncomeForwardedToCoreVault(token, amount);
    }

    /// @inheritdoc ISpokeVault
    /// @dev DEC-069, DEC-081, DEC-097, DEC-131: the body lives in the linked library `SpokeUnwindLib` (see
    ///      `SpokeUnwindLib.unwindForPayout`); the vault keeps the chain, caller and reentrancy checks.
    /// @param unwindHints `abi.encode(SpokeVaultTypes.UnwindHint[])`, optional, one per position visited in order.
    function unwindForPayout(uint256 usdcTarget, bytes calldata unwindHints)
        external
        onlyOnHubChain
        nonReentrant
        returns (uint256 usdcProceeds)
    {
        if (msg.sender != coreVault) revert NotCoreVault(msg.sender);
        usdcProceeds = SpokeUnwindLib.unwindForPayout(_s, _config(), usdcTarget, unwindHints);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Garbage collector
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeVault
    /// @dev DEC-080, DEC-096, DEC-101: excess = balance minus Unallocated Balance, collected income (dust included)
    ///      and Operating Cash; ledger value is never swept. Returns 0 when there is no excess.
    function sweepExcess(address token) external nonReentrant returns (uint256 amount) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 ledger = _s.ledgerTotal(baseToken, token);
        if (balance <= ledger) return 0;
        amount = balance - ledger;
        IERC20(token).safeTransfer(excessRecipient, amount);
        emit ExcessSwept(token, excessRecipient, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeVault
    function adapters() external view returns (address[] memory) {
        return _s.adapters;
    }

    /// @notice Spoke-side bridge adapters of this chain in Mandate priority order (empty on the hub).
    function bridgeAdapters() external view returns (address[] memory) {
        return _s.bridgeAdapters;
    }

    /// @notice Bridge target pinned for `bridgeAdapter` at creation.
    function bridgeTarget(address bridgeAdapter) external view returns (address) {
        return _s.bridgeTarget[bridgeAdapter];
    }

    /// @inheritdoc ISpokeVault
    /// @dev Position and bridge adapters alike (DEC-087: a bridge is an Adapter).
    function adapterCodehash(address adapter) external view returns (bytes32) {
        return _s.codehash[adapter];
    }

    /// @notice Tokens of a Mandate pool on this chain, as the adapter reported them at creation.
    function poolTokens(address adapter, bytes32 poolKey) external view returns (address token0, address token1) {
        SpokeVaultTypes.PoolTokens memory p = _s.pool(adapter, poolKey);
        return (p.token0, p.token1);
    }

    /// @inheritdoc ISpokeVault
    function unallocatedBalance(address token) external view returns (uint256) {
        return _s.unallocated[token];
    }

    /// @inheritdoc ISpokeVault
    /// @dev The closed list: the base token and every token of a Mandate pool on this chain.
    function ledgerTokens() external view returns (address[] memory) {
        return _s.tokens;
    }

    /// @inheritdoc ISpokeVault
    function collectedIncome(address token) external view returns (uint256) {
        return _s.collectedIncome[token];
    }

    /// @inheritdoc ISpokeVault
    /// @dev Q60: the sum of every Mandate adapter's own monotonic counter on this chain, so closing a position never
    ///      lowers it.
    function cumulativeIncome(address token) external view returns (uint256) {
        return SpokeCrossChainLib.cumulativeIncome(_s, token);
    }

    /// @inheritdoc ISpokeVault
    function positions() external view returns (PositionRef[] memory) {
        return _s.positions;
    }

    /// @inheritdoc ISpokeVault
    function operatingCash() external view returns (uint256) {
        return _s.operatingCash;
    }

    /// @inheritdoc ISpokeVault
    function operatingCashFloor() external view returns (uint256) {
        return _s.operatingCashFloor;
    }

    /// @inheritdoc ISpokeVault
    function operatingCashTopUp() external view returns (uint256) {
        return _s.operatingCashTopUp;
    }

    /// @inheritdoc ISpokeVault
    function cumulativeReceived() external view returns (uint256) {
        return _s.cumulativeReceived;
    }

    /// @inheritdoc ISpokeVault
    function cumulativeSentHome() external view returns (uint256) {
        return _s.cumulativeSentHome;
    }

    /// @inheritdoc ISpokeVault
    function reportSequence() external view returns (uint64) {
        return _s.reportSequence;
    }

    /// @inheritdoc ISpokeVault
    function hubBoundTransit(bytes32 transitId) external view returns (Transit memory) {
        return _s.hubBoundTransits[transitId];
    }

    /// @inheritdoc ISpokeVault
    function hasArrived(bytes32 transitId) external view returns (bool) {
        return _s.arrivals[transitId] != 0;
    }

    /// @notice Principal credited for a hub-to-spoke transit id (OQ-09: a claim the hub confirms by id once it reaches
    ///         the amount the hub expects to arrive, OQ-01).
    function arrivals(bytes32 transitId) external view returns (uint256) {
        return _s.arrivals[transitId];
    }

    /// @notice Hub-bound transit ids still tracked as in flight (pruned lazily when a report is published).
    function inFlightTransitIds() external view returns (bytes32[] memory) {
        return _s.inFlightIds;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The vault's immutable wiring for its linked libraries.
    function _config() internal view returns (SpokeVaultTypes.Config memory) {
        return SpokeVaultTypes.Config({
            fundId: fundId,
            mandateHash: mandateHash,
            chainId: chainId,
            hubChainId: hubChainId,
            coreVault: coreVault,
            baseToken: baseToken,
            hubChainUsdc: hubChainUsdc,
            transitEscrowImplementation: transitEscrowImplementation,
            maxBridgeFeeBps: maxBridgeFeeBps,
            maxReportAge: maxReportAge
        });
    }

    /// @dev DEC-096, DEC-100: below the floor, the next value-moving operation adds `operatingCashTopUp` (or what
    ///      Unallocated Balance of the base token holds, if less) to Operating Cash; the Share Price drop is accepted.
    ///      DEC-041: the expense is booked with its payer, Share Assets. Spoke Chains only (on the hub, Operating Cash
    ///      lives in the Core Vault). Never reverts, so it never blocks an exit (DEC-056).
    function _topUpOperatingCash() internal {
        if (!onHubChain) SpokeCrossChainLib.topUpOperatingCash(_s, baseToken, chainId);
    }
}
