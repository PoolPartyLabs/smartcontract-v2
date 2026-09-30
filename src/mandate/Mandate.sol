// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A position adapter deployed on one chain of the fund.
/// @dev DEC-053, DEC-058: closed list, fixed at creation; no adapter may be added to a live fund.
struct AdapterConfig {
    uint256 chainId;
    address adapter;
}

/// @notice A pool the manager may open positions in, through a given adapter on a given chain.
/// @dev DEC-030: every pool the manager may operate is listed in the Mandate. `poolKey` is adapter-specific.
struct PoolConfig {
    uint256 chainId;
    address adapter;
    bytes32 poolKey;
}

/// @notice One step of the automatic unwind order.
/// @dev DEC-069: fixed at creation, used only for automatic unwind on the payout claim path.
struct UnwindStep {
    uint256 chainId;
    address adapter;
    bytes32 poolKey;
}

/// @notice A Spoke Chain of the fund.
/// @param chainId EVM chain id of the spoke (Robinhood Chain: 4663).
/// @param wormholeChainId Wormhole chain id of the spoke (Robinhood Chain: 72), the report emitter chain (DEC-086).
/// @param spokeVault The fund's Spoke Vault on that chain, as a universal address; the only accepted report emitter
///        (DEC-086) and the only accepted bridge recipient on that chain (DEC-087).
/// @param spokeToken Token the Transport Route delivers on the spoke (Robinhood: USDG). A route property, not a product
///        rule (DEC-055, DEC-031).
/// @param spokeCap Maximum fund principal the manager may allocate to the spoke, in hub USDC base units, checked only
///        on send and counting In-flight Value at the amount sent (DEC-031, DEC-037, DEC-066, DEC-095).
/// @param maxReportAge Report lifetime in seconds (DEC-094, DEC-099: spoke time to finality plus one block; value
///        OPEN, Q57 / Q66, research value for Robinhood 1,587 s).
struct SpokeConfig {
    uint256 chainId;
    uint16 wormholeChainId;
    bytes32 spokeVault;
    address spokeToken;
    uint256 spokeCap;
    uint32 maxReportAge;
}

/// @notice A bridge adapter serving one spoke, deployed on one side of the route.
/// @dev DEC-087, DEC-088: bridge adapters are Adapters, fixed at creation, listed in order per spoke chain. For a
///      given `(spokeChainId, chainId)` pair the order of appearance in `Mandate.bridgeAdapters` is the priority:
///      the first is the primary, the next ones are fallbacks.
/// @param spokeChainId EVM chain id of the spoke this route serves.
/// @param chainId EVM chain id where the adapter is deployed: the Hub Chain for hub-to-spoke sends, the spoke for
///        spoke-to-hub sends.
/// @param adapter Adapter address.
struct BridgeAdapterConfig {
    uint256 spokeChainId;
    uint256 chainId;
    address adapter;
}

/// @notice Initial Operating Cash parameters of one chain, in the base units of the chain's base token.
/// @dev DEC-096, DEC-100: per-chain floor and top-up; the manager may adjust them on a live fund, so the live values
///      live in the vaults and these are only the creation values.
struct OperatingCashConfig {
    uint256 chainId;
    uint256 floor;
    uint256 topUp;
}

/// @notice The rules of a fund, written once at creation (DEC-053).
/// @dev Every array holds value-only structs so a vault can copy the Mandate into storage element by element.
/// @param manager Fund manager (DEC-002; manager transfer OPEN, immutable in the MVP).
/// @param hubChainId EVM chain id of the Hub Chain (DEC-011).
/// @param usdc USDC on the Hub Chain, the only deposit and payout asset (DEC-011).
/// @param adapters Closed list of position adapters per chain, hub included (DEC-053, DEC-054, DEC-058).
/// @param pools Closed list of pools per adapter (DEC-030).
/// @param unwindOrder Ordered steps for automatic unwind (DEC-069).
/// @param spokes Spoke Chains (DEC-031, DEC-037, DEC-095).
/// @param bridgeAdapters Bridge adapters per spoke, in priority order (DEC-087, DEC-088).
/// @param operatingCash Initial Operating Cash floor and top-up per chain (DEC-096).
/// @param payoutFeeBps Payout Fee on Instant Payouts, in bps; immutable (DEC-006, DEC-075, DEC-095, DEC-102, DEC-110).
/// @param standardPayoutTerm Standard Payout term, in seconds (DEC-060, DEC-095).
/// @param minFirstDeposit Minimum first deposit, in USDC base units; no protocol floor (DEC-061, DEC-095, erratum 22).
/// @param performanceFeeBps Manager performance fee on collected income, in bps; may only decrease (DEC-107, DEC-110).
/// @param managementFeeBps Manager management fee, in bps per year; the MVP accepts only 0 (DEC-108, LC-144 OPEN).
/// @param maxBridgeFeeBps Maximum bridge fee per send, in bps of the amount sent (DEC-030 exception; value OPEN, QA19).
struct Mandate {
    address manager;
    uint256 hubChainId;
    address usdc;
    AdapterConfig[] adapters;
    PoolConfig[] pools;
    UnwindStep[] unwindOrder;
    SpokeConfig[] spokes;
    BridgeAdapterConfig[] bridgeAdapters;
    OperatingCashConfig[] operatingCash;
    uint16 payoutFeeBps;
    uint32 standardPayoutTerm;
    uint256 minFirstDeposit;
    uint16 performanceFeeBps;
    uint16 managementFeeBps;
    uint16 maxBridgeFeeBps;
}

/// @title MandateLib
/// @notice Validation, hashing and lookups over a Mandate held in memory.
library MandateLib {
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Starting value of the Payout Fee (DEC-095): 2%.
    uint16 internal constant DEFAULT_PAYOUT_FEE_BPS = 200;

    /// @notice Starting value of the Standard Payout term (DEC-095): 72 hours.
    uint32 internal constant DEFAULT_STANDARD_PAYOUT_TERM = 72 hours;

    /// @notice Cap on the performance fee. OPEN (LC-57): value proposed by research, not decided (DEC-110 says caps
    ///         are core constants).
    uint16 internal constant MAX_PERFORMANCE_FEE_BPS = 2500;

    /// @notice Cap on the management fee, per year. OPEN (LC-57): value proposed by research, not decided.
    uint16 internal constant MAX_MANAGEMENT_FEE_BPS = 200;

    /// @notice Cap on `maxBridgeFeeBps`: 1% of the amount sent.
    /// @dev Security review S-9 (QA19 leaves the per-fund value OPEN; DEC-110 makes fee caps core constants): with
    ///      `maxBridgeFeeBps` allowed up to 100% a Mandate the factory accepted let one send deliver 1 base unit for
    ///      the whole Free Idle and the relayer keep the rest. The measured Across route fee is about 0.06%
    ///      (docs/DECISIONS.md), so 1% leaves a wide margin. OPEN value (security review parameter, to confirm with the
    ///      founder).
    uint16 internal constant MAX_BRIDGE_FEE_BPS = 100;

    error ZeroManager();
    error ZeroUsdc();
    error ZeroHubChainId();
    error EmptyAdapters();
    error EmptyPools();
    error EmptyUnwindOrder();
    error ZeroAdapter();
    error UnknownChain(uint256 chainId);
    error DuplicateAdapter(uint256 chainId, address adapter);
    error DuplicatePool(uint256 chainId, address adapter, bytes32 poolKey);
    error PoolAdapterNotListed(uint256 chainId, address adapter);
    error UnwindStepNotInPools(uint256 chainId, address adapter, bytes32 poolKey);
    error DuplicateUnwindStep(uint256 chainId, address adapter, bytes32 poolKey);
    error SpokeIsHubChain(uint256 chainId);
    error DuplicateSpoke(uint256 chainId, uint16 wormholeChainId);
    error InvalidSpoke(uint256 chainId);
    error UnknownSpokeChain(uint256 spokeChainId);
    error BridgeAdapterSideInvalid(uint256 spokeChainId, uint256 chainId);
    error MissingBridgeAdapter(uint256 spokeChainId, uint256 chainId);
    error DuplicateOperatingCashChain(uint256 chainId);
    error BpsAboveMax(uint256 bps, uint256 maxBps);
    error ManagementFeeNotSupported(uint16 bps);
    error NoBridgeAdapter(uint256 spokeChainId, uint256 chainId, uint256 rank);

    /// @notice Reverts unless the Mandate is well formed.
    /// @dev Checks, with the decision behind each:
    ///      - manager, USDC and hub chain id set (DEC-002, DEC-011);
    ///      - position adapters, pools and unwind order non-empty, no zero or duplicate adapter, every adapter on the
    ///        hub or a spoke (DEC-053, DEC-058);
    ///      - every pool behind a listed adapter on the same chain, no duplicate pool (DEC-030);
    ///      - every unwind step in the pool list, no duplicate step (DEC-069);
    ///      - spokes on chains other than the hub, unique by EVM and Wormhole chain id, vault, token and report age set
    ///        (DEC-086, DEC-087, DEC-099);
    ///      - every spoke has at least one bridge adapter on the hub side and one on the spoke side (DEC-089: a chain
    ///        is supported only through a live bridge adapter); no address listed twice as an adapter on one chain;
    ///      - Operating Cash entries on known chains, one per chain (DEC-096);
    ///      - fees: Payout Fee at most 100%; bridge fee at most `MAX_BRIDGE_FEE_BPS` (security review S-9);
    ///        performance fee within the OPEN cap; management fee 0 in the MVP (DEC-108, LC-144, LC-57).
    ///      A Mandate without spokes (hub-only fund) is accepted: no decision requires a spoke.
    function validate(Mandate memory m) internal pure {
        if (m.manager == address(0)) revert ZeroManager();
        if (m.usdc == address(0)) revert ZeroUsdc();
        if (m.hubChainId == 0) revert ZeroHubChainId();

        _validateSpokes(m);
        _validateAdapters(m);
        _validatePools(m);
        _validateUnwindOrder(m);
        _validateBridgeAdapters(m);
        _validateOperatingCash(m);

        if (m.payoutFeeBps > BPS) revert BpsAboveMax(m.payoutFeeBps, BPS);
        if (m.maxBridgeFeeBps > MAX_BRIDGE_FEE_BPS) revert BpsAboveMax(m.maxBridgeFeeBps, MAX_BRIDGE_FEE_BPS);
        if (m.performanceFeeBps > MAX_PERFORMANCE_FEE_BPS) {
            revert BpsAboveMax(m.performanceFeeBps, MAX_PERFORMANCE_FEE_BPS);
        }
        // DEC-108, LC-144: recipient and "position close" are OPEN, so the MVP accepts only a zero management fee.
        if (m.managementFeeBps != 0) revert ManagementFeeNotSupported(m.managementFeeBps);
    }

    /// @notice Hash that identifies the Mandate (`mandateHash`, the glossary identifier).
    function hash(Mandate memory m) internal pure returns (bytes32) {
        return keccak256(abi.encode(m));
    }

    /// @notice Whether `chainId` is the hub or one of the spokes.
    function isFundChain(Mandate memory m, uint256 chainId) internal pure returns (bool) {
        if (chainId == m.hubChainId) return true;
        for (uint256 i; i < m.spokes.length; ++i) {
            if (m.spokes[i].chainId == chainId) return true;
        }
        return false;
    }

    /// @notice Whether `adapter` is a Mandate position adapter on `chainId`.
    function isAdapter(Mandate memory m, uint256 chainId, address adapter) internal pure returns (bool) {
        for (uint256 i; i < m.adapters.length; ++i) {
            if (m.adapters[i].chainId == chainId && m.adapters[i].adapter == adapter) return true;
        }
        return false;
    }

    /// @notice Whether `adapter` is a Mandate bridge adapter deployed on `chainId`.
    function isBridgeAdapter(Mandate memory m, uint256 chainId, address adapter) internal pure returns (bool) {
        for (uint256 i; i < m.bridgeAdapters.length; ++i) {
            if (m.bridgeAdapters[i].chainId == chainId && m.bridgeAdapters[i].adapter == adapter) return true;
        }
        return false;
    }

    /// @notice Whether `(chainId, adapter, poolKey)` is in the Mandate pool list (DEC-030).
    function isAllowedPool(Mandate memory m, uint256 chainId, address adapter, bytes32 poolKey)
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < m.pools.length; ++i) {
            PoolConfig memory p = m.pools[i];
            if (p.chainId == chainId && p.adapter == adapter && p.poolKey == poolKey) return true;
        }
        return false;
    }

    /// @notice The spoke on `chainId` and its index. Reverts with `UnknownSpokeChain` if none.
    function spokeByChainId(Mandate memory m, uint256 chainId)
        internal
        pure
        returns (uint256 index, SpokeConfig memory spoke)
    {
        for (uint256 i; i < m.spokes.length; ++i) {
            if (m.spokes[i].chainId == chainId) return (i, m.spokes[i]);
        }
        revert UnknownSpokeChain(chainId);
    }

    /// @notice The bridge adapter of priority `rank` (0 = primary) serving `spokeChainId` and deployed on `chainId`.
    /// @dev DEC-088. Reverts with `NoBridgeAdapter` if there is no adapter at that rank.
    function bridgeAdapterFor(Mandate memory m, uint256 spokeChainId, uint256 chainId, uint256 rank)
        internal
        pure
        returns (address)
    {
        uint256 seen;
        for (uint256 i; i < m.bridgeAdapters.length; ++i) {
            BridgeAdapterConfig memory b = m.bridgeAdapters[i];
            if (b.spokeChainId == spokeChainId && b.chainId == chainId) {
                if (seen == rank) return b.adapter;
                ++seen;
            }
        }
        revert NoBridgeAdapter(spokeChainId, chainId, rank);
    }

    /// @notice Initial Operating Cash floor and top-up of `chainId`; zero when the Mandate has no entry.
    function operatingCashFor(Mandate memory m, uint256 chainId) internal pure returns (uint256 floor, uint256 topUp) {
        for (uint256 i; i < m.operatingCash.length; ++i) {
            if (m.operatingCash[i].chainId == chainId) return (m.operatingCash[i].floor, m.operatingCash[i].topUp);
        }
        return (0, 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Validation helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _validateSpokes(Mandate memory m) private pure {
        for (uint256 i; i < m.spokes.length; ++i) {
            SpokeConfig memory s = m.spokes[i];
            if (s.chainId == 0 || s.wormholeChainId == 0 || s.spokeVault == bytes32(0) || s.spokeToken == address(0)) {
                revert InvalidSpoke(s.chainId);
            }
            // DEC-099: a zero lifetime would reject every report.
            if (s.maxReportAge == 0) revert InvalidSpoke(s.chainId);
            if (s.chainId == m.hubChainId) revert SpokeIsHubChain(s.chainId);
            for (uint256 j; j < i; ++j) {
                if (m.spokes[j].chainId == s.chainId || m.spokes[j].wormholeChainId == s.wormholeChainId) {
                    revert DuplicateSpoke(s.chainId, s.wormholeChainId);
                }
            }
        }
    }

    function _validateAdapters(Mandate memory m) private pure {
        if (m.adapters.length == 0) revert EmptyAdapters();
        for (uint256 i; i < m.adapters.length; ++i) {
            AdapterConfig memory a = m.adapters[i];
            if (a.adapter == address(0)) revert ZeroAdapter();
            if (!isFundChain(m, a.chainId)) revert UnknownChain(a.chainId);
            for (uint256 j; j < i; ++j) {
                if (m.adapters[j].chainId == a.chainId && m.adapters[j].adapter == a.adapter) {
                    revert DuplicateAdapter(a.chainId, a.adapter);
                }
            }
        }
    }

    function _validatePools(Mandate memory m) private pure {
        if (m.pools.length == 0) revert EmptyPools();
        for (uint256 i; i < m.pools.length; ++i) {
            PoolConfig memory p = m.pools[i];
            if (!isAdapter(m, p.chainId, p.adapter)) revert PoolAdapterNotListed(p.chainId, p.adapter);
            for (uint256 j; j < i; ++j) {
                PoolConfig memory q = m.pools[j];
                if (q.chainId == p.chainId && q.adapter == p.adapter && q.poolKey == p.poolKey) {
                    revert DuplicatePool(p.chainId, p.adapter, p.poolKey);
                }
            }
        }
    }

    function _validateUnwindOrder(Mandate memory m) private pure {
        if (m.unwindOrder.length == 0) revert EmptyUnwindOrder();
        for (uint256 i; i < m.unwindOrder.length; ++i) {
            UnwindStep memory u = m.unwindOrder[i];
            if (!isAllowedPool(m, u.chainId, u.adapter, u.poolKey)) {
                revert UnwindStepNotInPools(u.chainId, u.adapter, u.poolKey);
            }
            for (uint256 j; j < i; ++j) {
                UnwindStep memory v = m.unwindOrder[j];
                if (v.chainId == u.chainId && v.adapter == u.adapter && v.poolKey == u.poolKey) {
                    revert DuplicateUnwindStep(u.chainId, u.adapter, u.poolKey);
                }
            }
        }
    }

    function _validateBridgeAdapters(Mandate memory m) private pure {
        for (uint256 i; i < m.bridgeAdapters.length; ++i) {
            BridgeAdapterConfig memory b = m.bridgeAdapters[i];
            if (b.adapter == address(0)) revert ZeroAdapter();
            // Throws UnknownSpokeChain when the route serves no Mandate spoke.
            spokeByChainId(m, b.spokeChainId);
            if (b.chainId != m.hubChainId && b.chainId != b.spokeChainId) {
                revert BridgeAdapterSideInvalid(b.spokeChainId, b.chainId);
            }
            // One address is one adapter on a chain: never both a position adapter and a bridge adapter.
            if (isAdapter(m, b.chainId, b.adapter)) revert DuplicateAdapter(b.chainId, b.adapter);
            for (uint256 j; j < i; ++j) {
                BridgeAdapterConfig memory c = m.bridgeAdapters[j];
                // The same bridge adapter may serve several spokes from the hub, but never twice for one spoke.
                if (c.chainId == b.chainId && c.adapter == b.adapter && c.spokeChainId == b.spokeChainId) {
                    revert DuplicateAdapter(b.chainId, b.adapter);
                }
            }
        }
        // DEC-089: every spoke is reachable in both directions.
        for (uint256 i; i < m.spokes.length; ++i) {
            uint256 spokeChainId = m.spokes[i].chainId;
            if (!_hasBridgeAdapter(m, spokeChainId, m.hubChainId)) {
                revert MissingBridgeAdapter(spokeChainId, m.hubChainId);
            }
            if (!_hasBridgeAdapter(m, spokeChainId, spokeChainId)) {
                revert MissingBridgeAdapter(spokeChainId, spokeChainId);
            }
        }
    }

    function _validateOperatingCash(Mandate memory m) private pure {
        for (uint256 i; i < m.operatingCash.length; ++i) {
            uint256 chainId = m.operatingCash[i].chainId;
            if (!isFundChain(m, chainId)) revert UnknownChain(chainId);
            for (uint256 j; j < i; ++j) {
                if (m.operatingCash[j].chainId == chainId) revert DuplicateOperatingCashChain(chainId);
            }
        }
    }

    function _hasBridgeAdapter(Mandate memory m, uint256 spokeChainId, uint256 chainId) private pure returns (bool) {
        for (uint256 i; i < m.bridgeAdapters.length; ++i) {
            if (m.bridgeAdapters[i].spokeChainId == spokeChainId && m.bridgeAdapters[i].chainId == chainId) {
                return true;
            }
        }
        return false;
    }
}
