// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {
    Mandate,
    AdapterConfig,
    PoolConfig,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";
import {MockAaveV3Pool} from "../../mocks/aave/MockAaveV3Pool.sol";
import {MockSpokeToken} from "../../mocks/spoke/MockSpokeToken.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockCoreVault} from "../../mocks/spoke/MockCoreVault.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";
import {MockSwapAdapter} from "../../mocks/swap/MockSwapAdapter.sol";

/// @notice (adapters review) The Aave V3 adapter accepts any listed reserve as a Mandate pool (the factory builds its
///         reserve list from the Mandate's pool keys) and reports it as a single-token position `(asset, address(0))`
///         with `isExactValue() == true`. When that reserve is not USDC and the position is in the unwind order, the
///         hub Spoke Vault's automatic unwind reverts at that step (`_unwindRoute` -> `_otherToken` on a single-token
///         pool), before it reads a claimant hint that names a valid Mandate route for the token. Real AaveV3Adapter
///         (over the mock pool with the live rounding) and real hub SpokeVault; mock V4-like adapter and Core Vault.
/// @dev Run: forge test --match-path 'test/review/adapters/AaveNonUsdcReserveUnwind.t.sol' -vv
contract AaveNonUsdcReserveUnwindTest is Test {
    using MandateFixture for Mandate;

    uint256 internal constant HUB = 42_161;
    bytes32 internal constant HUB_POOL = keccak256("hub WETH/USDC");

    address internal manager = makeAddr("manager");
    address internal guardian = makeAddr("guardian");

    MockSpokeToken internal usdc;
    MockSpokeToken internal weth;
    MockPositionAdapter internal hubUni;
    MockAaveV3Pool internal aavePool;
    AaveV3Adapter internal aave;
    MockCoreVault internal core;
    SpokeVault internal vault;
    MockSwapAdapter internal hubSwap;
    bytes32 internal aaveWeth;

    function setUp() public {
        vm.chainId(HUB);
        usdc = new MockSpokeToken("USD Coin", "USDC", 6);
        weth = new MockSpokeToken("Wrapped Ether", "WETH", 18);
        hubUni = new MockPositionAdapter(guardian, false);
        hubUni.addPool(HUB_POOL, address(weth), address(usdc));
        aavePool = new MockAaveV3Pool(MockAaveV3Pool.Rounding.Directional);
        aavePool.listReserve(address(weth));
        core = new MockCoreVault(address(usdc));
        aaveWeth = bytes32(uint256(uint160(address(weth))));

        TransitEscrow escrowImpl = new TransitEscrow();
        hubSwap = new MockSwapAdapter();
        address vaultAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        aave = new AaveV3Adapter(vaultAt, guardian, address(aavePool), assets);
        vault = new SpokeVault(
            _mandate(),
            keccak256("fund"),
            HUB,
            address(core),
            address(usdc),
            makeAddr("hubAcrossSpokePool"),
            address(0),
            address(escrowImpl),
            makeAddr("excess")
        );
        require(address(vault) == vaultAt, "wiring");
        hubUni.setVault(address(vault));
        usdc.mint(address(core), 10_000e6);
    }

    function _mandate() internal view returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = HUB;
        m.usdc = address(usdc);
        m.hubWormholeChainId = MandateFixture.ARBITRUM_WORMHOLE_CHAIN_ID;
        m.addToken(HUB, address(usdc));
        m.addToken(HUB, address(weth));
        m.addSwapAdapter(HUB, address(hubSwap));
        m.adapters = new AdapterConfig[](2);
        m.adapters[0] = AdapterConfig(HUB, address(hubUni));
        m.adapters[1] = AdapterConfig(HUB, address(aave));
        m.pools = new PoolConfig[](2);
        m.pools[0] = PoolConfig(HUB, address(hubUni), HUB_POOL);
        m.pools[1] = PoolConfig(HUB, address(aave), aaveWeth);
        m.spokes = new SpokeConfig[](0);
        m.bridgeAdapters = new BridgeAdapterConfig[](0);
        m.operatingCash = new OperatingCashConfig[](1);
        m.operatingCash[0] = OperatingCashConfig(HUB, 1e6, 3e6);
        m.payoutFeeBps = 200;
        m.minFirstDeposit = 100e6;
        m.performanceFeeBps = 1000;
    }

    /// @dev Ported to fix/pp-sc-fix-independent-review (review L-05 / adapters L-03, plan T14): PARTIAL. e5c778a: the
    ///      step reverted `UnexpectedToken(WETH)` with or without a route hint. Now a hint naming the Mandate WETH/USDC
    ///      route unwinds it (floored at the price source less 5%); without a hint the step is refused by name
    ///      (`MissingUnwindSwap`), so a claimant who passes none still gets a Partial Payout. STILL PRESENT: any listed
    ///      reserve is accepted and declared exact-value (`isExactValue()` true for aWETH, no vault reads it today).
    function test_REVIEW_L05_nonUsdcAaveReserveUnwindsThroughTheHintedRoute() public {
        // The fund is created: the Aave adapter took WETH as a reserve and reports it as a single-token position.
        (address t0, address t1) = aave.poolTokens(aaveWeth);
        assertEq(t0, address(weth));
        assertEq(t1, address(0));
        assertTrue(aave.isExactValue(), "an aWETH supply is still declared exact-value");
        MockPriceSource(core.priceSource()).setPrice(address(weth), 2000e6);

        // 1,000 USDC allocated; the manager buys 0.5 WETH through the Mandate WETH/USDC route and supplies it to Aave.
        core.allocate(ISpokeVault(address(vault)), 1000e6);
        weth.mint(address(hubUni), 1e18);
        hubUni.addLiquidity(address(weth), 1e18);
        hubUni.setSwapRate(1e18, 2000e6);
        vm.startPrank(manager);
        vault.swapExactInput(address(hubUni), HUB_POOL, address(usdc), 1000e6, 0, "");
        vault.openPosition(address(aave), aaveWeth, 0.5e18, 0, abi.encode(uint256(0.5e18)));
        vm.stopPrank();
        hubUni.setSwapRate(2000e6, 1e18);
        assertEq(vault.positions().length, 1);

        // A claim needs 500 USDC of unwind. Without a hint the Aave WETH step is refused by name.
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.MissingUnwindSwap.selector, address(weth)));
        core.unwind(ISpokeVault(address(vault)), 500e6, "");

        // A hint naming a pool that does not pair WETH with USDC is refused (re-attack: the route stays closed).
        SpokeVaultTypes.UnwindHint[] memory hints = new SpokeVaultTypes.UnwindHint[](1);
        hints[0].swaps = new SpokeVaultTypes.UnwindSwap[](1);
        hints[0].swaps[0] = SpokeVaultTypes.UnwindSwap(address(aave), aaveWeth, address(weth), 0, "");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.UnexpectedToken.selector, address(weth)));
        core.unwind(ISpokeVault(address(vault)), 500e6, abi.encode(hints));

        // With the hint naming the Mandate WETH/USDC route the step unwinds and reaches the target.
        hints[0].swaps[0] = SpokeVaultTypes.UnwindSwap(address(hubUni), HUB_POOL, address(weth), 0, "");
        uint256 held = core.unwind(ISpokeVault(address(vault)), 500e6, abi.encode(hints));
        assertGe(held, 500e6, "the unwind reached its target through the hinted route");
        assertGe(core.idleReturned(), 500e6, "and paid it to the Core Vault");
    }
}
