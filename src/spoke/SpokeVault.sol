// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";

import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {Transit, TransferKind} from "../interfaces/FundTypes.sol";
import {Mandate} from "../mandate/Mandate.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {TransitMessage} from "../libraries/TransitMessage.sol";
import {SpokeVaultTypes} from "./SpokeVaultTypes.sol";
import {SpokeCrossChainLib} from "./SpokeCrossChainLib.sol";
import {SpokeLedger} from "./SpokeLedger.sol";
import {SpokeVaultBase} from "./SpokeVaultBase.sol";
import {SpokeVaultUnwind} from "./SpokeVaultUnwind.sol";
import {SpokeVaultIncome} from "./SpokeVaultIncome.sol";

/// @title SpokeVault
/// @notice The fund's account on one chain, the Hub Chain included. See ISpokeVault.
/// @dev DEC-054: one Spoke Vault per fund chain, the Hub Chain included; `onHubChain` selects the role. The hub role
///      talks to the Core Vault, publishes no report and holds no Operating Cash; the spoke role receives Across fills,
///      sends home and publishes value reports through the Wormhole Core Bridge.
/// @dev The source is split by concern like the Core Vault's (WP-07 A3, DEC-131 pattern): `SpokeVaultBase` (identity,
///      wiring, storage, modifiers, construction), `SpokeVaultUnwind` (the automatic unwind), `SpokeVaultIncome` (the
///      collected income verbs) and this contract (the manager's position verbs, the cross-chain verbs, the hub
///      interplay, the garbage collector and the views), compiled into one contract with an unchanged ABI.
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
contract SpokeVault is SpokeVaultUnwind, SpokeVaultIncome {
    using SafeERC20 for IERC20;
    using SpokeLedger for SpokeVaultTypes.State;

    /// @dev DEC-093: reports are published with finalized consistency.
    uint8 internal constant WORMHOLE_FINALIZED = 1;

    /// @dev Wormhole nonce: a batching tag only; replay protection is the (emitter, sequence) pair (DEC-093).
    uint32 internal constant WORMHOLE_NONCE = 0;

    // ---------------------------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev See SpokeVaultBase for the parameters and the pins (DEC-053, DEC-058, Q17-4, OQ-12, DEC-087, DEC-088).
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
    )
        SpokeVaultBase(
            mandate_,
            fundId_,
            chainId_,
            coreVault_,
            baseToken_,
            acrossSpokePool_,
            wormholeCore_,
            transitEscrowImplementation_,
            excessRecipient_
        )
    {}

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
    /// @dev DEC-136, DEC-142, DEC-143, DEC-153; founder, 2026-10-02 ("swaps are not done in the fund pools"). The
    ///      custody and ledger checks are `SpokeLedger.swapThrough`; the swap adapter applies the route, the maximum
    ///      loss and its own pause and deprecation (DEC-056: a swap into the base token always runs).
    function swap(
        address swapAdapter,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint16 maxLossBps,
        bytes calldata route
    ) external onlyManager nonReentrant returns (uint256 amountOut) {
        _topUpOperatingCash();
        uint256 spotOut;
        uint256 minOut;
        (amountOut, spotOut, minOut) =
            _s.swapThrough(swapAdapter, tokenIn, tokenOut, amountIn, maxLossBps, route, false);
        emit Swapped(swapAdapter, tokenIn, tokenOut, amountIn, amountOut, spotOut, maxLossBps, minOut);
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
    /// @dev See `SpokeCrossChainLib.sendHome`: DEC-056, DEC-066, DEC-085, DEC-087, DEC-088, DEC-158, DEC-162, QA6, QA19.
    ///      No bridge data: the Across adapter refuses any (DEC-176: no signed quote in the MVP). Security review S-3:
    ///      the transit stays in `inFlightToHub` until its refund is recognized (by anyone, or at the next report or
    ///      send once it landed) or until `fillDeadline + ReportCodec.HUB_BOUND_RETENTION` has passed.
    ///      `cumulativeSentHome` grows by `amount`.
    function sendToHub(uint256 amount, TransferKind kind, uint256 bridgeRank)
        external
        onlyOnSpokeChain
        onlyManager
        nonReentrant
        returns (bytes32 transitId)
    {
        _topUpOperatingCash();
        transitId = SpokeCrossChainLib.sendHome(_s, _config(), amount, kind, bridgeRank, "");
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
    /// @dev Position, bridge and swap adapters alike (DEC-087: a bridge is an Adapter; DEC-136).
    function adapterCodehash(address adapter) external view returns (bytes32) {
        return _s.codehash[adapter];
    }

    /// @inheritdoc ISpokeVault
    function swapAdapters() external view returns (address[] memory) {
        return _s.swapAdapters;
    }

    /// @inheritdoc ISpokeVault
    function isMandateToken(address token) external view returns (bool) {
        return _s.isLedgerToken[token];
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
    /// @dev The closed list: this chain's Mandate tokens, base token first (DEC-136).
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
}
