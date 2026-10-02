// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {
    Mandate,
    MandateLib,
    AdapterConfig,
    PoolConfig,
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

/// @notice Adversarial verification of the factory stage (round 1). The hub and the spoke factory are two deployments at
///         the same address, one per simulated chain, as in FundFactory.t.sol.
/// @dev `test_DEC054_verify_createSpokeCannotConsumeTheHubSaltsOfAFutureFund` is the inverted form of a verifier
///      finding (fixed): `createSpoke` derives the fund id from the Mandate's Hub Chain, never this chain.
///      `test_DEC001_verify_anotherManagerCannotSquatTheSpokeVaultOfARealFund` is the inverted form of FF-OQ-1 (fixed):
///      the fund id binds the Manager.
contract FundFactoryVerifyTest is Test, FactoryDeployment, FundMandate, FundSeed {
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

    function _poolKey(address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 500, 10, IHooks(address(0)));
    }

    function _plan(address manager_) internal view returns (FundPlan memory plan) {
        plan.manager = manager_;
        plan.hubChainId = HUB;
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
    }

    /// @dev A Mandate that names Arbitrum (this hub factory's chain) as a Spoke Chain of a fund hubbed elsewhere,
    ///      with every address predicted for `fundId`, so `_requirePredictedAddresses` accepts it.
    function _foreignHubMandate(bytes32 fundId) internal view returns (Mandate memory m) {
        address uniswap = factory.addressOf(fundId, "UniswapV4Adapter", HUB);
        bytes32 poolId = PoolId.unwrap(_poolKey(address(weth), address(usdc)).toId());
        m.manager = attacker;
        m.hubChainId = SPOKE;
        m.usdc = address(usdg);
        m.adapters = new AdapterConfig[](1);
        m.adapters[0] = AdapterConfig(HUB, uniswap);
        m.pools = new PoolConfig[](1);
        m.pools[0] = PoolConfig(HUB, uniswap, poolId);
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
        m.minFirstDeposit = 1e6;
    }

    /// @dev Verifier finding (blocking), fixed. Before the fix `createSpoke` took any `fundId`, including one this
    ///      factory derives for its own next `createFund`, and one call consumed the hub-chain salts of that fund, so
    ///      `createFund` reverted `SaltAlreadyUsed` forever. Now the fund id is derived from `m.hubChainId`, which
    ///      must not be this chain, so no `createSpoke` reaches a hub fund id of this factory (DEC-001, DEC-011,
    ///      DEC-054).
    function test_DEC054_verify_createSpokeCannotConsumeTheHubSaltsOfAFutureFund() public {
        uint256 n = factory.nextCreationNumber();
        bytes32 fundId = factory.fundIdOf(HUB, n, manager);
        Mandate memory squat = _foreignHubMandate(fundId);
        IFundFactory.SpokeParams memory sp;
        sp.uniswapV4Pools = new PoolKey[](1);
        sp.uniswapV4Pools[0] = _poolKey(address(weth), address(usdc));

        // 1. Naming this chain as the hub: refused before any deployment.
        Mandate memory selfHub = _foreignHubMandate(fundId);
        selfHub.hubChainId = HUB;
        sp.mandateHash = MandateLib.hash(selfHub);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.SpokeOnHubChain.selector, HUB));
        factory.createSpoke(n, selfHub, sp);

        // 2. Another hub with this factory's hub addresses: the derived fund id is another one, the addresses differ.
        sp.mandateHash = MandateLib.hash(squat);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.UnexpectedAdapter.selector, HUB, squat.adapters[0].adapter));
        factory.createSpoke(n, squat, sp);

        // 3. A consistent fund hubbed elsewhere lands on its own salts, disjoint from the hub fund's.
        bytes32 foreignFund = factory.fundIdOf(SPOKE, n, attacker);
        Mandate memory foreign = _foreignHubMandate(foreignFund);
        sp.mandateHash = MandateLib.hash(foreign);
        vm.prank(attacker);
        IFundFactory.ChainAddresses memory c = factory.createSpoke(n, foreign, sp);
        assertEq(c.spokeVault, factory.addressOf(foreignFund, "SpokeVault", HUB));
        assertTrue(c.spokeVault != factory.addressOf(fundId, "SpokeVault", HUB));

        // The real manager still creates fund n and the number advances.
        Mandate memory m = _buildMandate(factory, fundId, _plan(manager));
        IFundFactory.HubParams memory p = _hubParams(n, _plan(manager), _coreVaultCreationCode(hubDeployment));
        vm.prank(manager);
        IFundFactory.FundAddresses memory a = factory.createFund(m, p);
        assertEq(a.chains[0].spokeVault, factory.addressOf(fundId, "SpokeVault", HUB));
        assertEq(factory.nextCreationNumber(), n + 1);
        assertTrue(factory.isFund(a.coreVault));
    }

    /// @dev Verifier finding (major), fixed: FF-OQ-1 closed on chain. Before the fix the predictions ignored the
    ///      manager, so a stranger naming themselves Manager created the real fund's Spoke Vault first, at the address
    ///      the hub's Mandate names as bridge recipient (DEC-087) and report emitter (DEC-086). Now the fund id binds
    ///      the Manager (DEC-001, Q59 stance): the stranger's Mandate derives another fund id and other addresses, the
    ///      real Mandate needs the real Manager's key, and the real manager creates the spoke at the named address.
    function test_DEC001_verify_anotherManagerCannotSquatTheSpokeVaultOfARealFund() public {
        Mandate memory m = _buildMandate(factory, factory.fundIdOf(HUB, 1, manager), _plan(manager));
        vm.prank(manager);
        IFundFactory.FundAddresses memory a =
            factory.createFund(m, _hubParams(1, _plan(manager), _coreVaultCreationCode(hubDeployment)));
        bytes32 hubMandateHash = MandateLib.hash(m);
        address named = address(uint160(uint256(m.spokes[0].spokeVault)));

        address hubFactory = address(factory);
        FundFactory spokeFactory = _spokeFactory();
        assertEq(address(spokeFactory), hubFactory, "same factory address on every chain");

        // The real fund's addresses under another manager: refused, the derived fund id is the attacker's.
        Mandate memory forged = _buildMandate(spokeFactory, a.fundId, _plan(attacker));
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IFundFactory.UnexpectedAdapter.selector, HUB, a.chains[0].uniswapV4Adapter)
        );
        spokeFactory.createSpoke(a.creationNumber, forged, _spokeParams(MandateLib.hash(forged), _plan(attacker)));

        // The real Mandate from another key: refused.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.NotManager.selector, attacker, manager));
        spokeFactory.createSpoke(a.creationNumber, m, _spokeParams(hubMandateHash, _plan(manager)));

        // The attacker's own fund id for the same number: its own addresses, never the named one.
        bytes32 attackerFund = spokeFactory.fundIdOf(HUB, a.creationNumber, attacker);
        Mandate memory own = _buildMandate(spokeFactory, attackerFund, _plan(attacker));
        vm.prank(attacker);
        IFundFactory.ChainAddresses memory c =
            spokeFactory.createSpoke(a.creationNumber, own, _spokeParams(MandateLib.hash(own), _plan(attacker)));
        assertTrue(c.spokeVault != named);
        assertEq(named.code.length, 0);

        // The real manager creates the spoke at the address the hub's Mandate names.
        vm.prank(manager);
        c = spokeFactory.createSpoke(a.creationNumber, m, _spokeParams(hubMandateHash, _plan(manager)));
        assertEq(c.spokeVault, named);
        assertEq(SpokeVault(named).manager(), manager);
        assertEq(SpokeVault(named).coreVault(), a.coreVault);
        assertEq(SpokeVault(named).mandateHash(), hubMandateHash);
    }

    /// @dev Checks-effects-interactions across an invalid Mandate: the factory checks predictions before validation,
    ///      and `MandateLib.validate` only runs inside the Spoke Vault constructor after the adapters were deployed.
    ///      The whole creation must still unwind: no adapter code left behind, no number consumed (DEC-053, DEC-058).
    function test_DEC058_verify_invalidMandateLeavesNoPartialDeployment() public {
        bytes32 fundId = factory.fundIdOf(HUB, 1, manager);
        Mandate memory m = _buildMandate(factory, fundId, _plan(manager));
        // An adapter on a chain that is neither the hub nor a spoke, at its predicted address.
        AdapterConfig[] memory adapters = new AdapterConfig[](m.adapters.length + 1);
        for (uint256 i; i < m.adapters.length; ++i) {
            adapters[i] = m.adapters[i];
        }
        adapters[m.adapters.length] = AdapterConfig(999, factory.addressOf(fundId, "UniswapV4Adapter", 999));
        m.adapters = adapters;
        IFundFactory.HubParams memory p = _hubParams(1, _plan(manager), _coreVaultCreationCode(hubDeployment));

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.UnknownChain.selector, 999));
        factory.createFund(m, p);

        assertEq(factory.nextCreationNumber(), 1);
        assertFalse(factory.isFund(factory.addressOf(fundId, "CoreVault", HUB)));
        assertEq(factory.addressOf(fundId, "UniswapV4Adapter", HUB).code.length, 0, "no adapter left behind");
        assertEq(factory.addressOf(fundId, "AaveV3Adapter", HUB).code.length, 0);
        assertEq(factory.addressOf(fundId, "AcrossBridgeAdapter", HUB).code.length, 0);
        // The salts are free again: the corrected Mandate creates the fund.
        Mandate memory good = _buildMandate(factory, fundId, _plan(manager));
        vm.prank(manager);
        IFundFactory.FundAddresses memory a = factory.createFund(good, p);
        assertTrue(factory.isFund(a.coreVault));
    }
}
