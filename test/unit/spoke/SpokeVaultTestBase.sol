// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    Mandate,
    AdapterConfig,
    PoolConfig,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {MockSpokeToken} from "../../mocks/spoke/MockSpokeToken.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockBridgeAdapter} from "../../mocks/spoke/MockBridgeAdapter.sol";
import {MockBridgeNextArrive} from "../../mocks/across/MockBridgeNextArrive.sol";
import {MockAcrossSpokePool} from "../../mocks/spoke/MockAcrossSpokePool.sol";
import {MockCoreVault} from "../../mocks/spoke/MockCoreVault.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {MockSwapAdapter} from "../../mocks/swap/MockSwapAdapter.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";

/// @notice Shared fixture: one Mandate with a Hub Chain (42161) and one Spoke Chain (4663), mock adapters on both,
///         mock Across, Wormhole and Core Vault. `_deploySpoke` / `_deployHub` switch `block.chainid` and deploy.
abstract contract SpokeVaultTestBase is Test {
    using MandateFixture for Mandate;

    uint256 internal constant HUB = 42_161;
    uint256 internal constant SPOKE = 4663;
    uint16 internal constant WH_SPOKE = 72;
    uint32 internal constant MAX_REPORT_AGE = 1587;
    uint256 internal constant SPOKE_FLOOR = 5e6;
    uint256 internal constant SPOKE_TOP_UP = 10e6;
    bytes32 internal constant FUND_ID = keccak256("fund-1");
    bytes32 internal constant HUB_POOL = keccak256("hub WETH/USDC");
    bytes32 internal constant AAVE_USDC = keccak256("aave USDC");
    bytes32 internal constant SPOKE_POOL = keccak256("spoke WETH/USDG");

    address internal manager = makeAddr("manager");
    address internal guardian = makeAddr("guardian");
    address internal excessRecipient = makeAddr("excessRecipient");
    address internal hubBridge = makeAddr("hubAcrossAdapter");
    address internal spokeVaultInMandate = makeAddr("spokeVaultInMandate");
    address internal stranger = makeAddr("stranger");

    MockSpokeToken internal usdc;
    MockSpokeToken internal usdg;
    MockSpokeToken internal weth;
    MockPositionAdapter internal hubUni;
    MockPositionAdapter internal hubAave;
    MockPositionAdapter internal spokeUni;
    MockSwapAdapter internal hubSwap;
    MockSwapAdapter internal spokeSwap;
    MockAcrossSpokePool internal spokePool;
    MockBridgeAdapter internal spokeBridge;
    MockBridgeAdapter internal spokeBridgeFallback;
    MockWormholeCore internal wormhole;
    MockCoreVault internal core;
    TransitEscrow internal escrowImplementation;

    SpokeVault internal vault;

    function _setUpMocks() internal {
        usdc = new MockSpokeToken("USD Coin", "USDC", 6);
        usdg = new MockSpokeToken("Global Dollar", "USDG", 6);
        weth = new MockSpokeToken("Wrapped Ether", "WETH", 18);
        hubUni = new MockPositionAdapter(guardian, false);
        hubAave = new MockPositionAdapter(guardian, true);
        spokeUni = new MockPositionAdapter(guardian, false);
        hubUni.addPool(HUB_POOL, address(weth), address(usdc));
        hubAave.addPool(AAVE_USDC, address(usdc), address(0));
        spokeUni.addPool(SPOKE_POOL, address(weth), address(usdg));
        // DEC-136: every swap runs through a Mandate swap adapter; the stand-ins swap at 2,000 USDC (USDG) per WETH.
        hubSwap = new MockSwapAdapter();
        spokeSwap = new MockSwapAdapter();
        hubSwap.setPrice(address(weth), address(usdc), 2000e6, 1e18);
        spokeSwap.setPrice(address(weth), address(usdg), 2000e6, 1e18);
        spokePool = new MockAcrossSpokePool();
        spokeBridge = new MockBridgeAdapter(guardian, address(spokePool));
        spokeBridgeFallback = new MockBridgeAdapter(guardian, address(spokePool));
        wormhole = new MockWormholeCore();
        core = new MockCoreVault(address(usdc));
        // Security review S-2: the unwind swap floor reads the Core Vault's price source; 2,000 USDC per WETH, the
        // rate the hub tests swap at.
        MockPriceSource(core.priceSource()).setPrice(address(weth), 2000e6);
        escrowImplementation = new TransitEscrow();
    }

    function _mandate() internal view virtual returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = HUB;
        m.hubWormholeChainId = MandateFixture.ARBITRUM_WORMHOLE_CHAIN_ID;
        m.usdc = address(usdc);
        m.addToken(HUB, address(usdc));
        m.addToken(HUB, address(weth));
        m.addToken(SPOKE, address(usdg));
        m.addToken(SPOKE, address(weth));
        m.addSwapAdapter(HUB, address(hubSwap));
        m.addSwapAdapter(SPOKE, address(spokeSwap));

        m.adapters = new AdapterConfig[](3);
        m.adapters[0] = AdapterConfig(HUB, address(hubUni));
        m.adapters[1] = AdapterConfig(HUB, address(hubAave));
        m.adapters[2] = AdapterConfig(SPOKE, address(spokeUni));

        m.pools = new PoolConfig[](3);
        m.pools[0] = PoolConfig(HUB, address(hubUni), HUB_POOL);
        m.pools[1] = PoolConfig(HUB, address(hubAave), AAVE_USDC);
        m.pools[2] = PoolConfig(SPOKE, address(spokeUni), SPOKE_POOL);

        m.spokes = new SpokeConfig[](1);
        m.spokes[0] = SpokeConfig(
            SPOKE, WH_SPOKE, bytes32(uint256(uint160(spokeVaultInMandate))), address(usdg), 1_000_000e6, MAX_REPORT_AGE
        );

        m.bridgeAdapters = new BridgeAdapterConfig[](3);
        m.bridgeAdapters[0] = BridgeAdapterConfig(SPOKE, HUB, hubBridge);
        m.bridgeAdapters[1] = BridgeAdapterConfig(SPOKE, SPOKE, address(spokeBridge));
        m.bridgeAdapters[2] = BridgeAdapterConfig(SPOKE, SPOKE, address(spokeBridgeFallback));

        m.operatingCash = new OperatingCashConfig[](2);
        m.operatingCash[0] = OperatingCashConfig(HUB, 1e6, 3e6);
        m.operatingCash[1] = OperatingCashConfig(SPOKE, SPOKE_FLOOR, SPOKE_TOP_UP);

        m.payoutFeeBps = 200;
        m.minFirstDeposit = 100e6;
        m.performanceFeeBps = 1000;
        m.managementFeeBps = 0;
    }

    function _deploySpoke() internal returns (SpokeVault v) {
        vm.chainId(SPOKE);
        v = new SpokeVault(
            _mandate(),
            FUND_ID,
            SPOKE,
            address(core),
            address(usdg),
            address(spokePool),
            address(wormhole),
            address(escrowImplementation),
            excessRecipient
        );
        spokeUni.setVault(address(v));
        spokeBridge.setVault(address(v));
        spokeBridgeFallback.setVault(address(v));
        vault = v;
    }

    function _deployHub() internal returns (SpokeVault v) {
        vm.chainId(HUB);
        v = new SpokeVault(
            _mandate(),
            FUND_ID,
            HUB,
            address(core),
            address(usdc),
            makeAddr("hubAcrossSpokePool"),
            address(0),
            address(escrowImplementation),
            excessRecipient
        );
        hubUni.setVault(address(v));
        hubAave.setVault(address(v));
        vault = v;
    }

    // ---- spoke helpers ----

    /// @dev A relayer fill from the Across SpokePool carrying this fund's message from the hub.
    function _arrive(uint256 amount, bytes32 transitId, TransferKind kind) internal {
        usdg.mint(address(spokePool), amount);
        spokePool.fill(address(vault), address(usdg), amount, TransitMessage.encode(FUND_ID, HUB, transitId, kind));
    }

    function _disableOperatingCash() internal {
        vm.prank(manager);
        vault.setOperatingCashParameters(0, 0);
    }

    /// @dev DEC-158, DEC-162: the Spoke Vault ignores its vestigial quote argument and the bridge adapter fixes the
    ///      amount to arrive, so the primary mock adapter is set to deliver `outputAmount` on the next send home.
    function _quote(uint256 outputAmount) internal returns (BridgeQuote memory q) {
        MockBridgeNextArrive.set(address(spokeBridge), outputAmount);
        q.outputAmount = outputAmount;
    }

    /// @dev Income for a position: the tokens reach the adapter and are booked as uncollected.
    function _earnIncome(MockPositionAdapter adapter, bytes32 positionKey, uint256 amount0, uint256 amount1) internal {
        (bytes32 poolKey,,,,,) = adapter.position(positionKey);
        (address token0, address token1,,) = adapter.pools(poolKey);
        if (amount0 != 0) MockSpokeToken(token0).mint(address(adapter), amount0);
        if (amount1 != 0) MockSpokeToken(token1).mint(address(adapter), amount1);
        adapter.earnIncome(positionKey, amount0, amount1);
    }

    function _ledgerTotal(address token) internal view returns (uint256 total) {
        total = vault.unallocatedBalance(token) + vault.collectedIncome(token);
        if (token == vault.baseToken()) total += vault.operatingCash();
    }
}
