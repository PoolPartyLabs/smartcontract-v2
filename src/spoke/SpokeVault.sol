// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";

import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {Transit, TransferKind, ExpensePayer, BridgeQuote} from "../interfaces/FundTypes.sol";
import {Mandate, MandateLib, SpokeConfig, PoolConfig, UnwindStep, BridgeAdapterConfig} from "../mandate/Mandate.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {TransitMessage} from "../libraries/TransitMessage.sol";
import {SpokeVaultTypes} from "./SpokeVaultTypes.sol";
import {SpokeCrossChainLib} from "./SpokeCrossChainLib.sol";

/// @title SpokeVault
/// @notice The fund's account on one chain, the Hub Chain included. See ISpokeVault.
/// @dev DEC-054: one Spoke Vault per fund chain, the Hub Chain included; `onHubChain` selects the role. The hub role
///      talks to the Core Vault, publishes no report and holds no Operating Cash; the spoke role receives Across fills,
///      sends home and publishes value reports through the Wormhole Core Bridge.
/// @dev DEC-022, DEC-058: no proxy, no upgrade path, no selfdestruct. The constructor takes everything it needs, so the
///      FundFactory deploys it at a CREATE3 address that depends only on the factory and the salt (fund id, role,
///      chain id), never on this creation code (DEC-054). The Spoke Chain half (send home, refunds, report) lives in the
///      linked external library `SpokeCrossChainLib`, which runs by DELEGATECALL over this vault's storage and holds
///      none of its own: its address is part of this vault's creation code and trust surface (immutable, no upgrade
///      path). The operator deploys it once per chain at a chain-independent address (so the linked creation code and
///      its hash are the same on every chain) and the factory stores that code with its hash fixed at construction.
///      This is the only DELEGATECALL the vault makes; adapters are always called with a plain CALL.
/// @dev DEC-080: every value that reaches a base comes from the internal ledger (`unallocated`, `collectedIncome`,
///      `operatingCash`), never from `balanceOf`. `balanceOf` is read only to assert the ledger is backed, to verify
///      an exact bridge debit and to size the excess sweep.
contract SpokeVault is ISpokeVault, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MandateLib for Mandate;

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
    ///      can be moved within a block by the claimant); a claimant hint may only raise the minimum.
    uint256 public constant MAX_UNWIND_SLIPPAGE_BPS = 500;

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
        IAdapter a = _positionAdapter(adapter);
        SpokeVaultTypes.PoolTokens memory p = _pool(adapter, poolKey);
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();
        _topUpOperatingCash();
        _sendToAdapter(adapter, p.token0, amount0);
        _sendToAdapter(adapter, p.token1, amount1);
        (positionKey, used0, used1) = a.openPosition(poolKey, params);
        _creditUnused(adapter, p, amount0, used0, amount1, used1);
        if (_s.positionSlot[adapter][positionKey] != 0) {
            revert SpokeVaultTypes.PositionAlreadyRegistered(adapter, positionKey);
        }
        _s.positions.push(PositionRef(adapter, positionKey, poolKey));
        _s.positionSlot[adapter][positionKey] = _s.positions.length;
        _requireBacked(p);
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
        IAdapter a = _positionAdapter(adapter);
        SpokeVaultTypes.PoolTokens memory p = _pool(adapter, _positionPool(adapter, positionKey));
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();
        _topUpOperatingCash();
        _sendToAdapter(adapter, p.token0, amount0);
        _sendToAdapter(adapter, p.token1, amount1);
        (used0, used1, income0, income1) = a.increasePosition(positionKey, params);
        _creditUnused(adapter, p, amount0, used0, amount1, used1);
        _credit(p, IAdapter.Amounts(0, 0, income0, income1));
        _requireBacked(p);
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
        (amounts,) = _exit(adapter, positionKey, SpokeVaultTypes.ExitKind.Decrease, params);
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
        (amounts,) = _exit(adapter, positionKey, SpokeVaultTypes.ExitKind.Close, params);
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
        (amounts,) = _exit(adapter, positionKey, SpokeVaultTypes.ExitKind.Collect, "");
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
        IAdapter a = _positionAdapter(adapter);
        SpokeVaultTypes.PoolTokens memory p = _pool(adapter, poolKey);
        _topUpOperatingCash();
        amountOut = _swap(a, p, poolKey, tokenIn, amountIn, minAmountOut, params, false);
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
        IAdapter a = _positionAdapter(adapter);
        SpokeVaultTypes.PoolTokens memory p = _pool(adapter, poolKey);
        if (_otherToken(p, tokenIn) != baseToken) revert UnexpectedToken(tokenIn);
        _topUpOperatingCash();
        amountOut = _swap(a, p, poolKey, tokenIn, amountIn, minAmountOut, params, true);
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
    ///      did not. A repeated id adds to the same entry and is listed once, when its credited total first reaches
    ///      `MIN_LISTED_ARRIVAL`; below it the arrival is credited but never listed (the hub then counts the transit
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

        if (kind == TransferKind.Principal) {
            _s.unallocated[tokenSent] += amount;
            _s.cumulativeReceived += amount;
            uint256 before = _s.arrivals[transitId];
            _s.arrivals[transitId] = before + amount;
            if (before < SpokeVaultTypes.MIN_LISTED_ARRIVAL && before + amount >= SpokeVaultTypes.MIN_LISTED_ARRIVAL) {
                _s.recentArrivals[_s.arrivalCount % SpokeVaultTypes.ARRIVAL_WINDOW] = transitId;
                ++_s.arrivalCount;
            }
        } else {
            _s.collectedIncome[tokenSent] += amount;
        }
        _requireBacked(tokenSent);
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
        _requireBacked(baseToken);
        emit ReceivedFromCoreVault(amount);
    }

    /// @inheritdoc ISpokeVault
    function returnToCoreVault(uint256 amount) external onlyOnHubChain onlyManager nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _debitUnallocated(baseToken, amount);
        _payCoreVaultIdle(amount);
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
    /// @dev DEC-069: walks the Mandate unwind order restricted to this chain; within a step, every open position of
    ///      that (adapter, pool) in registry order. An illiquid step reverts (no try/catch, a position is never
    ///      skipped). The stop condition (USDC Unallocated Balance at `usdcTarget`) is re-evaluated before every
    ///      position.
    /// @dev Final verification (DEC-069, DEC-081, DEC-097, QA3 OPEN): the vault, not the claimant, sizes every step.
    ///      For each position it values the principal in USDC (`IAdapter.positionValue`, non-USDC legs at the route's
    ///      `spotQuote`), takes the shortfall still needed (`usdcTarget` minus the USDC Unallocated Balance so far)
    ///      and asks the adapter for the exit that removes only that share (`IAdapter.unwindExitParams`); the whole
    ///      position is closed only when its whole value is needed. A position with no principal value is skipped.
    /// @dev DEC-059, DEC-067: Unallocated USDC (exact value) is used first; every position, Exact-Value ones included
    ///      (`isExactValue`), is only exited while the target is not reached, so an Exact-Value position is read, not
    ///      exited, when what comes before it covers the target.
    /// @dev Non-USDC principal an exit returns is swapped to USDC through `swapExactInput` with a minimum output of
    ///      at least the route's spot quote less `MAX_UNWIND_SLIPPAGE_BPS` (DEC-081: `usdcTarget` already holds the 2%
    ///      margin; DEC-097: its Market Costs are the fund's). The claimant's hints can only raise that minimum or
    ///      restrict the swap; they never size an exit. Income from the exits goes to the collected income bucket,
    ///      never to the proceeds (DEC-092).
    /// @param unwindHints `abi.encode(SpokeVaultTypes.UnwindHint[])`, optional, one per position visited in order.
    function unwindForPayout(uint256 usdcTarget, bytes calldata unwindHints)
        external
        onlyOnHubChain
        nonReentrant
        returns (uint256 usdcProceeds)
    {
        if (msg.sender != coreVault) revert NotCoreVault(msg.sender);
        if (usdcTarget == 0) revert ZeroAmount();
        SpokeVaultTypes.UnwindHint[] memory hints = unwindHints.length == 0
            ? new SpokeVaultTypes.UnwindHint[](0)
            : abi.decode(unwindHints, (SpokeVaultTypes.UnwindHint[]));

        uint256 visited;
        for (uint256 s; s < _s.unwindOrder.length && _s.unallocated[baseToken] < usdcTarget; ++s) {
            visited = _unwindStep(_s.unwindOrder[s], hints, visited, usdcTarget);
        }

        usdcProceeds = Math.min(_s.unallocated[baseToken], usdcTarget);
        if (usdcProceeds != 0) {
            _s.unallocated[baseToken] -= usdcProceeds;
            _payCoreVaultIdle(usdcProceeds);
        }
        emit UnwoundForPayout(usdcTarget, usdcProceeds);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Garbage collector
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeVault
    /// @dev DEC-080, DEC-096, DEC-101: excess = balance minus Unallocated Balance, collected income (dust included)
    ///      and Operating Cash; ledger value is never swept. Returns 0 when there is no excess.
    function sweepExcess(address token) external nonReentrant returns (uint256 amount) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 ledger = _ledgerTotal(token);
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
        SpokeVaultTypes.PoolTokens memory p = _pool(adapter, poolKey);
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
    // Internal: adapters and positions
    // ---------------------------------------------------------------------------------------------------------------

    function _config() internal view returns (SpokeVaultTypes.Config memory) {
        return SpokeVaultTypes.Config({
            fundId: fundId,
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

    /// @dev DEC-053: Mandate adapters on this chain only. Q17-4: the pinned codehash must still match.
    function _positionAdapter(address adapter) internal view returns (IAdapter) {
        if (!_s.isPositionAdapter[adapter]) revert AdapterNotInMandate(adapter);
        bytes32 expected = _s.codehash[adapter];
        bytes32 actual = adapter.codehash;
        if (actual != expected) revert AdapterCodehashMismatch(adapter, expected, actual);
        return IAdapter(adapter);
    }

    /// @dev DEC-030: Mandate pools on this chain only.
    function _pool(address adapter, bytes32 poolKey) internal view returns (SpokeVaultTypes.PoolTokens memory p) {
        p = _s.pools[adapter][poolKey];
        if (!p.listed) revert PoolNotInMandate(adapter, poolKey);
    }

    function _positionPool(address adapter, bytes32 positionKey) internal view returns (bytes32) {
        uint256 slot = _s.positionSlot[adapter][positionKey];
        if (slot == 0) revert UnknownPosition(adapter, positionKey);
        return _s.positions[slot - 1].poolKey;
    }

    function _removePosition(address adapter, bytes32 positionKey) internal {
        uint256 slot = _s.positionSlot[adapter][positionKey];
        uint256 last = _s.positions.length;
        if (slot != last) {
            PositionRef memory moved = _s.positions[last - 1];
            _s.positions[slot - 1] = moved;
            _s.positionSlot[moved.adapter][moved.positionKey] = slot;
        }
        _s.positions.pop();
        delete _s.positionSlot[adapter][positionKey];
    }

    /// @dev Whether `a` still lists `positionKey` among its open positions.
    function _adapterLists(IAdapter a, bytes32 positionKey) internal view returns (bool) {
        bytes32[] memory keys = a.positionKeys();
        for (uint256 i; i < keys.length; ++i) {
            if (keys[i] == positionKey) return true;
        }
        return false;
    }

    function _positionKeysOf(address adapter, bytes32 poolKey) internal view returns (bytes32[] memory keys) {
        uint256 n = _s.positions.length;
        keys = new bytes32[](n);
        uint256 found;
        for (uint256 i; i < n; ++i) {
            PositionRef storage ref = _s.positions[i];
            if (ref.adapter == adapter && ref.poolKey == poolKey) keys[found++] = ref.positionKey;
        }
        assembly ("memory-safe") {
            mstore(keys, found)
        }
    }

    /// @dev DEC-056, DEC-079: decrease, close or collect; principal to Unallocated Balance, income to the collected
    ///      income bucket, both from what the adapter returned. A close leaves the registry only when the adapter no
    ///      longer lists the key: an adapter may keep it open holding income the protocol could not pay yet (Aave
    ///      reserve liquidity, final verification, DEC-056, DEC-068), and that income stays reachable and reported.
    function _exit(address adapter, bytes32 positionKey, SpokeVaultTypes.ExitKind kind, bytes memory params)
        internal
        returns (IAdapter.Amounts memory amounts, SpokeVaultTypes.PoolTokens memory p)
    {
        IAdapter a = _positionAdapter(adapter);
        p = _pool(adapter, _positionPool(adapter, positionKey));
        if (kind == SpokeVaultTypes.ExitKind.Decrease) {
            amounts = a.decreasePosition(positionKey, params);
            emit PositionDecreased(adapter, positionKey, amounts);
        } else if (kind == SpokeVaultTypes.ExitKind.Close) {
            amounts = a.closePosition(positionKey, params);
            if (_adapterLists(a, positionKey)) {
                emit PositionDecreased(adapter, positionKey, amounts);
            } else {
                _removePosition(adapter, positionKey);
                emit PositionClosed(adapter, positionKey, amounts);
            }
        } else {
            amounts = a.collectIncome(positionKey);
            emit IncomeCollected(adapter, positionKey, amounts.income0, amounts.income1);
        }
        _credit(p, amounts);
        _requireBacked(p);
    }

    /// @dev Swaps `tokenIn` for the pool's other token (DEC-079, DEC-080), from and into Unallocated Balance, or from
    ///      and into the collected income bucket when `income` is true (DEC-092: the two never mix).
    function _swap(
        IAdapter a,
        SpokeVaultTypes.PoolTokens memory p,
        bytes32 poolKey,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes memory params,
        bool income
    ) internal returns (uint256 amountOut) {
        address tokenOut = _otherToken(p, tokenIn);
        if (amountIn == 0) revert ZeroAmount();
        if (income) {
            uint256 available = _s.collectedIncome[tokenIn];
            if (amountIn > available) revert InsufficientCollectedIncome(tokenIn, available, amountIn);
            _s.collectedIncome[tokenIn] = available - amountIn;
            IERC20(tokenIn).safeTransfer(address(a), amountIn);
        } else {
            _sendToAdapter(address(a), tokenIn, amountIn);
        }
        amountOut = a.swapExactInput(poolKey, tokenIn, amountIn, minAmountOut, params);
        if (amountOut < minAmountOut) revert SpokeVaultTypes.SwapOutputBelowMinimum(amountOut, minAmountOut);
        if (income) {
            _s.collectedIncome[tokenOut] += amountOut;
            emit IncomeSwapped(address(a), poolKey, tokenIn, tokenOut, amountIn, amountOut);
        } else {
            _s.unallocated[tokenOut] += amountOut;
            emit Swapped(address(a), poolKey, tokenIn, tokenOut, amountIn, amountOut);
        }
        _requireBacked(tokenOut);
    }

    function _otherToken(SpokeVaultTypes.PoolTokens memory p, address tokenIn) internal pure returns (address out) {
        if (tokenIn != address(0)) {
            if (tokenIn == p.token0) out = p.token1;
            else if (tokenIn == p.token1) out = p.token0;
        }
        if (out == address(0)) revert UnexpectedToken(tokenIn);
    }

    /// @dev Every open position of one Mandate unwind step, in registry order, while the target is not reached; the
    ///      `visited`-th position takes the `visited`-th hint, if any. Returns the positions visited so far.
    function _unwindStep(
        UnwindStep memory step,
        SpokeVaultTypes.UnwindHint[] memory hints,
        uint256 visited,
        uint256 usdcTarget
    ) internal returns (uint256) {
        bytes32[] memory keys = _positionKeysOf(step.adapter, step.poolKey);
        for (uint256 k; k < keys.length; ++k) {
            uint256 held = _s.unallocated[baseToken];
            if (held >= usdcTarget) break;
            SpokeVaultTypes.UnwindSwap[] memory swaps;
            if (visited < hints.length) swaps = hints[visited].swaps;
            ++visited;
            _unwindPosition(step.adapter, step.poolKey, keys[k], usdcTarget - held, swaps);
        }
        return visited;
    }

    /// @dev One unwind step on one position (final verification): value the principal in USDC, exit only the share
    ///      of it the `shortfall` needs (the whole position when its whole value is needed), then swap the non-USDC
    ///      principal the exit returned into USDC above the vault's floor.
    function _unwindPosition(
        address adapter,
        bytes32 poolKey,
        bytes32 positionKey,
        uint256 shortfall,
        SpokeVaultTypes.UnwindSwap[] memory swaps
    ) internal {
        IAdapter a = _positionAdapter(adapter);
        SpokeVaultTypes.PoolTokens memory p = _pool(adapter, poolKey);
        SpokeVaultTypes.UnwindSwap memory r0 = _unwindRoute(adapter, poolKey, p, p.token0, swaps);
        SpokeVaultTypes.UnwindSwap memory r1 = _unwindRoute(adapter, poolKey, p, p.token1, swaps);
        uint256 value;
        {
            IAdapter.PositionValue memory v = a.positionValue(positionKey);
            value = _unwindValue(r0, v.principal0) + _unwindValue(r1, v.principal1);
        }
        if (value == 0) return;
        (bool close, bytes memory params) = a.unwindExitParams(positionKey, Math.min(shortfall, value), value);
        (IAdapter.Amounts memory amounts,) = _exit(
            adapter, positionKey, close ? SpokeVaultTypes.ExitKind.Close : SpokeVaultTypes.ExitKind.Decrease, params
        );
        _unwindSwap(r0, amounts.principal0);
        _unwindSwap(r1, amounts.principal1);
    }

    /// @dev The swap route of `token` into USDC for an unwind exit: none for USDC (or a missing token1); the
    ///      position's own pool when it pairs `token` with USDC (a hint for `token` must then name that same route);
    ///      otherwise the hint's route, which must be a Mandate pool of a Mandate adapter pairing `token` with USDC.
    ///      The hint entry's `minAmountOut` and `params` travel with the route.
    function _unwindRoute(
        address adapter,
        bytes32 poolKey,
        SpokeVaultTypes.PoolTokens memory p,
        address token,
        SpokeVaultTypes.UnwindSwap[] memory swaps
    ) internal view returns (SpokeVaultTypes.UnwindSwap memory r) {
        address usdc = baseToken;
        if (token == usdc || token == address(0)) return r;
        for (uint256 i; i < swaps.length; ++i) {
            if (swaps[i].tokenIn == token) r = swaps[i];
        }
        if (_otherToken(p, token) == usdc) {
            if (r.adapter != address(0) && (r.adapter != adapter || r.poolKey != poolKey)) {
                revert SpokeVaultTypes.InvalidUnwindSwap(r.adapter, r.poolKey, token);
            }
            (r.adapter, r.poolKey, r.tokenIn) = (adapter, poolKey, token);
        } else {
            if (r.adapter == address(0)) revert SpokeVaultTypes.MissingUnwindSwap(token);
            _positionAdapter(r.adapter);
            if (_otherToken(_pool(r.adapter, r.poolKey), token) != usdc) {
                revert SpokeVaultTypes.InvalidUnwindSwap(r.adapter, r.poolKey, token);
            }
        }
    }

    /// @dev USDC value of `amount` of a route's token at the route's spot price; USDC itself (no route) at par.
    function _unwindValue(SpokeVaultTypes.UnwindSwap memory r, uint256 amount) internal view returns (uint256) {
        if (amount == 0 || r.adapter == address(0)) return amount;
        return IAdapter(r.adapter).spotQuote(r.poolKey, r.tokenIn, amount);
    }

    /// @dev Swaps `amountIn` along route `r` into USDC with a minimum output of at least the higher of the route's
    ///      spot quote and the Core Vault's price-source value, less `MAX_UNWIND_SLIPPAGE_BPS`; the hint's minimum
    ///      only when it is higher (final verification, QA3 OPEN).
    /// @dev Security review S-2: the claimant runs this inside its own transaction and can move `slot0` first, so a
    ///      floor measured against the spot quote alone followed the moved price. The price-source value (Chainlink
    ///      for WETH, the price Share Assets use) cannot be moved in the same block; a pushed-down spot now makes the
    ///      swap revert, the whole unwind reverts and the claim is paid from Idle only (DEC-068). A reverting price
    ///      source reverts the unwind the same way (the claim itself never reverts, `CoreVault._unwindForPayout`).
    function _unwindSwap(SpokeVaultTypes.UnwindSwap memory r, uint256 amountIn) internal {
        if (amountIn == 0 || r.adapter == address(0)) return;
        IAdapter a = IAdapter(r.adapter);
        (uint256 oracleValue,) = IPriceSource(ICoreVault(coreVault).priceSource()).usdcValue(r.tokenIn, amountIn);
        uint256 floor = Math.mulDiv(
            Math.max(a.spotQuote(r.poolKey, r.tokenIn, amountIn), oracleValue),
            MandateLib.BPS - MAX_UNWIND_SLIPPAGE_BPS,
            MandateLib.BPS
        );
        _swap(
            a,
            _pool(r.adapter, r.poolKey),
            r.poolKey,
            r.tokenIn,
            amountIn,
            Math.max(floor, r.minAmountOut),
            r.params,
            false
        );
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internal: ledger (DEC-080)
    // ---------------------------------------------------------------------------------------------------------------

    function _sendToAdapter(address adapter, address token, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) revert UnexpectedToken(token);
        _debitUnallocated(token, amount);
        IERC20(token).safeTransfer(adapter, amount);
    }

    function _creditUnused(
        address adapter,
        SpokeVaultTypes.PoolTokens memory p,
        uint256 sent0,
        uint256 used0,
        uint256 sent1,
        uint256 used1
    ) internal {
        if (used0 > sent0) revert SpokeVaultTypes.AdapterUsedAboveInput(adapter, p.token0, sent0, used0);
        if (used1 > sent1) revert SpokeVaultTypes.AdapterUsedAboveInput(adapter, p.token1, sent1, used1);
        if (sent0 != used0) _s.unallocated[p.token0] += sent0 - used0;
        if (sent1 != used1) _s.unallocated[p.token1] += sent1 - used1;
    }

    /// @dev DEC-079: principal to Unallocated Balance, income to the collected income bucket (DEC-092).
    function _credit(SpokeVaultTypes.PoolTokens memory p, IAdapter.Amounts memory a) internal {
        if (p.token1 == address(0) && (a.principal1 != 0 || a.income1 != 0)) revert UnexpectedToken(address(0));
        _s.unallocated[p.token0] += a.principal0;
        _s.collectedIncome[p.token0] += a.income0;
        if (p.token1 != address(0)) {
            _s.unallocated[p.token1] += a.principal1;
            _s.collectedIncome[p.token1] += a.income1;
        }
    }

    function _debitUnallocated(address token, uint256 amount) internal {
        uint256 available = _s.unallocated[token];
        if (amount > available) revert InsufficientUnallocatedBalance(token, available, amount);
        _s.unallocated[token] = available - amount;
    }

    function _ledgerTotal(address token) internal view returns (uint256 total) {
        total = _s.unallocated[token] + _s.collectedIncome[token];
        if (token == baseToken) total += _s.operatingCash;
    }

    /// @dev DEC-080 fitness function: the ledger never exceeds the balance. An adapter or a caller that reports more
    ///      than it delivered makes the operation revert instead of inflating a value base.
    function _requireBacked(address token) internal view {
        if (token == address(0)) return;
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 ledger = _ledgerTotal(token);
        if (balance < ledger) revert SpokeVaultTypes.LedgerExceedsBalance(token, balance, ledger);
    }

    function _requireBacked(SpokeVaultTypes.PoolTokens memory p) internal view {
        _requireBacked(p.token0);
        _requireBacked(p.token1);
    }

    /// @dev DEC-096, DEC-100: below the floor, the next value-moving operation adds `operatingCashTopUp` (or what
    ///      Unallocated Balance of the base token holds, if less) to Operating Cash; the Share Price drop is accepted.
    ///      DEC-041: the expense is booked with its payer, Share Assets. Spoke Chains only (on the hub, Operating Cash
    ///      lives in the Core Vault). Never reverts, so it never blocks an exit (DEC-056).
    function _topUpOperatingCash() internal {
        if (onHubChain) return;
        uint256 cash = _s.operatingCash;
        if (cash >= _s.operatingCashFloor) return;
        uint256 amount = Math.min(_s.operatingCashTopUp, _s.unallocated[baseToken]);
        if (amount == 0) return;
        _s.unallocated[baseToken] -= amount;
        _s.operatingCash = cash + amount;
        emit OperatingCashToppedUp(amount, cash + amount);
        emit OperatingExpensePaid(chainId, address(0), OPERATING_CASH_TOP_UP, amount, ExpensePayer.ShareAssets);
    }

    function _payCoreVaultIdle(uint256 amount) internal {
        IERC20(baseToken).safeTransfer(coreVault, amount);
        ICoreVault(coreVault).returnToIdle(amount);
    }
}
