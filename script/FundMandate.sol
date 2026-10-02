// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IFundFactory} from "../src/interfaces/IFundFactory.sol";
import {
    Mandate,
    MandateLib,
    AdapterConfig,
    PoolConfig,
    UnwindStep,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../src/mandate/Mandate.sol";

/// @title FundMandate
/// @notice Builds a fund's Mandate from the factory's predicted addresses: one hub Uniswap V4 pool, optionally Aave V3
///         supply of one hub asset, and optionally one Spoke Chain with one Uniswap V4 pool, reached through Across in
///         both directions. Shared by `script/CreateFund.s.sol` and the tests, so a Mandate built on the hub and
///         rebuilt on the spoke is byte-identical (same `mandateHash`).
/// @dev The builder only fills in addresses; every rule value is the manager's choice in `FundPlan` (DEC-053).
abstract contract FundMandate {
    /// @notice The manager's choices for a fund.
    /// @param manager The Manager (DEC-001, DEC-002).
    /// @param hubChainId Hub Chain (DEC-011).
    /// @param usdc Hub USDC (DEC-011).
    /// @param hubPool The hub Uniswap V4 pool (DEC-030, hookless in the MVP, OQ-12).
    /// @param hubAaveAsset Aave V3 reserve asset on the hub; address(0) for no Aave adapter (DEC-018, DEC-028).
    /// @param spokeChainId Spoke Chain; 0 for a hub-only fund (OQ-08).
    /// @param spokeWormholeChainId Wormhole chain id of the spoke (DEC-086).
    /// @param spokeToken Token the Transport Route delivers on the spoke (DEC-031, DEC-055).
    /// @param spokePool The spoke Uniswap V4 pool.
    /// @param spokeCap Spoke Cap in hub USDC base units (DEC-037, DEC-095).
    /// @param maxReportAge Report lifetime (ruling 2026-09-29: Robinhood 1,587 s plus one block).
    /// @param spokeOperatingCashFloor Spoke Operating Cash floor (DEC-096).
    /// @param spokeOperatingCashTopUp Spoke Operating Cash top-up (DEC-096).
    /// @param minFirstDeposit Minimum first deposit, which the seed must reach (DEC-061, DEC-095, DEC-127).
    /// @param performanceFeeBps Performance fee (DEC-107, DEC-110).
    /// @param maxBridgeFeeBps Maximum bridge fee per send (QA19 OPEN).
    /// @param seedAmount The manager's seed at creation, in hub USDC base units (DEC-127); 0 seeds `minFirstDeposit`.
    struct FundPlan {
        address manager;
        uint256 hubChainId;
        address usdc;
        PoolKey hubPool;
        address hubAaveAsset;
        uint256 spokeChainId;
        uint16 spokeWormholeChainId;
        address spokeToken;
        PoolKey spokePool;
        uint256 spokeCap;
        uint32 maxReportAge;
        uint256 spokeOperatingCashFloor;
        uint256 spokeOperatingCashTopUp;
        uint256 minFirstDeposit;
        uint16 performanceFeeBps;
        uint16 maxBridgeFeeBps;
        uint256 seedAmount;
    }

    /// @notice The Mandate of fund `fundId` for `plan`, with every address predicted by `factory`.
    function _buildMandate(IFundFactory factory, bytes32 fundId, FundPlan memory plan)
        internal
        view
        returns (Mandate memory m)
    {
        bool aave = plan.hubAaveAsset != address(0);
        bool spoke = plan.spokeChainId != 0;
        address hubUniswap = factory.addressOf(fundId, "UniswapV4Adapter", plan.hubChainId);
        address hubAave = factory.addressOf(fundId, "AaveV3Adapter", plan.hubChainId);
        bytes32 hubPoolId = PoolId.unwrap(plan.hubPool.toId());
        bytes32 aaveKey = bytes32(uint256(uint160(plan.hubAaveAsset)));

        m.manager = plan.manager;
        m.hubChainId = plan.hubChainId;
        m.usdc = plan.usdc;
        uint256 adapterCount = 1 + (aave ? 1 : 0) + (spoke ? 1 : 0);
        m.adapters = new AdapterConfig[](adapterCount);
        m.pools = new PoolConfig[](adapterCount);
        m.adapters[0] = AdapterConfig(plan.hubChainId, hubUniswap);
        m.pools[0] = PoolConfig(plan.hubChainId, hubUniswap, hubPoolId);
        // Automatic unwind reaches hub positions only in the MVP (feedback question 2, DEC-069).
        m.unwindOrder = new UnwindStep[](aave ? 2 : 1);
        m.unwindOrder[0] = UnwindStep(plan.hubChainId, hubUniswap, hubPoolId);
        if (aave) {
            m.adapters[1] = AdapterConfig(plan.hubChainId, hubAave);
            m.pools[1] = PoolConfig(plan.hubChainId, hubAave, aaveKey);
            m.unwindOrder[1] = UnwindStep(plan.hubChainId, hubAave, aaveKey);
        }
        if (spoke) _addSpoke(factory, fundId, plan, m, adapterCount - 1);

        m.payoutFeeBps = MandateLib.DEFAULT_PAYOUT_FEE_BPS;
        m.standardPayoutTerm = MandateLib.DEFAULT_STANDARD_PAYOUT_TERM;
        m.minFirstDeposit = plan.minFirstDeposit;
        m.performanceFeeBps = plan.performanceFeeBps;
        m.maxBridgeFeeBps = plan.maxBridgeFeeBps;
    }

    function _addSpoke(IFundFactory factory, bytes32 fundId, FundPlan memory plan, Mandate memory m, uint256 index)
        private
        view
    {
        address spokeUniswap = factory.addressOf(fundId, "UniswapV4Adapter", plan.spokeChainId);
        address spokeVault = factory.addressOf(fundId, "SpokeVault", plan.spokeChainId);
        m.adapters[index] = AdapterConfig(plan.spokeChainId, spokeUniswap);
        m.pools[index] = PoolConfig(plan.spokeChainId, spokeUniswap, PoolId.unwrap(plan.spokePool.toId()));
        m.spokes = new SpokeConfig[](1);
        m.spokes[0] = SpokeConfig(
            plan.spokeChainId,
            plan.spokeWormholeChainId,
            bytes32(uint256(uint160(spokeVault))),
            plan.spokeToken,
            plan.spokeCap,
            plan.maxReportAge
        );
        // DEC-088, DEC-089: one Across adapter per side, the spoke reachable in both directions.
        m.bridgeAdapters = new BridgeAdapterConfig[](2);
        m.bridgeAdapters[0] = BridgeAdapterConfig(
            plan.spokeChainId, plan.hubChainId, factory.addressOf(fundId, "AcrossBridgeAdapter", plan.hubChainId)
        );
        m.bridgeAdapters[1] = BridgeAdapterConfig(
            plan.spokeChainId, plan.spokeChainId, factory.addressOf(fundId, "AcrossBridgeAdapter", plan.spokeChainId)
        );
        m.operatingCash = new OperatingCashConfig[](1);
        m.operatingCash[0] =
            OperatingCashConfig(plan.spokeChainId, plan.spokeOperatingCashFloor, plan.spokeOperatingCashTopUp);
    }

    /// @notice `createFund` inputs for `plan`.
    function _hubParams(uint256 creationNumber, FundPlan memory plan, bytes memory coreVaultCreationCode)
        internal
        pure
        returns (IFundFactory.HubParams memory p)
    {
        p.creationNumber = creationNumber;
        p.uniswapV4Pools = new PoolKey[](1);
        p.uniswapV4Pools[0] = plan.hubPool;
        p.coreVaultCreationCode = coreVaultCreationCode;
        p.seedAmount = plan.seedAmount != 0 ? plan.seedAmount : plan.minFirstDeposit;
    }

    /// @notice `createSpoke` inputs for `plan` and the `mandateHash` the hub emitted.
    function _spokeParams(bytes32 mandateHash, FundPlan memory plan)
        internal
        pure
        returns (IFundFactory.SpokeParams memory p)
    {
        p.mandateHash = mandateHash;
        p.uniswapV4Pools = new PoolKey[](1);
        p.uniswapV4Pools[0] = plan.spokePool;
    }
}
