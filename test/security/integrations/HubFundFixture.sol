// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FundSeed} from "../../utils/FundSeed.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {
    Mandate,
    AdapterConfig,
    PoolConfig,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";
import {MockPermit2} from "../../mocks/v4/MockPermit2.sol";
import {V4SwapRouter} from "../../mocks/v4/V4SwapRouter.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {MockAcrossSpokePool} from "../../mocks/core/MockAcrossSpokePool.sol";
import {MockReportReceiver} from "../../mocks/core/MockReportReceiver.sol";
import {PoolLibV4} from "./mocks/PoolLibV4.sol";
import {BlocklistToken} from "./mocks/BlocklistToken.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";
import {MockSwapAdapter} from "../../mocks/swap/MockSwapAdapter.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";

/// @notice A hub-only fund on Arbitrum (42161) built from the real contracts: `CoreVault` (linked `CoreVaultLogic`),
///         the hub `SpokeVault` (linked `SpokeCrossChainLib`), `UniswapV4Adapter`, `ShareToken`, `ManagerFeeVault` and
///         `TransitEscrow`, over a WETH/USDC 0.05% pool whose swap and liquidity mathematics are v4-core's own
///         (`PoolLibV4`). Only what the fund does not custody is mocked: the price source (WETH at a fixed 2,500 USDC,
///         playing Chainlink), the manager registry, the report receiver and the Across SpokePool (never called here).
/// @dev WETH is `currency0` and USDC `currency1`, as on Arbitrum One (0x82aF... < 0xaf88...). An external liquidity
///      provider (this contract) holds a wide position around the current price so the pool has depth of its own;
///      the fund's position is opened by the manager through the vault and adapter, exactly as in production.
abstract contract HubFundFixture is Test, FundSeed {
    using MandateFixture for Mandate;

    uint256 internal constant HUB = 42_161;
    bytes32 internal constant FUND_ID = keccak256("sec-integrations hub fund");
    /// @dev USDC per WETH: the external ("Chainlink") price and the pool's starting price.
    uint256 internal constant WETH_PRICE = 2500;
    /// @dev `IPriceSource.priceInUsdc(weth)`: USDC base units per wei, times 1e18.
    uint256 internal constant WETH_PRICE_1E18 = WETH_PRICE * 1e6;
    uint256 internal constant Q96 = 1 << 96;
    /// @dev ShareMath: price scale 1e18 over 1e18-unit shares, i.e. `usdc = shares * price / 1e36`.
    uint256 internal constant PRICE_DENOMINATOR = 1e36;

    BlocklistToken internal weth;
    BlocklistToken internal usdc;
    MockPermit2 internal permit2;
    PoolLibV4 internal pool;
    V4SwapRouter internal router;
    PoolKey internal key;
    bytes32 internal poolId;
    uint160 internal startSqrtPrice;
    int24 internal startTick;

    MockPriceSource internal prices;
    MockManagerRegistry internal registry;
    MockAcrossSpokePool internal across;
    MockReportReceiver internal receiver;
    TransitEscrow internal escrowImpl;

    UniswapV4Adapter internal adapter;
    SpokeVault internal hubVault;
    MockSwapAdapter internal hubSwap;
    MockWormholeCore internal hubWormhole;
    CoreVault internal core;
    ShareToken internal shares;

    address internal manager = makeAddr("manager");
    address internal guardian = makeAddr("guardian");
    address internal protocol = makeAddr("protocolRecipient");
    address internal excess = makeAddr("excessRecipient");

    function setUp() public virtual {
        vm.chainId(HUB);
        vm.warp(1_800_000_000);

        // Tokens in Arbitrum's order: WETH below USDC.
        usdc = new BlocklistToken("USDC", 6);
        do {
            weth = new BlocklistToken("WETH", 18);
        } while (address(weth) > address(usdc));

        permit2 = new MockPermit2();
        pool = new PoolLibV4(permit2);
        router = new V4SwapRouter(IPoolManager(address(pool)));
        key = PoolKey(Currency.wrap(address(weth)), Currency.wrap(address(usdc)), 500, 10, IHooks(address(0)));
        poolId = PoolId.unwrap(key.toId());
        startSqrtPrice = _sqrtPriceFor(WETH_PRICE);
        startTick = pool.initialize(key, startSqrtPrice);

        prices = new MockPriceSource();
        prices.setPrice(address(weth), WETH_PRICE_1E18);
        registry = new MockManagerRegistry();
        across = new MockAcrossSpokePool();
        receiver = new MockReportReceiver();
        escrowImpl = new TransitEscrow();

        // The adapter needs its vault, the hub Spoke Vault its Core Vault and the Core Vault its hub Spoke Vault:
        // three consecutive deployments from this contract, so every address is predicted from the nonce.
        hubSwap = new MockSwapAdapter();
        hubWormhole = new MockWormholeCore();
        uint64 nonce = vm.getNonce(address(this));
        address adapterAddress = vm.computeCreateAddress(address(this), nonce);
        address hubVaultAddress = vm.computeCreateAddress(address(this), nonce + 1);
        address coreAddress = vm.computeCreateAddress(address(this), nonce + 2);

        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        adapter = new UniswapV4Adapter(
            hubVaultAddress,
            guardian,
            IPoolManager(address(pool)),
            IPositionManager(address(pool)),
            IStateView(address(pool)),
            IAllowanceTransfer(address(permit2)),
            keys
        );
        Mandate memory m = _mandate(adapterAddress);
        hubVault = new SpokeVault(
            m, FUND_ID, HUB, coreAddress, address(usdc), address(across), address(0), address(escrowImpl), excess
        );
        core = new CoreVault(m, _config(hubVaultAddress));
        // DEC-127: this contract plays the factory and seeds the fund (FundSeed).
        _seedFund(address(core), core.usdc(), core.flowFeeBps());
        assertEq(address(adapter), adapterAddress, "adapter prediction");
        assertEq(address(hubVault), hubVaultAddress, "hub vault prediction");
        assertEq(address(core), coreAddress, "core vault prediction");
        receiver.setCoreVault(address(core));
        shares = ShareToken(core.shareToken());
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Mandate and wiring
    // ---------------------------------------------------------------------------------------------------------------

    function _mandate(address hubAdapter) internal view returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = HUB;
        m.usdc = address(usdc);
        m.hubWormholeChainId = MandateFixture.ARBITRUM_WORMHOLE_CHAIN_ID;
        m.addToken(HUB, address(usdc));
        m.addToken(HUB, address(weth));
        m.addSwapAdapter(HUB, address(hubSwap));
        m.adapters = new AdapterConfig[](1);
        m.adapters[0] = AdapterConfig(HUB, hubAdapter);
        m.pools = new PoolConfig[](1);
        m.pools[0] = PoolConfig(HUB, hubAdapter, poolId);
        m.spokes = new SpokeConfig[](0);
        m.bridgeAdapters = new BridgeAdapterConfig[](0);
        m.operatingCash = new OperatingCashConfig[](0);
        m.payoutFeeBps = 200;
        m.minFirstDeposit = FIXTURE_MIN_FIRST_DEPOSIT;
        m.performanceFeeBps = 2000;
        m.managementFeeBps = 0;
    }

    function _config(address hubSpokeVault) internal view returns (CoreVaultConfig memory c) {
        c.fundId = FUND_ID;
        c.usdc = address(usdc);
        c.hubSpokeVault = hubSpokeVault;
        c.reportReceiver = address(receiver);
        c.managerRegistry = address(registry);
        c.priceSource = address(prices);
        c.acrossSpokePool = address(across);
        c.wormholeCore = address(hubWormhole);
        c.protocolRecipient = protocol;
        c.excessRecipient = excess;
        c.escrowImplementation = address(escrowImpl);
        c.flowFeeBps = 25;
        c.factory = address(this);
        c.shareName = "Pool Party Fund 1";
        c.shareSymbol = "PP-1";
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Pool helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev sqrtPriceX96 of `usdcPerWeth` USDC per WETH with WETH as currency0: sqrt(usdcPerWeth * 1e6 / 1e18) * 2^96.
    function _sqrtPriceFor(uint256 usdcPerWeth) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(usdcPerWeth * 1e6, 1 << 192, 1e18)));
    }

    /// @dev USDC per WETH at `sqrtPriceX96`, in USDC base units per whole WETH.
    function _usdcPerWeth(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        return Math.mulDiv(1e18, priceX128, 1 << 128);
    }

    function _spotSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = pool.getSlot0(PoolId.wrap(poolId));
    }

    /// @dev `tick` rounded toward negative infinity to the pool's tick spacing.
    function _aligned(int24 tick) internal pure returns (int24) {
        int24 spacing = 10;
        int24 r = tick / spacing * spacing;
        if (tick < 0 && r != tick) r -= spacing;
        return r;
    }

    /// @dev Ticks `bps` below and above the current price (1.0001^tick), aligned to the spacing.
    function _rangeAround(uint256 bps) internal view returns (int24 lower, int24 upper) {
        uint160 lo = uint160(Math.mulDiv(startSqrtPrice, Math.sqrt((10_000 - bps) * 1e18 / 10_000 * 1e18), 1e18));
        uint160 hi = uint160(Math.mulDiv(startSqrtPrice, Math.sqrt((10_000 + bps) * 1e18 / 10_000 * 1e18), 1e18));
        lower = _aligned(TickMath.getTickAtSqrtPrice(lo));
        upper = _aligned(TickMath.getTickAtSqrtPrice(hi)) + 10;
    }

    /// @dev This contract mints an external position: the pool's own depth, independent of the fund.
    function _provideExternalLiquidity(int24 lower, int24 upper, uint256 wethAmount, uint256 usdcAmount)
        internal
        returns (uint128 liquidity)
    {
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            _spotSqrtPrice(),
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            wethAmount,
            usdcAmount
        );
        weth.mint(address(this), wethAmount);
        usdc.mint(address(this), usdcAmount);
        weth.approve(address(permit2), type(uint256).max);
        usdc.approve(address(permit2), type(uint256).max);
        permit2.approve(address(weth), address(pool), type(uint160).max, type(uint48).max);
        permit2.approve(address(usdc), address(pool), type(uint160).max, type(uint48).max);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE));
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(key, lower, upper, uint256(liquidity), type(uint128).max, type(uint128).max, address(this), "");
        params[1] = abi.encode(key.currency0, uint256(0), true);
        params[2] = abi.encode(key.currency1, uint256(0), true);
        pool.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @dev A swap by `who` through the test router: exact input of `amountIn`, stopping at `sqrtPriceLimit`.
    function _swapAs(address who, bool zeroForOne, uint256 amountIn, uint160 sqrtPriceLimit) internal {
        vm.startPrank(who);
        weth.approve(address(router), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        router.swap(key, zeroForOne, -int256(amountIn), sqrtPriceLimit);
        vm.stopPrank();
    }

    /// @dev The market: an arbitrageur (this contract, with its own funds) brings the pool back to the external price,
    ///      as arbitrage bots do after any swap that moves a pool away from the market.
    function _arbToExternalPrice() internal {
        uint160 spot = _spotSqrtPrice();
        if (spot == startSqrtPrice) return;
        bool sellWeth = spot > startSqrtPrice;
        uint256 amountIn = sellWeth ? 100_000e18 : 100_000_000e6;
        if (sellWeth) weth.mint(address(this), amountIn);
        else usdc.mint(address(this), amountIn);
        _swapAs(address(this), sellWeth, amountIn, startSqrtPrice);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fund helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _deposit(address who, uint256 amount) internal returns (uint256 minted) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(core), amount);
        (minted,) = core.deposit(amount, 0);
        vm.stopPrank();
    }

    /// @dev The manager allocates `usdcAmount` of Free Idle to the hub Spoke Vault, swaps half of it into WETH at the
    ///      external price through the Mandate swap adapter (DEC-136: never in the fund's pool, so the pool stays at
    ///      the external price) and opens a position over `[lower, upper]` with everything the swap produced.
    function _allocateAndOpen(uint256 usdcAmount, int24 lower, int24 upper)
        internal
        returns (bytes32 positionKey, uint256 used0, uint256 used1)
    {
        vm.startPrank(manager);
        core.allocateToHubSpokeVault(usdcAmount);
        uint256 half = usdcAmount / 2;
        hubSwap.setPrice(address(usdc), address(weth), 1e18, WETH_PRICE * 1e6);
        uint256 wethBought = hubVault.swap(address(hubSwap), address(usdc), address(weth), half, 0, "");
        uint256 usdcLeft = hubVault.unallocatedBalance(address(usdc));
        (positionKey, used0, used1) = hubVault.openPosition(
            address(adapter),
            poolId,
            wethBought,
            usdcLeft,
            abi.encode(
                UniswapV4Adapter.OpenParams({
                    tickLower: lower,
                    tickUpper: upper,
                    liquidity: 0,
                    amount0Max: uint128(wethBought),
                    amount1Max: uint128(usdcLeft),
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            )
        );
        vm.stopPrank();
    }

    /// @dev USDC value of a WETH amount at the external price.
    function _fair(uint256 wethAmount) internal pure returns (uint256) {
        return Math.mulDiv(wethAmount, WETH_PRICE_1E18, 1e18);
    }

    /// @dev Wealth of `who` at the external price: USDC, WETH and shares at the current Share Price.
    function _wealth(address who) internal view returns (uint256) {
        return usdc.balanceOf(who) + _fair(weth.balanceOf(who))
            + Math.mulDiv(shares.balanceOf(who), core.sharePrice(), PRICE_DENOMINATOR);
    }
}
