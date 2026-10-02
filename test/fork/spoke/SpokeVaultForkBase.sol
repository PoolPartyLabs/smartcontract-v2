// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    Mandate,
    AdapterConfig,
    PoolConfig,
    UnwindStep,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";

/// @notice Verified mainnet addresses (docs/INTEGRATIONS.md) and a Mandate builder for the Spoke Vault fork suites.
abstract contract SpokeVaultForkBase is Test {
    uint256 internal constant ARBITRUM = 42_161;
    uint256 internal constant ROBINHOOD = 4663;
    uint16 internal constant WH_ROBINHOOD = 72;
    uint32 internal constant MAX_REPORT_AGE = 1587;
    bytes32 internal constant FUND_ID = keccak256("fork fund");
    bytes32 internal constant HUB_POOL = keccak256("hub WETH/USDC");
    bytes32 internal constant AAVE_USDC = keccak256("aave USDC");
    bytes32 internal constant SPOKE_POOL = keccak256("spoke WETH/USDG");

    // Arbitrum One (Hub Chain)
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant ARB_SPOKE_POOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;

    // Robinhood Chain (Spoke Chain)
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant RH_WORMHOLE_CORE = 0x141fBa8AD5D61bdaB45A047cF60b5Ad9784987FB;
    address internal constant RH_SPOKE_POOL = 0xD29C85F15DF544bA632C9E25829fd29d767d7978;

    address internal manager = makeAddr("manager");
    address internal guardian = makeAddr("guardian");
    address internal excessRecipient = makeAddr("excessRecipient");

    struct ForkAdapters {
        address hubUni;
        address hubAave;
        address spokeUni;
        address hubBridge;
        address spokeBridge;
        address spokeVault;
    }

    function _mandate(ForkAdapters memory a) internal view returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = ARBITRUM;
        m.usdc = ARB_USDC;

        m.adapters = new AdapterConfig[](3);
        m.adapters[0] = AdapterConfig(ARBITRUM, a.hubUni);
        m.adapters[1] = AdapterConfig(ARBITRUM, a.hubAave);
        m.adapters[2] = AdapterConfig(ROBINHOOD, a.spokeUni);

        m.pools = new PoolConfig[](3);
        m.pools[0] = PoolConfig(ARBITRUM, a.hubUni, HUB_POOL);
        m.pools[1] = PoolConfig(ARBITRUM, a.hubAave, AAVE_USDC);
        m.pools[2] = PoolConfig(ROBINHOOD, a.spokeUni, SPOKE_POOL);

        m.unwindOrder = new UnwindStep[](3);
        m.unwindOrder[0] = UnwindStep(ARBITRUM, a.hubUni, HUB_POOL);
        m.unwindOrder[1] = UnwindStep(ARBITRUM, a.hubAave, AAVE_USDC);
        m.unwindOrder[2] = UnwindStep(ROBINHOOD, a.spokeUni, SPOKE_POOL);

        m.spokes = new SpokeConfig[](1);
        m.spokes[0] = SpokeConfig(
            ROBINHOOD, WH_ROBINHOOD, bytes32(uint256(uint160(a.spokeVault))), RH_USDG, 1_000_000e6, MAX_REPORT_AGE
        );

        m.bridgeAdapters = new BridgeAdapterConfig[](2);
        m.bridgeAdapters[0] = BridgeAdapterConfig(ROBINHOOD, ARBITRUM, a.hubBridge);
        m.bridgeAdapters[1] = BridgeAdapterConfig(ROBINHOOD, ROBINHOOD, a.spokeBridge);

        m.operatingCash = new OperatingCashConfig[](1);
        m.operatingCash[0] = OperatingCashConfig(ROBINHOOD, 5e6, 10e6);

        m.payoutFeeBps = 200;
        m.minFirstDeposit = 100e6;
        m.performanceFeeBps = 1000;
    }
}
