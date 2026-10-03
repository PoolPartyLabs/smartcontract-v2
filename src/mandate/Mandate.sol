// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A position adapter or a swap adapter deployed on one chain of the fund.
/// @dev DEC-053, DEC-058: closed list, fixed at creation; no adapter may be added to a live fund. DEC-136: swap
///      adapters are listed the same way, in their own list.
struct AdapterConfig {
    uint256 chainId;
    address adapter;
}

/// @notice A token the fund may hold on one chain.
/// @dev DEC-136 closing note item 2 (a swap adapter swaps only tokens the Mandate has), DEC-123 level 1 (every token is
///      priced on the hub at creation), DEC-173 (an API route's first and last tokens; its intermediate hops may be
///      any token).
struct TokenConfig {
    uint256 chainId;
    address token;
}

/// @notice A pool the manager may open positions in, through a given adapter on a given chain.
/// @dev DEC-030: every pool the manager may operate is listed in the Mandate. `poolKey` is adapter-specific.
struct PoolConfig {
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
/// @dev Ruling 2026-10-02, DEC-187: both values must be zero in the MVP; native Operating Cash is post-buildathon.
struct OperatingCashConfig {
    uint256 chainId;
    uint256 floor;
    uint256 topUp;
}

/// @notice The rules of a fund, written once at creation (DEC-053).
/// @dev Every array holds value-only structs so a vault can copy the Mandate into storage element by element.
/// @param manager Fund manager (DEC-002; manager transfer OPEN, immutable in the MVP).
/// @param hubChainId EVM chain id of the Hub Chain (DEC-011).
/// @param hubWormholeChainId Wormhole chain id of the Hub Chain (Arbitrum One: 23), the emitter chain of the Hub's
///        orders to the spokes (DEC-120, DEC-139; reading D-15); the Core Vault checks it against its Wormhole Core.
/// @param usdc USDC on the Hub Chain, the only deposit and payout asset (DEC-011).
/// @param tokens Closed list of the tokens the fund may hold, per chain, every chain's base token included (USDC on the
///        hub, the spoke token on each spoke); unique per chain, at most `MAX_TOKENS` in total (DEC-123, DEC-136).
/// @param adapters Closed list of position adapters per chain, hub included (DEC-053, DEC-054, DEC-058).
/// @param swapAdapters Closed list of swap adapters per chain, at least one on every fund chain; the alpha lists one
///        `UniswapV3SwapAdapter` per chain (DEC-136 and its closing note).
/// @param pools Closed list of pools per adapter (DEC-030); every pool token is a Mandate token of its chain (checked
///        by the Spoke Vault, which reads the pool tokens from the adapter).
/// @param spokes Spoke Chains (DEC-031, DEC-037, DEC-095).
/// @param bridgeAdapters Bridge adapters per spoke, in priority order (DEC-087, DEC-088).
/// @param operatingCash Initial Operating Cash floor and top-up per chain (DEC-096).
/// @param payoutFeeBps Payout Fee on Instant Payouts, in bps; immutable (DEC-006, DEC-075, DEC-095, DEC-102, DEC-110).
/// @param minFirstDeposit Minimum first deposit, in USDC base units; no protocol floor (DEC-061, DEC-095, erratum 22).
/// @param performanceFeeBps Manager performance fee on collected income, in bps, chosen by the manager at creation
///        within [`MIN_PERFORMANCE_FEE_BPS`, `MAX_PERFORMANCE_FEE_BPS`] = [1,000, 9,000]; may only decrease, never
///        below the minimum (DEC-107, DEC-110, DEC-182, DEC-184).
/// @param managementFeeBps Manager management fee, in bps per year on Share Assets, chosen by the manager at creation
///        within [0, `MAX_MANAGEMENT_FEE_BPS`] = [0, 500]; accrued as a liability outside Share Assets at every
///        valuation and paid at fund closure (DEC-108, DEC-114, DEC-182, DEC-184, DEC-186); may only decrease, down
///        to 0 (DEC-110).
/// @dev Mandate v2 (WP-07 B). No unwind order: the automatic unwind is proportional (DEC-137, DEC-139; corrects
///      DEC-069 item 1). No Standard Payout term: 72 hours for every fund (DEC-154). No bridge fee bound: DEC-156 (no
///      protocol cap on the bridge fee) and DEC-162 (the bridge adapter fixes the send terms and holds the fee rule).
struct Mandate {
    address manager;
    uint256 hubChainId;
    uint16 hubWormholeChainId;
    address usdc;
    TokenConfig[] tokens;
    AdapterConfig[] adapters;
    AdapterConfig[] swapAdapters;
    PoolConfig[] pools;
    SpokeConfig[] spokes;
    BridgeAdapterConfig[] bridgeAdapters;
    OperatingCashConfig[] operatingCash;
    uint16 payoutFeeBps;
    uint256 minFirstDeposit;
    uint16 performanceFeeBps;
    uint16 managementFeeBps;
}

/// @title MandateLib
/// @notice Validation, hashing and lookups over a Mandate held in memory.
library MandateLib {
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Starting value of the Payout Fee (DEC-095): 2%.
    uint16 internal constant DEFAULT_PAYOUT_FEE_BPS = 200;

    /// @notice Cap on the performance fee: 90% of income, a core constant (DEC-110, DEC-115, DEC-184). At the cap,
    ///         72,000 of an income of 80,000 is fee.
    uint16 internal constant MAX_PERFORMANCE_FEE_BPS = 9000;

    /// @notice Floor on the performance fee: 10% of income, the V1 minimum, a core constant (DEC-182, DEC-184). It
    ///         binds at creation and every `decreaseManagerFee`; it replaces the ManagerRegistry's adjustable minimum
    ///         (corrects DEC-115 and DEC-125 item 3, reading D-36), so the protocol slice (DEC-112) is at least 0.5% of
    ///         collected income.
    uint16 internal constant MIN_PERFORMANCE_FEE_BPS = 1000;

    /// @notice Cap on the management fee: 5% a year, a core constant (DEC-110, DEC-115). DEC-186 (Slack only so far)
    ///         keeps 5% and corrects the 10% that DEC-182 and DEC-184 state; the floor is 0 (DEC-184).
    uint16 internal constant MAX_MANAGEMENT_FEE_BPS = 500;

    /// @notice Cap on the Payout Fee: 10%, a core constant (DEC-155; refines DEC-075, DEC-095, DEC-110).
    /// @dev Security review S-17 still holds with room to spare: an Instant Payout pays `usdcGross - payoutFee -
    ///      flowFee`, and 10% plus the 1% flow fee cap (`ShareMath.MAX_FLOW_FEE_BPS`) never underflows.
    uint16 internal constant MAX_PAYOUT_FEE_BPS = 1000;

    /// @notice Most tokens a Mandate lists, every chain together (WP-07 B1): the bound of the hub's income token list
    ///         (`IncomeAccumulator.MAX_TOKENS`, `DollarIncomeIndex.MAX_TOKENS`) and of every ledger walk.
    uint256 internal constant MAX_TOKENS = 16;

    /// @notice Cap on a spoke's report lifetime (`maxReportAge`): one day.
    /// @dev Independent review M-04 (security review S-25): DEC-094 and DEC-099 make the lifetime a property of the
    ///      spoke chain, which the factory does not hold yet (DEC-089 registry OPEN), and the Mandate took any non-zero
    ///      value: at `type(uint32).max` mints would price on reports 136 years old and an unlisted arrival could only
    ///      be recovered after a report built that long after it (S-4). The research value for Robinhood is 1,587 s
    ///      (ruling 2026-09-29); one day leaves a wide margin. The lower bound (the chain's finality) needs the
    ///      per-chain registry. OPEN value.
    uint32 internal constant MAX_REPORT_AGE = 1 days;

    error ZeroManager();
    error ZeroUsdc();
    error ZeroHubChainId();
    error ZeroHubWormholeChainId();
    error ZeroToken();
    error DuplicateToken(uint256 chainId, address token);
    error TooManyTokens(uint256 count, uint256 maxTokens);
    error MissingBaseToken(uint256 chainId, address token);
    error MissingSwapAdapter(uint256 chainId);
    error EmptyAdapters();
    error EmptyPools();
    error ZeroAdapter();
    error UnknownChain(uint256 chainId);
    error DuplicateAdapter(uint256 chainId, address adapter);
    error DuplicatePool(uint256 chainId, address adapter, bytes32 poolKey);
    error PoolAdapterNotListed(uint256 chainId, address adapter);
    error SpokeIsHubChain(uint256 chainId);
    error DuplicateSpoke(uint256 chainId, uint16 wormholeChainId);
    error InvalidSpoke(uint256 chainId);
    error UnknownSpokeChain(uint256 spokeChainId);
    error BridgeAdapterSideInvalid(uint256 spokeChainId, uint256 chainId);
    error MissingBridgeAdapter(uint256 spokeChainId, uint256 chainId);
    error DuplicateOperatingCashChain(uint256 chainId);
    error OperatingCashNotSupported();
    error BpsAboveMax(uint256 bps, uint256 maxBps);
    error BpsBelowMin(uint256 bps, uint256 minBps);
    error NoBridgeAdapter(uint256 spokeChainId, uint256 chainId, uint256 rank);

    /// @notice Reverts unless the Mandate is well formed.
    /// @dev Checks, with the decision behind each:
    ///      - manager, USDC, hub chain id and hub Wormhole chain id set (DEC-002, DEC-011, DEC-120 reading D-15);
    ///      - tokens: none zero, each on the hub or a spoke, unique per chain, at most `MAX_TOKENS` in total, every
    ///        chain's base token listed (DEC-123, DEC-136);
    ///      - position adapters and pools non-empty, no zero or duplicate adapter, every adapter on the hub or a spoke
    ///        (DEC-053, DEC-058);
    ///      - swap adapters: none zero, each on the hub or a spoke, never also a position or bridge adapter of that
    ///        chain, at least one on every fund chain (DEC-136);
    ///      - every pool behind a listed adapter on the same chain, no duplicate pool (DEC-030);
    ///      - spokes on chains other than the hub (by EVM and Wormhole chain id), unique by both, vault, token and report
    ///        age set,
    ///        the report age at most `MAX_REPORT_AGE` (DEC-086, DEC-087, DEC-099; independent review M-04);
    ///      - every spoke has at least one bridge adapter on the hub side and one on the spoke side (DEC-089: a chain
    ///        is supported only through a live bridge adapter); no address listed twice as an adapter on one chain;
    ///      - Operating Cash entries on known chains, one per chain (DEC-096);
    ///      - fees: Payout Fee at most `MAX_PAYOUT_FEE_BPS` (DEC-155); performance fee within
    ///        [`MIN_PERFORMANCE_FEE_BPS`, `MAX_PERFORMANCE_FEE_BPS`] (DEC-115, DEC-182, DEC-184); management fee at
    ///        most `MAX_MANAGEMENT_FEE_BPS` (DEC-114, DEC-184, DEC-186).
    ///      A Mandate without spokes (hub-only fund) is accepted: no decision requires a spoke.
    function validate(Mandate memory m) internal pure {
        if (m.manager == address(0)) revert ZeroManager();
        if (m.usdc == address(0)) revert ZeroUsdc();
        if (m.hubChainId == 0) revert ZeroHubChainId();
        if (m.hubWormholeChainId == 0) revert ZeroHubWormholeChainId();

        _validateSpokes(m);
        _validateTokens(m);
        _validateAdapters(m);
        _validatePools(m);
        _validateBridgeAdapters(m);
        _validateSwapAdapters(m);
        _validateOperatingCash(m);

        if (m.payoutFeeBps > MAX_PAYOUT_FEE_BPS) revert BpsAboveMax(m.payoutFeeBps, MAX_PAYOUT_FEE_BPS);
        if (m.performanceFeeBps > MAX_PERFORMANCE_FEE_BPS) {
            revert BpsAboveMax(m.performanceFeeBps, MAX_PERFORMANCE_FEE_BPS);
        }
        if (m.performanceFeeBps < MIN_PERFORMANCE_FEE_BPS) {
            revert BpsBelowMin(m.performanceFeeBps, MIN_PERFORMANCE_FEE_BPS);
        }
        if (m.managementFeeBps > MAX_MANAGEMENT_FEE_BPS) {
            revert BpsAboveMax(m.managementFeeBps, MAX_MANAGEMENT_FEE_BPS);
        }
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

    /// @notice Whether `adapter` is a Mandate swap adapter on `chainId` (DEC-136).
    function isSwapAdapter(Mandate memory m, uint256 chainId, address adapter) internal pure returns (bool) {
        for (uint256 i; i < m.swapAdapters.length; ++i) {
            if (m.swapAdapters[i].chainId == chainId && m.swapAdapters[i].adapter == adapter) return true;
        }
        return false;
    }

    /// @notice Whether `token` is a Mandate token of `chainId` (DEC-136).
    function isToken(Mandate memory m, uint256 chainId, address token) internal pure returns (bool) {
        for (uint256 i; i < m.tokens.length; ++i) {
            if (m.tokens[i].chainId == chainId && m.tokens[i].token == token) return true;
        }
        return false;
    }

    /// @notice The Mandate tokens of `chainId`, in Mandate order.
    function tokensOf(Mandate memory m, uint256 chainId) internal pure returns (address[] memory tokens) {
        tokens = new address[](m.tokens.length);
        uint256 count;
        for (uint256 i; i < m.tokens.length; ++i) {
            if (m.tokens[i].chainId == chainId) tokens[count++] = m.tokens[i].token;
        }
        assembly ("memory-safe") {
            mstore(tokens, count)
        }
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
            // DEC-099: a zero lifetime would reject every report; above MAX_REPORT_AGE stale reports would price
            // mints (independent review M-04).
            if (s.maxReportAge == 0 || s.maxReportAge > MAX_REPORT_AGE) revert InvalidSpoke(s.chainId);
            if (s.chainId == m.hubChainId || s.wormholeChainId == m.hubWormholeChainId) {
                revert SpokeIsHubChain(s.chainId);
            }
            for (uint256 j; j < i; ++j) {
                if (m.spokes[j].chainId == s.chainId || m.spokes[j].wormholeChainId == s.wormholeChainId) {
                    revert DuplicateSpoke(s.chainId, s.wormholeChainId);
                }
            }
        }
    }

    function _validateTokens(Mandate memory m) private pure {
        if (m.tokens.length > MAX_TOKENS) revert TooManyTokens(m.tokens.length, MAX_TOKENS);
        for (uint256 i; i < m.tokens.length; ++i) {
            TokenConfig memory t = m.tokens[i];
            if (t.token == address(0)) revert ZeroToken();
            if (!isFundChain(m, t.chainId)) revert UnknownChain(t.chainId);
            for (uint256 j; j < i; ++j) {
                if (m.tokens[j].chainId == t.chainId && m.tokens[j].token == t.token) {
                    revert DuplicateToken(t.chainId, t.token);
                }
            }
        }
        // Every chain's base token: USDC on the hub (DEC-011), the Transport Route's token on each spoke (DEC-031).
        if (!isToken(m, m.hubChainId, m.usdc)) revert MissingBaseToken(m.hubChainId, m.usdc);
        for (uint256 i; i < m.spokes.length; ++i) {
            SpokeConfig memory s = m.spokes[i];
            if (!isToken(m, s.chainId, s.spokeToken)) revert MissingBaseToken(s.chainId, s.spokeToken);
        }
    }

    /// @dev DEC-136: a third adapter type; one address is one adapter on a chain, so a swap adapter is never also a
    ///      position or bridge adapter there. Every fund chain needs one: every sale (manager, income, unwind) runs
    ///      through a swap adapter.
    function _validateSwapAdapters(Mandate memory m) private pure {
        for (uint256 i; i < m.swapAdapters.length; ++i) {
            AdapterConfig memory a = m.swapAdapters[i];
            if (a.adapter == address(0)) revert ZeroAdapter();
            if (!isFundChain(m, a.chainId)) revert UnknownChain(a.chainId);
            if (isAdapter(m, a.chainId, a.adapter) || isBridgeAdapter(m, a.chainId, a.adapter)) {
                revert DuplicateAdapter(a.chainId, a.adapter);
            }
            for (uint256 j; j < i; ++j) {
                if (m.swapAdapters[j].chainId == a.chainId && m.swapAdapters[j].adapter == a.adapter) {
                    revert DuplicateAdapter(a.chainId, a.adapter);
                }
            }
        }
        if (!_hasSwapAdapter(m, m.hubChainId)) revert MissingSwapAdapter(m.hubChainId);
        for (uint256 i; i < m.spokes.length; ++i) {
            if (!_hasSwapAdapter(m, m.spokes[i].chainId)) revert MissingSwapAdapter(m.spokes[i].chainId);
        }
    }

    function _hasSwapAdapter(Mandate memory m, uint256 chainId) private pure returns (bool) {
        for (uint256 i; i < m.swapAdapters.length; ++i) {
            if (m.swapAdapters[i].chainId == chainId) return true;
        }
        return false;
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
            if (m.operatingCash[i].floor != 0 || m.operatingCash[i].topUp != 0) revert OperatingCashNotSupported();
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
