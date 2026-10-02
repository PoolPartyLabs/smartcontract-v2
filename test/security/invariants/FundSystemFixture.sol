// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FundSeed} from "../../utils/FundSeed.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {
    Mandate,
    AdapterConfig,
    PoolConfig,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";
import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {MockAcrossSpokePool} from "../../mocks/core/MockAcrossSpokePool.sol";
import {MockBridgeAdapter} from "../../mocks/core/MockBridgeAdapter.sol";
import {MockCoreBridge} from "../../mocks/receiver/MockCoreBridge.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";
import {MockSwapAdapter} from "../../mocks/swap/MockSwapAdapter.sol";

/// @notice Every contract of one fund, as the invariant handlers and the tests address it.
struct FundSystem {
    CoreVault core;
    ShareToken shares;
    SpokeVault hubVault;
    SpokeVault spokeVault;
    ValueReportReceiver receiver;
    CoreMockToken usdc;
    CoreMockToken weth;
    CoreMockToken usdg;
    CoreMockToken spokeWeth;
    MockAcrossSpokePool hubPool;
    MockAcrossSpokePool spokePool;
    MockPositionAdapter hubUni;
    MockPositionAdapter hubAave;
    MockPositionAdapter spokeUni;
    MockSwapAdapter spokeSwap;
    MockWormholeCore wormhole;
    MockPriceSource prices;
    address manager;
    address protocolRecipient;
    address excessRecipient;
}

/// @title One whole fund in one EVM, for the security invariant suites
/// @notice The real Core Vault, the real Spoke Vault in both roles (hub and spoke) and the real ValueReportReceiver,
///         wired to each other the way the FundFactory wires them, with mocks only at the protocol edges: Across
///         (deposits are recorded, the handler plays the relayer and the refund), Wormhole (the spoke's published
///         payload is wrapped into a VAA the mock Core Bridge accepts), the position adapters, the price source and
///         the manager registry. Arbitrum One is the Hub Chain (42161) and Robinhood Chain the one Spoke Chain (4663);
///         `block.chainid` is switched only while each contract is constructed, and both chains share one clock.
/// @dev Principal is only ever held in USDC (hub) and USDG (spoke, priced 1:1), so nothing in the system appreciates:
///      Share Assets move only through deposits, payouts, fees, Operating Cash top-ups and bridge fees. That is what
///      makes "no actor ends with more than they put in" a checkable property. WETH exists only as income.
abstract contract FundSystemFixture is Test, FundSeed {
    using MandateFixture for Mandate;

    uint256 internal constant HUB = 42_161;
    uint256 internal constant SPOKE = 4663;
    uint16 internal constant WH_SPOKE = 72;
    uint32 internal constant MAX_REPORT_AGE = 1587;
    uint256 internal constant SPOKE_CAP = 10_000_000e6;
    uint16 internal constant PERFORMANCE_FEE_BPS = 2000;
    uint16 internal constant FLOW_FEE_BPS = 25;
    bytes32 internal constant FUND_ID = keccak256("pool-party-security-fund");
    bytes32 internal constant HUB_POOL = keccak256("hub WETH/USDC");
    bytes32 internal constant AAVE_USDC = keccak256("aave USDC");
    bytes32 internal constant SPOKE_POOL = keccak256("spoke WETH/USDG");
    /// @dev DEC-127: the manager seeds the Mandate minimum, 100 USDC; after the flow fee it buys 99 whole shares at
    ///      1.00 and leaves 99 USDC in Idle. Hub Operating Cash (floor 1, top-up 3) is live from creation, so the first
    ///      value-moving operation tops it up out of the seed's Idle (DEC-096).
    uint256 internal constant SYSTEM_SEED = 100e6;
    uint256 internal constant SYSTEM_SEED_IDLE = 99e6;

    FundSystem internal sys;
    MockCoreBridge internal coreBridge;
    MockSwapAdapter internal hubSwap;
    MockSwapAdapter internal spokeSwap;
    MockManagerRegistry internal registry;
    MockBridgeAdapter internal hubBridge;
    MockBridgeAdapter internal spokeBridge;
    TransitEscrow internal escrowImplementation;

    address internal manager = makeAddr("manager");
    address internal guardian = makeAddr("guardian");
    address internal protocolRecipient = makeAddr("protocolRecipient");
    address internal excessRecipient = makeAddr("excessRecipient");

    function _deploySystem() internal {
        vm.chainId(HUB);
        vm.warp(1_800_000_000);

        sys.usdc = new CoreMockToken("USD Coin", "USDC", 6);
        sys.weth = new CoreMockToken("Wrapped Ether", "WETH", 18);
        sys.usdg = new CoreMockToken("Global Dollar", "USDG", 6);
        sys.spokeWeth = new CoreMockToken("Robinhood WETH", "WETH", 18);
        sys.prices = new MockPriceSource();
        sys.prices.setPrice(address(sys.weth), 2.5e9);
        sys.prices.setPrice(address(sys.spokeWeth), 2.5e9);
        sys.prices.setPrice(address(sys.usdg), 1e18);
        registry = new MockManagerRegistry();
        coreBridge = new MockCoreBridge();
        sys.wormhole = new MockWormholeCore();
        sys.hubPool = new MockAcrossSpokePool();
        sys.spokePool = new MockAcrossSpokePool();
        hubBridge = new MockBridgeAdapter(address(sys.hubPool));
        spokeBridge = new MockBridgeAdapter(address(sys.spokePool));
        escrowImplementation = new TransitEscrow();

        sys.hubUni = new MockPositionAdapter(guardian, false);
        sys.hubAave = new MockPositionAdapter(guardian, true);
        sys.spokeUni = new MockPositionAdapter(guardian, false);
        sys.hubUni.addPool(HUB_POOL, address(sys.weth), address(sys.usdc));
        sys.hubAave.addPool(AAVE_USDC, address(sys.usdc), address(0));
        sys.spokeUni.addPool(SPOKE_POOL, address(sys.spokeWeth), address(sys.usdg));

        hubSwap = new MockSwapAdapter();
        spokeSwap = new MockSwapAdapter();
        // WETH income is swapped into USDG one base unit for one base unit (DEC-136: through the swap adapter).
        spokeSwap.setPrice(address(sys.spokeWeth), address(sys.usdg), 1, 1);
        sys.spokeSwap = spokeSwap;
        sys.manager = manager;
        sys.protocolRecipient = protocolRecipient;
        sys.excessRecipient = excessRecipient;
        _deployFund();

        sys.hubUni.setVault(address(sys.hubVault));
        sys.hubAave.setVault(address(sys.hubVault));
        sys.spokeUni.setVault(address(sys.spokeVault));
        hubBridge.setVault(address(sys.core));
        spokeBridge.setVault(address(sys.spokeVault));
    }

    /// @dev The fund's four contracts reference each other, so their addresses are predicted from this contract's
    ///      nonce first (the FundFactory does the same with CREATE3).
    function _deployFund() private {
        uint64 nonce = vm.getNonce(address(this));
        address spokeVaultAddress = vm.computeCreateAddress(address(this), nonce);
        address coreAddress = vm.computeCreateAddress(address(this), nonce + 3);
        Mandate memory m = _mandate(spokeVaultAddress);

        vm.chainId(SPOKE);
        sys.spokeVault = new SpokeVault(
            m,
            FUND_ID,
            SPOKE,
            coreAddress,
            address(sys.usdg),
            address(sys.spokePool),
            address(sys.wormhole),
            address(escrowImplementation),
            excessRecipient
        );
        vm.chainId(HUB);
        sys.hubVault = new SpokeVault(
            m,
            FUND_ID,
            HUB,
            coreAddress,
            address(sys.usdc),
            address(sys.hubPool),
            address(0),
            address(escrowImplementation),
            excessRecipient
        );
        sys.receiver = new ValueReportReceiver(address(coreBridge), coreAddress, FUND_ID, m.spokes, 0);
        sys.core = new CoreVault(m, _config());
        // DEC-127: this contract plays the factory and seeds the fund (FundSeed) with the Mandate minimum.
        _seedFundWith(address(sys.core), sys.core.usdc(), SYSTEM_SEED);
        assertEq(sys.core.idle(), SYSTEM_SEED_IDLE, "the seed's Idle");
        sys.shares = ShareToken(sys.core.shareToken());
        assertEq(address(sys.spokeVault), spokeVaultAddress, "spoke vault address prediction");
        assertEq(address(sys.core), coreAddress, "core vault address prediction");
    }

    function _mandate(address spokeVaultAddress) internal view returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = HUB;
        m.usdc = address(sys.usdc);
        m.hubWormholeChainId = MandateFixture.ARBITRUM_WORMHOLE_CHAIN_ID;
        m.addToken(HUB, address(sys.usdc));
        m.addToken(HUB, address(sys.weth));
        m.addToken(SPOKE, address(sys.usdg));
        m.addToken(SPOKE, address(sys.spokeWeth));
        m.addSwapAdapter(HUB, address(hubSwap));
        m.addSwapAdapter(SPOKE, address(spokeSwap));
        m.adapters = new AdapterConfig[](3);
        m.adapters[0] = AdapterConfig(HUB, address(sys.hubUni));
        m.adapters[1] = AdapterConfig(HUB, address(sys.hubAave));
        m.adapters[2] = AdapterConfig(SPOKE, address(sys.spokeUni));
        m.pools = new PoolConfig[](3);
        m.pools[0] = PoolConfig(HUB, address(sys.hubUni), HUB_POOL);
        m.pools[1] = PoolConfig(HUB, address(sys.hubAave), AAVE_USDC);
        m.pools[2] = PoolConfig(SPOKE, address(sys.spokeUni), SPOKE_POOL);
        m.spokes = new SpokeConfig[](1);
        m.spokes[0] = SpokeConfig(
            SPOKE, WH_SPOKE, bytes32(uint256(uint160(spokeVaultAddress))), address(sys.usdg), SPOKE_CAP, MAX_REPORT_AGE
        );
        m.bridgeAdapters = new BridgeAdapterConfig[](2);
        m.bridgeAdapters[0] = BridgeAdapterConfig(SPOKE, HUB, address(hubBridge));
        m.bridgeAdapters[1] = BridgeAdapterConfig(SPOKE, SPOKE, address(spokeBridge));
        m.operatingCash = new OperatingCashConfig[](2);
        m.operatingCash[0] = OperatingCashConfig(HUB, 1e6, 3e6);
        m.operatingCash[1] = OperatingCashConfig(SPOKE, 5e6, 10e6);
        m.payoutFeeBps = 200;
        m.minFirstDeposit = SYSTEM_SEED;
        m.performanceFeeBps = PERFORMANCE_FEE_BPS;
        m.managementFeeBps = 0;
    }

    function _config() internal view returns (CoreVaultConfig memory c) {
        c.fundId = FUND_ID;
        c.usdc = address(sys.usdc);
        c.hubSpokeVault = address(sys.hubVault);
        c.reportReceiver = address(sys.receiver);
        c.managerRegistry = address(registry);
        c.priceSource = address(sys.prices);
        c.acrossSpokePool = address(sys.hubPool);
        c.wormholeCore = address(coreBridge);
        c.protocolRecipient = protocolRecipient;
        c.excessRecipient = excessRecipient;
        c.escrowImplementation = address(escrowImplementation);
        c.flowFeeBps = FLOW_FEE_BPS;
        c.factory = address(this);
        c.shareName = "Pool Party Fund 1";
        c.shareSymbol = "PP-1";
    }
}
