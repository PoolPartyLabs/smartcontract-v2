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
/// @dev DEC-022, DEC-058: no proxy, no upgrade path, no selfdestruct. The constructor takes everything it needs, so a
///      factory can deploy it at a CREATE2 address. The Spoke Chain half (send home, refunds, report) lives in the
///      linked external library `SpokeCrossChainLib`, which runs by DELEGATECALL over this vault's storage and holds
///      none of its own: its address is part of this vault's creation code and trust surface (immutable, no upgrade
///      path). The factory deploys it once per chain at a chain-independent address (so the vault's CREATE2 address
///      is the same on every chain, DEC-054) and pins its codehash like an adapter's (Q17-4). This is the only
///      DELEGATECALL the vault makes; adapters are always called with a plain CALL.
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
    /// @dev See `SpokeCrossChainLib.sendToHub`: DEC-056, DEC-066, DEC-085, DEC-087, DEC-088, QA6, QA19. OQ-09 stance:
    ///      the transit stays in `inFlightToHub` until its refund is recognized or until `fillDeadline +
    ///      maxReportAge` has passed. `cumulativeSentHome` grows by `amount`.
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
    ///      `ARRIVAL_WINDOW` listed ids plus `cumulativeReceived`) so the hub confirms what it sent and excludes what it
    ///      did not. A repeated id adds to the same entry and is listed once, when its credited total first reaches
    ///      `MIN_LISTED_ARRIVAL`; below it the arrival is credited but never listed (the hub then counts the transit
    ///      once through a fund-level deduction, at a liveness cost: see SpokeVaultTypes.MIN_LISTED_ARRIVAL). DEC-096: an arrival is a value-moving operation, so it runs the
    ///      Operating Cash top-up after crediting, like every other one (Spoke Vault verifier finding).
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
        } else {
            _s.collectedIncome[tokenSent] += amount;
        }
        uint256 before = _s.arrivals[transitId];
        _s.arrivals[transitId] = before + amount;
        if (before < SpokeVaultTypes.MIN_LISTED_ARRIVAL && before + amount >= SpokeVaultTypes.MIN_LISTED_ARRIVAL) {
            _s.recentArrivals[_s.arrivalCount % SpokeVaultTypes.ARRIVAL_WINDOW] = transitId;
            ++_s.arrivalCount;
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
    ///      that (adapter, pool) in registry order; each visited position consumes the next hint, and a missing hint
    ///      reverts (a position is never skipped). An illiquid step reverts (no try/catch). Stops as soon as the USDC
    ///      Unallocated Balance reaches `usdcTarget`.
    /// @dev DEC-059, DEC-067: Unallocated USDC (exact value) is used first; every position, Exact-Value ones included
    ///      (`isExactValue`), is only exited while the target is not reached, so an Exact-Value position is read, not
    ///      exited, when what comes before it covers the target.
    /// @dev Non-USDC principal an exit returns is swapped to USDC through `swapExactInput` in a Mandate pool with the
    ///      hint's per-step minimum output (DEC-081: `usdcTarget` already holds the 2% margin; DEC-097: its Market
    ///      Costs are the fund's). Income from the exits goes to the collected income bucket, never to the proceeds
    ///      (DEC-092).
    /// @param unwindHints `abi.encode(SpokeVaultTypes.UnwindHint[])`, one hint per position visited.
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

        address usdc = baseToken;
        uint256 used;
        for (uint256 s; s < _s.unwindOrder.length && _s.unallocated[usdc] < usdcTarget; ++s) {
            UnwindStep memory step = _s.unwindOrder[s];
            bytes32[] memory keys = _positionKeysOf(step.adapter, step.poolKey);
            for (uint256 k; k < keys.length && _s.unallocated[usdc] < usdcTarget; ++k) {
                if (used == hints.length) revert SpokeVaultTypes.MissingUnwindHint(step.adapter, keys[k]);
                _unwindPosition(step.adapter, keys[k], hints[used++]);
            }
        }

        usdcProceeds = Math.min(_s.unallocated[usdc], usdcTarget);
        if (usdcProceeds != 0) {
            _s.unallocated[usdc] -= usdcProceeds;
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

    /// @notice Amount credited for a hub-to-spoke transit id (OQ-09: a claim the hub confirms by id).
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
    ///      income bucket, both from what the adapter returned.
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
            _removePosition(adapter, positionKey);
            emit PositionClosed(adapter, positionKey, amounts);
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

    /// @dev One unwind step on one position: exit per the hint, then swap the non-USDC principal the exit returned.
    function _unwindPosition(address adapter, bytes32 positionKey, SpokeVaultTypes.UnwindHint memory hint) internal {
        (IAdapter.Amounts memory amounts, SpokeVaultTypes.PoolTokens memory p) = _exit(
            adapter,
            positionKey,
            hint.close ? SpokeVaultTypes.ExitKind.Close : SpokeVaultTypes.ExitKind.Decrease,
            hint.exitParams
        );
        address usdc = baseToken;
        uint256 left0 = p.token0 == usdc ? 0 : amounts.principal0;
        uint256 left1 = p.token1 == usdc ? 0 : amounts.principal1;
        for (uint256 i; i < hint.swaps.length; ++i) {
            SpokeVaultTypes.UnwindSwap memory sw = hint.swaps[i];
            uint256 amountIn;
            if (sw.tokenIn == p.token0 && p.token0 != usdc) {
                (amountIn, left0) = (left0, 0);
            } else if (sw.tokenIn == p.token1 && p.token1 != usdc) {
                (amountIn, left1) = (left1, 0);
            } else {
                revert SpokeVaultTypes.InvalidUnwindSwap(sw.adapter, sw.poolKey, sw.tokenIn);
            }
            // Nothing of that token came out of this exit (or an earlier swap took it): nothing to swap.
            if (amountIn == 0) continue;
            IAdapter swapAdapter = _positionAdapter(sw.adapter);
            SpokeVaultTypes.PoolTokens memory sp = _pool(sw.adapter, sw.poolKey);
            if (_otherToken(sp, sw.tokenIn) != usdc) {
                revert SpokeVaultTypes.InvalidUnwindSwap(sw.adapter, sw.poolKey, sw.tokenIn);
            }
            _swap(swapAdapter, sp, sw.poolKey, sw.tokenIn, amountIn, sw.minAmountOut, sw.params, false);
        }
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
