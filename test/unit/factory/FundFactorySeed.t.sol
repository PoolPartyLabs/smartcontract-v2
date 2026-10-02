// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {MockAcrossSpokePool} from "../../mocks/across/MockAcrossSpokePool.sol";
import {MockAaveV3Pool} from "../../mocks/aave/MockAaveV3Pool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {AnyPriceSource} from "../../mocks/core/AnyPriceSource.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {FundMandate} from "../../../script/FundMandate.sol";
import {V3Stub} from "../../utils/V3Stub.sol";

/// @notice DEC-127, DEC-061, DEC-113: `FundFactory.createFund` seeds the fund with the manager's own capital in the
///         creation transaction: no fund exists without its seed, and the first shares are the manager's. DEC-115,
///         DEC-125 item 3: the performance fee is at least the registry's minimum manager fee at creation.
contract FundFactorySeedTest is Test, FactoryDeployment, FundMandate {
    uint256 internal constant HUB = 42_161;
    uint256 internal constant SPOKE = 4663;

    MockToken internal usdc;
    MockToken internal weth;
    MockToken internal usdg;
    MockToken internal spokeWeth;
    MockAaveV3Pool internal aave;

    address internal manager = makeAddr("manager");
    address internal recipient = makeAddr("protocolRecipient");
    address internal registry = address(new MockManagerRegistry());

    FundFactory internal factory;
    Deployment internal hubDeployment;

    function setUp() public {
        usdc = new MockToken("USDC", 6);
        weth = new MockToken("WETH", 18);
        usdg = new MockToken("USDG", 6);
        spokeWeth = new MockToken("WETH", 18);
        aave = new MockAaveV3Pool(MockAaveV3Pool.Rounding.HalfUp);
        aave.listReserve(address(usdc));
        vm.chainId(HUB);
        IFundFactory.ProtocolWiring memory w;
        w.baseToken = address(usdc);
        w.acrossSpokePool = address(new MockAcrossSpokePool(0));
        w.wormholeCore = address(new MockWormholeCore());
        w.uniswapV4PoolManager = makeAddr("hubPoolManager");
        w.uniswapV4PositionManager = makeAddr("hubPositionManager");
        w.uniswapV4StateView = makeAddr("hubStateView");
        w.permit2 = makeAddr("permit2");
        w.aaveV3Pool = address(aave);
        V3Stub.wire(w);
        w.managerRegistry = registry;
        w.priceSource = address(new AnyPriceSource());
        w.protocolRecipient = recipient;
        w.guardian = makeAddr("guardian");
        w.flowFeeBps = 25;
        Deployment memory d;
        hubDeployment = _deployFactory(w, true, d);
        factory = hubDeployment.factory;
    }

    function _poolKey(address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 500, 10, IHooks(address(0)));
    }

    function _plan(uint256 seedAmount) internal view returns (FundPlan memory plan) {
        plan.manager = manager;
        plan.hubChainId = HUB;
        plan.hubWormholeChainId = WORMHOLE_ARBITRUM;
        plan.usdc = address(usdc);
        plan.hubPool = _poolKey(address(weth), address(usdc));
        plan.hubAaveAsset = address(usdc);
        plan.spokeChainId = SPOKE;
        plan.spokeWormholeChainId = 72;
        plan.spokeToken = address(usdg);
        plan.spokePool = _poolKey(address(spokeWeth), address(usdg));
        plan.spokeCap = 1_000_000e6;
        plan.maxReportAge = 1588;
        plan.spokeOperatingCashFloor = 5e6;
        plan.spokeOperatingCashTopUp = 10e6;
        plan.minFirstDeposit = 100e6;
        plan.performanceFeeBps = 2000;
        plan.seedAmount = seedAmount;
    }

    function _create(uint256 seedAmount, uint256 approved)
        internal
        returns (IFundFactory.FundAddresses memory a, IFundFactory.HubParams memory p, Mandate memory m)
    {
        (a, p, m) = _createWithFee(seedAmount, approved, 2000);
    }

    function _createWithFee(uint256 seedAmount, uint256 approved, uint16 performanceFeeBps)
        internal
        returns (IFundFactory.FundAddresses memory a, IFundFactory.HubParams memory p, Mandate memory m)
    {
        FundPlan memory plan = _plan(seedAmount);
        plan.performanceFeeBps = performanceFeeBps;
        m = _buildMandate(factory, factory.fundIdOf(HUB, 1, manager), plan);
        p = _hubParams(1, plan, _coreVaultCreationCode(hubDeployment));
        usdc.mint(manager, approved);
        vm.prank(manager);
        usdc.approve(address(factory), approved);
        vm.prank(manager);
        a = factory.createFund(m, p);
    }

    /// @dev DEC-113 example on the seed: 100,000 pays 250 and mints 99,750 shares at 1.00, all in one transaction.
    function test_DEC127_createFundSeedsTheFundAtomically() public {
        FundPlan memory plan = _plan(100_000e6);
        bytes32 fundId = factory.fundIdOf(HUB, 1, manager);
        Mandate memory m = _buildMandate(factory, fundId, plan);
        IFundFactory.HubParams memory p = _hubParams(1, plan, _coreVaultCreationCode(hubDeployment));
        usdc.mint(manager, 100_000e6);
        vm.prank(manager);
        usdc.approve(address(factory), 100_000e6);

        vm.expectEmit(factory.addressOf(fundId, "CoreVault", HUB));
        emit ICoreVaultLifecycle.FundSeeded(manager, 99_750e6, 250e6, 99_750e18);
        vm.prank(manager);
        IFundFactory.FundAddresses memory a = factory.createFund(m, p);

        CoreVault core = CoreVault(a.coreVault);
        ShareToken shares = ShareToken(a.shareToken);
        assertEq(core.factory(), address(factory));
        assertEq(shares.balanceOf(manager), 99_750e18, "the fund is born with the manager's shares");
        assertEq(shares.totalSupply(), 99_750e18);
        assertEq(core.idle(), 99_750e6);
        assertEq(core.sharePrice(), 1e24, "DEC-061: 1.00 per share");
        assertEq(core.managerPeakShares(), 99_750e18);
        assertEq(usdc.balanceOf(recipient), 250e6, "DEC-113: the seed pays the flow fee");
        assertEq(usdc.balanceOf(manager), 0);
        assertEq(usdc.balanceOf(address(factory)), 0, "the factory keeps nothing");
        assertEq(usdc.allowance(address(factory), a.coreVault), 0, "the exact approval was spent");
    }

    /// @dev The sub-share remainder never leaves the manager (DEC-035): the factory pulls only what the seed costs.
    function test_DEC127_factoryPullsOnlyWhatTheSeedCosts() public {
        (IFundFactory.FundAddresses memory a,,) = _create(100.5e6, 100.5e6);
        assertEq(ShareToken(a.shareToken).balanceOf(manager), 100e18);
        assertEq(usdc.balanceOf(manager), 100.5e6 - 100e6 - 0.25125e6, "the remainder stays with the manager");
        assertEq(usdc.balanceOf(address(factory)), 0);
    }

    /// @dev DEC-061, DEC-127: a seed below the Mandate minimum refuses the whole creation; nothing is left behind.
    function test_DEC061_seedBelowTheMinimumRevertsTheCreation() public {
        FundPlan memory plan = _plan(99e6);
        Mandate memory m = _buildMandate(factory, factory.fundIdOf(HUB, 1, manager), plan);
        IFundFactory.HubParams memory p = _hubParams(1, plan, _coreVaultCreationCode(hubDeployment));
        usdc.mint(manager, 99e6);
        vm.prank(manager);
        usdc.approve(address(factory), 99e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BelowMinFirstDeposit.selector, 99e6, 100e6));
        factory.createFund(m, p);
        assertEq(factory.nextCreationNumber(), 1, "no number consumed");
        assertEq(factory.addressOf(factory.fundIdOf(HUB, 1, manager), "CoreVault", HUB).code.length, 0);
        assertEq(usdc.balanceOf(manager), 99e6);
    }

    /// @dev Without the manager's approval there is no seed, and so no fund.
    function test_DEC127_noApprovalNoFund() public {
        FundPlan memory plan = _plan(100e6);
        Mandate memory m = _buildMandate(factory, factory.fundIdOf(HUB, 1, manager), plan);
        IFundFactory.HubParams memory p = _hubParams(1, plan, _coreVaultCreationCode(hubDeployment));
        usdc.mint(manager, 100e6);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 99.25e6)
        );
        factory.createFund(m, p);
        assertEq(factory.nextCreationNumber(), 1);
    }

    /// @dev A zero seed in the plan defaults to the Mandate minimum (`FundMandate._hubParams`).
    function test_DEC127_planWithoutSeedSeedsTheMinimum() public {
        (, IFundFactory.HubParams memory p,) = _create(0, 100e6);
        assertEq(p.seedAmount, 100e6);
    }

    /// @dev Nobody else seeds the created fund again, the manager included.
    function test_DEC127_theCreatedFundCannotBeSeededAgain() public {
        (IFundFactory.FundAddresses memory a,,) = _create(100e6, 100e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.NotFactory.selector, manager));
        CoreVault(a.coreVault).seed(100e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Minimum manager fee (DEC-115, DEC-125 item 3, D-36)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A Mandate below the registry's minimum is refused at creation; at the minimum it is created and the Core
    ///      Vault records the minimum as the floor of `decreaseManagerFee`.
    function test_DEC125_createFundRequiresTheMinimumManagerFee() public {
        MockManagerRegistry(registry).setMinManagerFeeBps(1000);
        FundPlan memory plan = _plan(100e6);
        plan.performanceFeeBps = 999;
        Mandate memory m = _buildMandate(factory, factory.fundIdOf(HUB, 1, manager), plan);
        IFundFactory.HubParams memory p = _hubParams(1, plan, _coreVaultCreationCode(hubDeployment));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.ManagerFeeBelowMinimum.selector, 999, 1000));
        factory.createFund(m, p);

        (IFundFactory.FundAddresses memory a,,) = _createWithFee(100e6, 100e6, 1000);
        assertEq(CoreVault(a.coreVault).minPerformanceFeeBps(), 1000);
        assertEq(CoreVault(a.coreVault).performanceFeeBps(), 1000);
    }

    /// @dev D-36: the creation-time minimum floors `decreaseManagerFee`; a later registry change never binds the fund.
    function test_DEC125_minimumAtCreationFloorsDecreaseManagerFee() public {
        MockManagerRegistry(registry).setMinManagerFeeBps(1000);
        (IFundFactory.FundAddresses memory a,,) = _createWithFee(100e6, 100e6, 2000);
        CoreVault core = CoreVault(a.coreVault);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.ManagerFeeBelowMinimum.selector, 999, 1000));
        core.decreaseManagerFee(999, 0);

        MockManagerRegistry(registry).setMinManagerFeeBps(0); // the registry lowers its minimum: the fund keeps 1,000
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.ManagerFeeBelowMinimum.selector, 500, 1000));
        core.decreaseManagerFee(500, 0);

        MockManagerRegistry(registry).setMinManagerFeeBps(1000); // and raising it again never forces the fund
        vm.prank(manager);
        core.decreaseManagerFee(1000, 0);
        assertEq(core.performanceFeeBps(), 1000);
        MockManagerRegistry(registry).setMinManagerFeeBps(1500);
        assertEq(core.performanceFeeBps(), 1000, "a live fund is never forced up");
        assertEq(core.minPerformanceFeeBps(), 1000);
    }

    /// @dev With the minimum at its 0 start the manager may go down to 0 (DEC-115: the minimum starts at 0).
    function test_DEC115_zeroMinimumLetsTheFeeReachZero() public {
        (IFundFactory.FundAddresses memory a,,) = _create(100e6, 100e6);
        vm.prank(manager);
        CoreVault(a.coreVault).decreaseManagerFee(0, 0);
        assertEq(CoreVault(a.coreVault).performanceFeeBps(), 0);
    }
}
