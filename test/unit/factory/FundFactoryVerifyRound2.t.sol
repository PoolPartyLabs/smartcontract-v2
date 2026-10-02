// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {Create3} from "../../../src/factory/Create3.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {
    Mandate,
    MandateLib,
    AdapterConfig,
    PoolConfig,
    UnwindStep,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {MockAcrossSpokePool} from "../../mocks/across/MockAcrossSpokePool.sol";
import {MockAaveV3Pool} from "../../mocks/aave/MockAaveV3Pool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {FundMandate} from "../../../script/FundMandate.sol";
import {AnyPriceSource} from "../../mocks/core/AnyPriceSource.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {FundSeed} from "../../utils/FundSeed.sol";

/// @notice Adversarial verification of the factory stage (round 2), after the fund id bound the Manager and
///         `createSpoke` started deriving the id from the Mandate's Hub Chain. Same two-chain fixture as
///         FundFactoryVerify.t.sol.
/// @dev `test_FFOQ1_verify_managerCanCreateTheSpokeFromAMandateOtherThanTheHubs` and
///      `test_DEC087_verify_hubMandateMayNameASpokeThatCanNeverBeCreated` document open limits (FF-OQ-1 residual and a
///      Mandate foot-gun), not fixed behaviour; the other two confirm the round 1 fixes hold from other directions.
contract FundFactoryVerifyRound2Test is Test, FactoryDeployment, FundMandate, FundSeed {
    uint256 internal constant HUB = 42_161;
    uint256 internal constant SPOKE = 4663;

    MockToken internal usdc;
    MockToken internal weth;
    MockToken internal usdg;
    MockToken internal spokeWeth;
    MockAcrossSpokePool internal hubAcross;
    MockAcrossSpokePool internal spokeAcross;
    MockAaveV3Pool internal aave;
    MockWormholeCore internal hubWormhole;
    MockWormholeCore internal spokeWormhole;

    address internal manager = makeAddr("manager");
    address internal attacker = makeAddr("attacker");
    address internal recipient = makeAddr("protocolRecipient");
    address internal guardian = makeAddr("guardian");
    address internal registry = address(new MockManagerRegistry());
    address internal prices = address(new AnyPriceSource());

    uint256 internal cleanState;
    FundFactory internal factory;
    Deployment internal hubDeployment;

    function setUp() public {
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
        cleanState = vm.snapshotState();
        vm.chainId(HUB);
        Deployment memory d;
        d = _deployFactory(_wiring(true), true, d);
        hubDeployment = d;
        factory = d.factory;
        // DEC-127: the manager holds the seed and approved the factory before `createFund`.
        _fundManagerSeed(address(usdc), manager, address(factory), 10_000e6);
    }

    function _wiring(bool hub) internal returns (IFundFactory.ProtocolWiring memory w) {
        w.numberOffset = hub ? 0 : 1_000_000;
        w.baseToken = hub ? address(usdc) : address(usdg);
        w.acrossSpokePool = hub ? address(hubAcross) : address(spokeAcross);
        w.wormholeCore = hub ? address(hubWormhole) : address(spokeWormhole);
        w.uniswapV4PoolManager = makeAddr(hub ? "hubPoolManager" : "spokePoolManager");
        w.uniswapV4PositionManager = makeAddr(hub ? "hubPositionManager" : "spokePositionManager");
        w.uniswapV4StateView = makeAddr(hub ? "hubStateView" : "spokeStateView");
        w.permit2 = makeAddr("permit2");
        w.aaveV3Pool = hub ? address(aave) : address(0);
        w.managerRegistry = hub ? registry : address(0);
        w.priceSource = hub ? prices : address(0);
        w.protocolRecipient = recipient;
        w.guardian = guardian;
        w.flowFeeBps = 25;
    }

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

    function _plan(address manager_) internal view returns (FundPlan memory plan) {
        plan.manager = manager_;
        plan.hubChainId = HUB;
        plan.usdc = address(usdc);
        plan.hubPool = _poolKey(address(weth), address(usdc), 500, 10);
        plan.hubAaveAsset = address(usdc);
        plan.spokeChainId = SPOKE;
        plan.spokeWormholeChainId = 72;
        plan.spokeToken = address(usdg);
        plan.spokePool = _poolKey(address(spokeWeth), address(usdg), 500, 10);
        plan.spokeCap = 1_000_000e6;
        plan.maxReportAge = 1588;
        plan.spokeOperatingCashFloor = 5e6;
        plan.spokeOperatingCashTopUp = 10e6;
        plan.minFirstDeposit = 100e6;
        plan.performanceFeeBps = 2000;
        plan.maxBridgeFeeBps = 50;
    }

    function _createFund(Mandate memory m, uint256 n) internal returns (IFundFactory.FundAddresses memory a) {
        vm.prank(manager);
        a = factory.createFund(m, _hubParams(n, _plan(manager), _coreVaultCreationCode(hubDeployment)));
    }

    /// @dev A Mandate hubbed on SPOKE that names HUB (this hub factory's chain) as its Spoke Chain, every address
    ///      predicted for `fundId`, so `_requirePredictedAddresses` accepts it on the hub factory.
    function _mandateHubbedElsewhere(bytes32 fundId, address manager_) internal view returns (Mandate memory m) {
        address uniswap = factory.addressOf(fundId, "UniswapV4Adapter", HUB);
        bytes32 poolId = PoolId.unwrap(_poolKey(address(weth), address(usdc), 500, 10).toId());
        m.manager = manager_;
        m.hubChainId = SPOKE;
        m.usdc = address(usdg);
        m.adapters = new AdapterConfig[](1);
        m.adapters[0] = AdapterConfig(HUB, uniswap);
        m.pools = new PoolConfig[](1);
        m.pools[0] = PoolConfig(HUB, uniswap, poolId);
        m.unwindOrder = new UnwindStep[](1);
        m.unwindOrder[0] = UnwindStep(HUB, uniswap, poolId);
        m.spokes = new SpokeConfig[](1);
        m.spokes[0] = SpokeConfig(
            HUB, 23, bytes32(uint256(uint160(factory.addressOf(fundId, "SpokeVault", HUB)))), address(usdc), 1e12, 1588
        );
        m.bridgeAdapters = new BridgeAdapterConfig[](2);
        m.bridgeAdapters[0] = BridgeAdapterConfig(HUB, SPOKE, factory.addressOf(fundId, "AcrossBridgeAdapter", SPOKE));
        m.bridgeAdapters[1] = BridgeAdapterConfig(HUB, HUB, factory.addressOf(fundId, "AcrossBridgeAdapter", HUB));
        m.operatingCash = new OperatingCashConfig[](1);
        m.operatingCash[0] = OperatingCashConfig(HUB, 5e6, 10e6);
        m.payoutFeeBps = MandateLib.DEFAULT_PAYOUT_FEE_BPS;
        m.standardPayoutTerm = MandateLib.DEFAULT_STANDARD_PAYOUT_TERM;
        m.minFirstDeposit = 1e6;
    }

    /// @dev FF-OQ-1 residual (OPEN; DEC-030, DEC-053): the fund id binds the Manager but not the Mandate's rules, so
    ///      the Manager can create the spoke at the address the hub's Mandate names from a Mandate with other rules.
    ///      Here the spoke pins a Uniswap V4 pool the hub's Mandate never listed and refuses the hub's pool; nothing on
    ///      chain ties the spoke's `mandateHash()` to the hub's. Documents the limit stated in docs/OPEN-QUESTIONS.md;
    ///      not fixed behaviour.
    function test_FFOQ1_verify_managerCanCreateTheSpokeFromAMandateOtherThanTheHubs() public {
        bytes32 fundId = factory.fundIdOf(HUB, 1, manager);
        Mandate memory hubMandate = _buildMandate(factory, fundId, _plan(manager));
        IFundFactory.FundAddresses memory a = _createFund(hubMandate, 1);
        bytes32 hubHash = CoreVault(a.coreVault).mandateHash();
        address named = address(uint160(uint256(hubMandate.spokes[0].spokeVault)));

        // Same Manager, same number, same hub: same fund id, same addresses; other spoke pool, other rules.
        FundPlan memory otherPlan = _plan(manager);
        otherPlan.spokePool = _poolKey(address(spokeWeth), address(usdg), 3000, 60);
        otherPlan.spokeCap = type(uint256).max;
        otherPlan.maxBridgeFeeBps = 100; // other rules, within the core cap (security review S-9)
        FundFactory spokeFactory = _spokeFactory();
        Mandate memory other = _buildMandate(spokeFactory, fundId, otherPlan);
        assertEq(other.spokes[0].spokeVault, hubMandate.spokes[0].spokeVault, "the hub-named address");
        assertTrue(MandateLib.hash(other) != hubHash);

        vm.prank(manager);
        IFundFactory.ChainAddresses memory c =
            spokeFactory.createSpoke(1, other, _spokeParams(MandateLib.hash(other), otherPlan));
        assertEq(c.spokeVault, named, "created at the address the hub trusts as recipient and emitter");
        _assertSpokeEnforcesOtherRules(SpokeVault(named), c.uniswapV4Adapter, hubHash, otherPlan.spokePool);
    }

    function _assertSpokeEnforcesOtherRules(
        SpokeVault vault,
        address uniswapAdapter,
        bytes32 hubHash,
        PoolKey memory otherPool
    ) internal {
        assertTrue(vault.mandateHash() != hubHash, "the spoke enforces rules the hub's Mandate never showed");
        assertEq(vault.maxBridgeFeeBps(), 100);
        (address token0,) = vault.poolTokens(uniswapAdapter, PoolId.unwrap(otherPool.toId()));
        assertTrue(token0 != address(0), "the unlisted pool is allowed on the spoke");
        bytes32 hubListedPool = PoolId.unwrap(_plan(manager).spokePool.toId());
        vm.expectRevert();
        vault.poolTokens(uniswapAdapter, hubListedPool);
    }

    /// @dev Foot-gun (DEC-087, DEC-028): the hub factory cannot know a Spoke Chain's wiring, so it accepts a Mandate
    ///      listing an Aave adapter on a spoke without Aave. The fund exists on the hub with that spoke as bridge
    ///      recipient, but `createSpoke` there reverts forever, so the named recipient never gets code. Not a factory
    ///      defect (the manager chose the Mandate); recorded so DEPLOYMENT.md can warn about it.
    function test_DEC087_verify_hubMandateMayNameASpokeThatCanNeverBeCreated() public {
        FundPlan memory plan = _plan(manager);
        bytes32 fundId = factory.fundIdOf(HUB, 1, manager);
        Mandate memory m = _buildMandate(factory, fundId, plan);
        address spokeAave = factory.addressOf(fundId, "AaveV3Adapter", SPOKE);
        AdapterConfig[] memory adapters = new AdapterConfig[](m.adapters.length + 1);
        PoolConfig[] memory pools = new PoolConfig[](m.pools.length + 1);
        for (uint256 i; i < m.adapters.length; ++i) {
            adapters[i] = m.adapters[i];
            pools[i] = m.pools[i];
        }
        adapters[m.adapters.length] = AdapterConfig(SPOKE, spokeAave);
        pools[m.pools.length] = PoolConfig(SPOKE, spokeAave, bytes32(uint256(uint160(address(usdg)))));
        m.adapters = adapters;
        m.pools = pools;

        IFundFactory.FundAddresses memory a = _createFund(m, 1);
        assertTrue(factory.isFund(a.coreVault), "the hub accepted the Mandate");
        address named = address(uint160(uint256(m.spokes[0].spokeVault)));

        FundFactory spokeFactory = _spokeFactory();
        bytes memory reason =
            abi.encodeWithSelector(IFundFactory.ProtocolNotOnChain.selector, spokeFactory.ROLE_AAVE_V3_ADAPTER());
        vm.prank(manager);
        vm.expectRevert(reason);
        spokeFactory.createSpoke(1, m, _spokeParams(MandateLib.hash(m), plan));
        assertEq(named.code.length, 0, "the bridge recipient the hub's Mandate names can never exist");
    }

    /// @dev DEC-001, DEC-054, FF-OQ-1 from the other direction: on the hub factory a stranger creates a "spoke" of a
    ///      fund hubbed elsewhere. The salts it consumes are the stranger's own; the Manager's future fund hubbed on
    ///      the other chain (its first number there) keeps every hub-side address free.
    function test_DEC054_verify_strangerCannotPreConsumeTheHubSideSaltsOfAFundHubbedElsewhere() public {
        uint256 n = 1_000_001;
        bytes32 managerFund = factory.fundIdOf(SPOKE, n, manager);
        bytes32 attackerFund = factory.fundIdOf(SPOKE, n, attacker);
        assertTrue(managerFund != attackerFund);

        // The Manager's addresses under the attacker's name: refused (derived id is the attacker's).
        Mandate memory forged = _mandateHubbedElsewhere(managerFund, attacker);
        IFundFactory.SpokeParams memory sp;
        sp.uniswapV4Pools = new PoolKey[](1);
        sp.uniswapV4Pools[0] = _poolKey(address(weth), address(usdc), 500, 10);
        sp.mandateHash = MandateLib.hash(forged);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IFundFactory.UnexpectedAdapter.selector, HUB, forged.adapters[0].adapter)
        );
        factory.createSpoke(n, forged, sp);

        // The Manager's Mandate from the attacker's key: refused.
        Mandate memory real = _mandateHubbedElsewhere(managerFund, manager);
        sp.mandateHash = MandateLib.hash(real);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.NotManager.selector, attacker, manager));
        factory.createSpoke(n, real, sp);

        // The attacker's own fund lands on its own salts.
        Mandate memory own = _mandateHubbedElsewhere(attackerFund, attacker);
        sp.mandateHash = MandateLib.hash(own);
        vm.prank(attacker);
        IFundFactory.ChainAddresses memory c = factory.createSpoke(n, own, sp);
        assertEq(c.spokeVault, factory.addressOf(attackerFund, "SpokeVault", HUB));
        assertEq(factory.addressOf(managerFund, "SpokeVault", HUB).code.length, 0);
        assertEq(factory.addressOf(managerFund, "UniswapV4Adapter", HUB).code.length, 0);
        assertEq(factory.addressOf(managerFund, "AcrossBridgeAdapter", HUB).code.length, 0);

        // The Manager still lands at the predicted hub-side addresses.
        sp = _params(real);
        vm.prank(manager);
        c = factory.createSpoke(n, real, sp);
        assertEq(c.spokeVault, factory.addressOf(managerFund, "SpokeVault", HUB));
        assertEq(SpokeVault(c.spokeVault).manager(), manager);
    }

    function _params(Mandate memory m) internal view returns (IFundFactory.SpokeParams memory sp) {
        sp.uniswapV4Pools = new PoolKey[](1);
        sp.uniswapV4Pools[0] = _poolKey(address(weth), address(usdc), 500, 10);
        sp.mandateHash = MandateLib.hash(m);
    }

    /// @dev DEC-054, DEC-058: the CREATE3 proxy stays callable after the fund contract exists. Anyone calling it with
    ///      creation code deploys at the proxy's next nonce, never at the fund address; the Core Vault's code and the
    ///      factory's registry and counter are untouched, and the next fund still creates.
    function test_DEC058_verify_usedCreate3ProxyCannotTouchTheFundAddress() public {
        bytes32 fundId = factory.fundIdOf(HUB, 1, manager);
        IFundFactory.FundAddresses memory a = _createFund(_buildMandate(factory, fundId, _plan(manager)), 1);
        bytes32 salt = factory.saltOf(fundId, factory.ROLE_CORE_VAULT(), HUB);
        address proxy = vm.computeCreate2Address(salt, Create3.PROXY_INITCODE_HASH, address(factory));
        assertTrue(proxy.code.length != 0, "the proxy persists");
        bytes32 coreCodehash = a.coreVault.codehash;

        // Creation code that returns a one-byte STOP runtime.
        vm.prank(attacker);
        (bool ok,) = proxy.call(hex"60016000f3");
        assertTrue(ok);
        address stray = vm.computeCreateAddress(proxy, 2);
        assertEq(stray.code.length, 1, "deployed at the proxy's next nonce");
        assertEq(a.coreVault.codehash, coreCodehash);
        assertTrue(factory.isFund(a.coreVault));
        assertFalse(factory.isFund(stray));
        assertEq(factory.nextCreationNumber(), 2);

        // A CREATE2 collision on the proxy salt is refused before the attempt, so the salt stays unusable, not
        // redeployable.
        Mandate memory m = _buildMandate(factory, factory.fundIdOf(HUB, 2, manager), _plan(manager));
        IFundFactory.FundAddresses memory b = _createFund(m, 2);
        assertEq(factory.fundByNumber(2), b.coreVault);
    }
}
