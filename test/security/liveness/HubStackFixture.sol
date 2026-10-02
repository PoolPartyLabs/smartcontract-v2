// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FundSeed} from "../../utils/FundSeed.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {
    Mandate,
    AdapterConfig,
    PoolConfig,
    UnwindStep,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {MockPermit2} from "../../mocks/v4/MockPermit2.sol";
import {MockV4} from "../../mocks/v4/MockV4.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {MockReportReceiver} from "../../mocks/core/MockReportReceiver.sol";

/// @notice A hub-only fund (OQ-08) built from the REAL contracts: CoreVault (linked CoreVaultLogic), the hub SpokeVault
///         (linked SpokeCrossChainLib) and the real UniswapV4Adapter, over the MockV4 pool (PoolManager, PositionManager
///         and StateView in one) used by the adapter unit tests. Only the protocol edges are mocked (V4, price source,
///         registry, receiver). WETH is token0 and USDC token1 (fixed addresses), the pool sits at 2,500 USDC per WETH
///         and the price source quotes exactly the pool price, so a position's value marked at the oracle equals its
///         pool value when the pool is at its true price.
abstract contract HubStackFixture is Test, FundSeed {
    uint256 internal constant HUB = 42_161;
    bytes32 internal constant FUND_ID = keccak256("pool-party-liveness-fund");
    /// @dev Tick of 2,500 USDC (6 decimals) per WETH (18 decimals): price 2.5e-9 in base units.
    int24 internal constant TRUE_TICK = -198_080;
    int24 internal constant HALF_RANGE = 500; // about 5% each side

    MockToken internal weth;
    MockToken internal usdc;
    MockPermit2 internal permit2;
    MockV4 internal v4;
    MockPriceSource internal prices;
    MockManagerRegistry internal registry;
    MockReportReceiver internal receiver;
    TransitEscrow internal escrowImpl;
    UniswapV4Adapter internal adapter;
    SpokeVault internal hubSpoke;
    CoreVault internal vault;
    ShareToken internal shares;
    PoolKey internal key;
    bytes32 internal poolId;

    address internal manager = makeAddr("manager");
    address internal guardian = makeAddr("guardian");
    address internal protocol = makeAddr("protocolRecipient");
    address internal excess = makeAddr("excessRecipient");
    address internal acrossPool = makeAddr("acrossSpokePool");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        vm.chainId(HUB);
        vm.warp(1_800_000_000);
        // Fixed addresses so WETH is currency0 and USDC currency1.
        weth = MockToken(address(0xA000));
        usdc = MockToken(address(0xB000));
        deployCodeTo("test/mocks/v4/MockToken.sol:MockToken", abi.encode("WETH", uint8(18)), address(weth));
        deployCodeTo("test/mocks/v4/MockToken.sol:MockToken", abi.encode("USDC", uint8(6)), address(usdc));

        permit2 = new MockPermit2();
        v4 = new MockV4(permit2);
        key = PoolKey(Currency.wrap(address(weth)), Currency.wrap(address(usdc)), 500, 10, IHooks(address(0)));
        poolId = PoolId.unwrap(key.toId());
        v4.setTick(poolId, TRUE_TICK);
        // Reserves that back swap outputs and TAKEs inside the mock protocol.
        weth.mint(address(v4), 1e24);
        usdc.mint(address(v4), 1e15);

        prices = new MockPriceSource();
        prices.setPrice(address(weth), _poolPrice1e18());
        registry = new MockManagerRegistry();
        receiver = new MockReportReceiver();
        escrowImpl = new TransitEscrow();

        uint64 nonce = vm.getNonce(address(this));
        address predictedSpoke = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedCore = vm.computeCreateAddress(address(this), nonce + 2);

        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        adapter = new UniswapV4Adapter(
            predictedSpoke,
            guardian,
            IPoolManager(address(v4)),
            IPositionManager(address(v4)),
            IStateView(address(v4)),
            IAllowanceTransfer(address(permit2)),
            keys
        );
        Mandate memory m = _mandate();
        hubSpoke = new SpokeVault(
            m, FUND_ID, HUB, predictedCore, address(usdc), acrossPool, address(0), address(escrowImpl), excess
        );
        vault = new CoreVault(m, _config());
        // DEC-127: this contract plays the factory and seeds the fund (FundSeed).
        _seedFund(address(vault), vault.usdc(), vault.flowFeeBps());
        assertEq(address(hubSpoke), predictedSpoke, "spoke prediction");
        assertEq(address(vault), predictedCore, "core prediction");
        receiver.setCoreVault(address(vault));
        shares = ShareToken(vault.shareToken());
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------------------------

    function _mandate() internal view returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = HUB;
        m.usdc = address(usdc);
        m.adapters = new AdapterConfig[](1);
        m.adapters[0] = AdapterConfig(HUB, address(adapter));
        m.pools = new PoolConfig[](1);
        m.pools[0] = PoolConfig(HUB, address(adapter), poolId);
        m.unwindOrder = new UnwindStep[](1);
        m.unwindOrder[0] = UnwindStep(HUB, address(adapter), poolId);
        m.spokes = new SpokeConfig[](0);
        m.bridgeAdapters = new BridgeAdapterConfig[](0);
        m.operatingCash = new OperatingCashConfig[](0);
        m.payoutFeeBps = 200;
        m.standardPayoutTerm = 72 hours;
        m.minFirstDeposit = FIXTURE_MIN_FIRST_DEPOSIT;
        m.performanceFeeBps = 2000;
        m.managementFeeBps = 0;
        m.maxBridgeFeeBps = 50;
    }

    function _config() internal view returns (CoreVaultConfig memory c) {
        c.fundId = FUND_ID;
        c.usdc = address(usdc);
        c.hubSpokeVault = address(hubSpoke);
        c.reportReceiver = address(receiver);
        c.managerRegistry = address(registry);
        c.priceSource = address(prices);
        c.acrossSpokePool = acrossPool;
        c.protocolRecipient = protocol;
        c.excessRecipient = excess;
        c.escrowImplementation = address(escrowImpl);
        c.flowFeeBps = 25;
        c.factory = address(this);
        c.incomeTokens = new address[](1);
        c.incomeTokens[0] = address(weth);
        c.shareName = "Pool Party Fund 1";
        c.shareSymbol = "PP-1";
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------------------------

    function _deposit(address who, uint256 amount) internal returns (uint256 minted) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        (minted,) = vault.deposit(amount, 0);
        vm.stopPrank();
    }

    function _request(address who, uint256 amount, ICoreVault.PayoutMode mode) internal {
        vm.prank(who);
        vault.requestPayout(amount, mode);
    }

    function _claim(address who) internal returns (ICoreVault.PayoutReceipt memory) {
        vm.prank(who);
        return vault.claimPayout("");
    }

    /// @dev Manager allocates `usdcAmount` to the hub Spoke Vault, swaps `usdcToSwap` of it into WETH at the pool
    ///      price and opens one position of about 5% each side of the current tick with everything swapped plus
    ///      `usdcInPosition`. Returns the position key.
    function _openHubPosition(uint256 usdcAmount, uint256 usdcToSwap, uint256 usdcInPosition)
        internal
        returns (bytes32 positionKey)
    {
        vm.startPrank(manager);
        vault.allocateToHubSpokeVault(usdcAmount);
        // USDC -> WETH at the true price: 1e6 USDC base units buy 4e14 wei.
        v4.setSwap(4e26, 10_000);
        uint256 wethOut = hubSpoke.swapExactInput(address(adapter), poolId, address(usdc), usdcToSwap, 0, "");
        UniswapV4Adapter.OpenParams memory p = UniswapV4Adapter.OpenParams({
            tickLower: TRUE_TICK - HALF_RANGE,
            tickUpper: TRUE_TICK + HALF_RANGE,
            liquidity: 0,
            amount0Max: uint128(wethOut),
            amount1Max: uint128(usdcInPosition),
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        (positionKey,,) = hubSpoke.openPosition(address(adapter), poolId, wethOut, usdcInPosition, abi.encode(p));
        vm.stopPrank();
        // WETH -> USDC for any later swap (unwind): 1e18 wei sells for 2,500e6.
        v4.setSwap(2.5e9, 10_000);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Measures
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev IPriceSource scale: USDC base units per WETH base unit, times 1e18, read from the pool's sqrt price.
    function _poolPrice1e18() internal view returns (uint256) {
        (uint160 sqrtP,,,) = v4.getSlot0(PoolId.wrap(poolId));
        return Math.mulDiv(uint256(sqrtP) * uint256(sqrtP), 1e18, 1 << 192);
    }

    /// @dev The oracle-marked USDC value of the hub position: WETH leg at the price source, USDC at par.
    function _markedPositionValue(bytes32 positionKey) internal view returns (uint256) {
        IAdapter.PositionValue memory v = adapter.positionValue(positionKey);
        (uint256 price,) = prices.priceInUsdc(address(weth));
        return Math.mulDiv(v.principal0, price, 1e18) + v.principal1;
    }
}
