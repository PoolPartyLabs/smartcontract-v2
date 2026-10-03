// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {Mandate, MandateLib, SpokeConfig, PoolConfig, BridgeAdapterConfig} from "../mandate/Mandate.sol";
import {SpokeVaultTypes} from "./SpokeVaultTypes.sol";
import {SpokeCrossChainLib} from "./SpokeCrossChainLib.sol";

/// @title SpokeVaultBase
/// @notice Identity, wiring, storage, modifiers and construction of the Spoke Vault. See ISpokeVault and SpokeVault.
/// @dev Split out of SpokeVault like the Core Vault's layers (WP-07 A3, DEC-131 pattern): the abstract layers
///      (`SpokeVaultBase`, `SpokeVaultUnwind`, `SpokeVaultIncome`) compile into the one `SpokeVault` contract, whose
///      ABI is unchanged. The constructor pins the Mandate's tokens, adapters, swap adapters, pools and bridge
///      adapters of this chain; the layers read the ledger through the internal library `SpokeLedger`.
abstract contract SpokeVaultBase is ISpokeVault, ReentrancyGuard {
    using MandateLib for Mandate;

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
    /// @notice This spoke's report lifetime from the Mandate (DEC-099; value OPEN, Q57 / Q66). 0 on the hub.
    uint32 public immutable maxReportAge;
    /// @dev The Mandate's Hub Wormhole chain id (D-15): the only emitter chain whose orders `executeOrder` accepts
    ///      (DEC-120, DEC-139).
    uint16 internal immutable _hubWormholeChainId;

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
    /// @param excessRecipient_ Destination of swept excess: the Protocol Recipient, the fee wallet (DEC-096, DEC-101,
    ///        DEC-116).
    /// @dev Q17-4 (OPEN, stance: pin in the vault, OQ-13): the codehash of every Mandate adapter on this chain, swap
    ///      adapters included (DEC-136), is pinned here and revalidated on every later call. The ledger's closed token
    ///      list is this chain's Mandate tokens, base token first (DEC-123, DEC-136). OQ-12: `poolTokens` is called for
    ///      every Mandate pool on this chain, which rejects hooked Uniswap V4 pools (DEC-079 open), and each pool token
    ///      must be a Mandate token of this chain (`PoolTokenNotInMandate`, WP-07 B1).
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
        _hubWormholeChainId = mandate_.hubWormholeChainId;
        chainId = chainId_;
        onHubChain = hub;
        coreVault = coreVault_;
        baseToken = baseToken_;
        hubChainUsdc = mandate_.usdc;
        acrossSpokePool = acrossSpokePool_;
        wormholeCore = wormholeCore_;
        transitEscrowImplementation = transitEscrowImplementation_;
        excessRecipient = excessRecipient_;

        _registerToken(baseToken_);
        address[] memory tokens = mandate_.tokensOf(chainId_);
        for (uint256 i; i < tokens.length; ++i) {
            _registerToken(tokens[i]);
        }
        _pinAdapters(mandate_, chainId_);
        _pinSwapAdapters(mandate_, chainId_);
        _pinPools(mandate_, chainId_);
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

    /// @dev DEC-136 (closing note item 1): the Mandate's swap adapters of this chain, each with its pinned codehash
    ///      (Q17-4), in Mandate order.
    function _pinSwapAdapters(Mandate memory m, uint256 chainId_) private {
        for (uint256 i; i < m.swapAdapters.length; ++i) {
            if (m.swapAdapters[i].chainId != chainId_) continue;
            address adapter = m.swapAdapters[i].adapter;
            _s.codehash[adapter] = _requireCode(adapter);
            _s.isSwapAdapter[adapter] = true;
            _s.swapAdapters.push(adapter);
        }
    }

    /// @dev DEC-030 (closed pool list), OQ-12 (hooked pools rejected by `poolTokens`), WP-07 B1 (every pool token is a
    ///      Mandate token of this chain, so the ledger, the report and the swap adapter know every token a position
    ///      can return).
    function _pinPools(Mandate memory m, uint256 chainId_) private {
        for (uint256 i; i < m.pools.length; ++i) {
            PoolConfig memory p = m.pools[i];
            if (p.chainId != chainId_) continue;
            (address token0, address token1) = IAdapter(p.adapter).poolTokens(p.poolKey);
            _s.pools[p.adapter][p.poolKey] = SpokeVaultTypes.PoolTokens(token0, token1, true);
            _requireMandateToken(p, token0);
            _requireMandateToken(p, token1);
        }
    }

    function _requireMandateToken(PoolConfig memory p, address token) private view {
        if (token != address(0) && !_s.isLedgerToken[token]) {
            revert SpokeVaultTypes.PoolTokenNotInMandate(p.adapter, p.poolKey, token);
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
            maxReportAge: maxReportAge
        });
    }

    /// @notice Reserved native Operating Cash hook; disabled in the MVP (ruling 2026-10-02, DEC-187).
    function _topUpOperatingCash() internal pure {}
}
