// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {ManagerRegistry} from "../../../src/core/ManagerRegistry.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {MockPermit2} from "../../mocks/v4/MockPermit2.sol";
import {MockV4} from "../../mocks/v4/MockV4.sol";
import {MockAcrossSpokePool} from "../../mocks/across/MockAcrossSpokePool.sol";
import {MockAaveV3Pool} from "../../mocks/aave/MockAaveV3Pool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {FundMandate} from "../../../script/FundMandate.sol";

/// @notice Shared fixture of the access-control security PoCs: a fund created by the REAL FundFactory (real Core
///         Vault, Spoke Vault, ShareToken, ManagerFeeVault, ValueReportReceiver, Uniswap V4, Aave V3 and Across
///         adapters, real ManagerRegistry) against the repository's mock external protocols (Across SpokePool,
///         Wormhole Core, Aave Pool, Uniswap V4). Nothing under `src/` is mocked.
/// @dev Same two-chain pattern as test/unit/factory/FundFactory.t.sol: the hub factory and the spoke factory are two
///      deployments at the same address, one per simulated chain (state reverted in between).
/// @dev The mock Uniswap V4 pool is initialized at tick 0 (one raw WETH unit for one raw USDC unit) and the price
///      source agrees with it, so amounts read the same in both tokens; only ratios matter to the PoCs.
abstract contract AccessFundFixture is Test, FactoryDeployment, FundMandate {
    uint256 internal constant HUB = 42_161;
    uint256 internal constant SPOKE = 4663;
    uint32 internal constant MAX_REPORT_AGE = 1588;

    MockToken internal usdc;
    MockToken internal weth;
    MockToken internal usdg;
    MockToken internal spokeWeth;
    MockAcrossSpokePool internal hubAcross;
    MockAcrossSpokePool internal spokeAcross;
    MockAaveV3Pool internal aave;
    MockWormholeCore internal hubWormhole;
    MockWormholeCore internal spokeWormhole;
    MockPermit2 internal permit2;
    MockV4 internal v4;
    MockPriceSource internal prices;
    ManagerRegistry internal registry;

    address internal manager = makeAddr("manager");
    address internal recipient = makeAddr("protocolRecipient");
    address internal guardian = makeAddr("guardian");
    address internal registryOwner = makeAddr("registryOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    uint256 internal cleanState;
    FundFactory internal factory;
    Deployment internal hubDeployment;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        usdc = new MockToken("USDC", 6);
        weth = new MockToken("WETH", 18);
        usdg = new MockToken("USDG", 6);
        spokeWeth = new MockToken("WETH", 18);
        hubAcross = new MockAcrossSpokePool(0);
        spokeAcross = new MockAcrossSpokePool(0);
        aave = new MockAaveV3Pool(MockAaveV3Pool.Rounding.HalfUp);
        aave.listReserve(address(usdc));
        hubWormhole = new MockWormholeCore();
        spokeWormhole = new MockWormholeCore();
        permit2 = new MockPermit2();
        v4 = new MockV4(permit2);
        prices = new MockPriceSource();
        prices.setPrice(address(weth), 1e18);
        prices.setPrice(address(usdg), 1e18);
        registry = new ManagerRegistry(registryOwner);
        v4.initialize(_hubPool(), TickMath.getSqrtPriceAtTick(0));
        // Reserves that back swap outputs inside the mock Uniswap V4.
        usdc.mint(address(v4), 1e15);
        weth.mint(address(v4), 1e15);
        cleanState = vm.snapshotState();
        vm.chainId(HUB);
        Deployment memory d;
        d = _deployFactory(_wiring(true), true, d);
        hubDeployment = d;
        factory = d.factory;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Factory and Mandate
    // ---------------------------------------------------------------------------------------------------------------

    function _wiring(bool hub) internal returns (IFundFactory.ProtocolWiring memory w) {
        w.numberOffset = hub ? 0 : 1_000_000;
        w.baseToken = hub ? address(usdc) : address(usdg);
        w.acrossSpokePool = hub ? address(hubAcross) : address(spokeAcross);
        w.wormholeCore = hub ? address(hubWormhole) : address(spokeWormhole);
        w.uniswapV4PoolManager = hub ? address(v4) : makeAddr("spokePoolManager");
        w.uniswapV4PositionManager = hub ? address(v4) : makeAddr("spokePositionManager");
        w.uniswapV4StateView = hub ? address(v4) : makeAddr("spokeStateView");
        w.permit2 = address(permit2);
        w.aaveV3Pool = hub ? address(aave) : address(0);
        w.managerRegistry = hub ? address(registry) : address(0);
        w.priceSource = hub ? address(prices) : address(0);
        w.protocolRecipient = recipient;
        w.guardian = guardian;
        w.flowFeeBps = 25;
    }

    /// @dev The spoke chain's factory, at the hub factory's address (the hub state is reverted, as on another chain).
    function _spokeFactory() internal returns (FundFactory) {
        vm.revertToState(cleanState);
        vm.chainId(SPOKE);
        Deployment memory d;
        return _deployFactory(_wiring(false), false, d).factory;
    }

    function _poolKey(address a, address b, uint24 fee, int24 tickSpacing) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, tickSpacing, IHooks(address(0)));
    }

    function _hubPool() internal view returns (PoolKey memory) {
        return _poolKey(address(weth), address(usdc), 500, 10);
    }

    function _hubPoolId() internal view returns (bytes32) {
        return PoolId.unwrap(_hubPool().toId());
    }

    /// @dev The manager's choices: one hub Uniswap V4 pool, Aave USDC on the hub, Robinhood as the spoke.
    function _plan() internal view returns (FundPlan memory plan) {
        plan.manager = manager;
        plan.hubChainId = HUB;
        plan.usdc = address(usdc);
        plan.hubPool = _hubPool();
        plan.hubAaveAsset = address(usdc);
        plan.spokeChainId = SPOKE;
        plan.spokeWormholeChainId = 72;
        plan.spokeToken = address(usdg);
        plan.spokePool = _poolKey(address(spokeWeth), address(usdg), 500, 10);
        plan.spokeCap = 1_000_000e6;
        plan.maxReportAge = MAX_REPORT_AGE;
        plan.spokeOperatingCashFloor = 5e6;
        plan.spokeOperatingCashTopUp = 10e6;
        plan.minFirstDeposit = 100e6;
        plan.performanceFeeBps = 2000;
        plan.maxBridgeFeeBps = 50;
    }

    /// @dev Creates fund number 1 on the hub from `plan`, as its manager.
    function _createFund(FundPlan memory plan)
        internal
        returns (IFundFactory.FundAddresses memory a, Mandate memory m)
    {
        m = _buildMandate(factory, factory.fundIdOf(HUB, 1, plan.manager), plan);
        vm.prank(plan.manager);
        a = factory.createFund(m, _hubParams(1, plan, _coreVaultCreationCode(hubDeployment.coreVaultLogic)));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------------------------

    function _deposit(CoreVault core, address who, uint256 amount) internal returns (uint256 minted) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(core), amount);
        (minted,) = core.deposit(amount, 0);
        vm.stopPrank();
    }

    function _quote(uint256 outputAmount, address exclusiveRelayer) internal view returns (BridgeQuote memory) {
        return BridgeQuote({
            outputAmount: outputAmount,
            quoteTimestamp: uint32(block.timestamp),
            exclusivityDeadline: exclusiveRelayer == address(0) ? 0 : 3600,
            exclusiveRelayer: exclusiveRelayer
        });
    }

    function _openParams(uint128 amount0Max, uint128 amount1Max) internal view returns (bytes memory) {
        return abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: -600,
                tickUpper: 600,
                liquidity: 0,
                amount0Max: amount0Max,
                amount1Max: amount1Max,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    function _balance(MockToken token, address who) internal view returns (uint256) {
        return IERC20(address(token)).balanceOf(who);
    }

    function _shares(CoreVault core, address who) internal view returns (uint256) {
        return ShareToken(core.shareToken()).balanceOf(who);
    }

    function _hubVault(IFundFactory.FundAddresses memory a) internal pure returns (SpokeVault) {
        return SpokeVault(a.chains[0].spokeVault);
    }
}
