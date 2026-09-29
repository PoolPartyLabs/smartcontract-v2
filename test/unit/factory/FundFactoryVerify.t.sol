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
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
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

/// @notice Adversarial verification of the factory stage (round 1). The hub and the spoke factory are two deployments at
///         the same address, one per simulated chain, as in FundFactory.t.sol.
/// @dev Two of these tests demonstrate a live defect rather than a rule; they pass today because they assert what the
///      contract does, and are meant to be inverted once the factory binds `createSpoke` to a fund id it cannot have
///      produced itself (and, for FF-OQ-1, to the manager):
///      - `test_DEC054_verify_createSpokeOnTheHubFactoryBricksEveryFutureFund`: the fund id namespace of a chain is
///        shared between "funds hubbed here" and "funds hubbed elsewhere", so anyone can burn the hub-chain salts of
///        the next real fund with one `createSpoke` and `createFund` reverts forever (the counter never advances);
///      - `test_DEC001_verify_spokeVaultOfARealFundSquattedByAnotherManager`: FF-OQ-1 as recorded, made concrete.
contract FundFactoryVerifyTest is Test, FactoryDeployment, FundMandate {
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
    address internal registry = makeAddr("managerRegistry");
    address internal prices = makeAddr("priceSource");

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
        plan.maxBridgeFeeBps = 50;
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

    /// @dev BLOCKING. `createSpoke` takes any `fundId`, including one this factory would itself derive as a hub
    ///      (`fundIdOf(block.chainid, n)`), and the role salts on a chain are `keccak256(fundId, role, chainId)`
    ///      whoever the hub is. One `createSpoke` on the hub factory for the next fund number therefore consumes the
    ///      hub-chain salts the next `createFund` needs, and `createFund` reverts `SaltAlreadyUsed` for that number
    ///      forever; since the number only advances on success, no fund can ever be created again (DEC-001, DEC-054).
    function test_DEC054_verify_createSpokeOnTheHubFactoryBricksEveryFutureFund() public {
        uint256 n = factory.nextCreationNumber();
        bytes32 fundId = factory.fundIdOf(HUB, n);
        Mandate memory squat = _foreignHubMandate(fundId);
        IFundFactory.SpokeParams memory sp;
        sp.mandateHash = MandateLib.hash(squat);
        sp.uniswapV4Pools = new PoolKey[](1);
        sp.uniswapV4Pools[0] = _poolKey(address(weth), address(usdc));

        // The attacker's spoke lands at the address the real fund's hub Spoke Vault would take.
        vm.prank(attacker);
        IFundFactory.ChainAddresses memory c = factory.createSpoke(fundId, squat, sp);
        assertEq(c.spokeVault, factory.addressOf(fundId, "SpokeVault", HUB));
        assertEq(SpokeVault(c.spokeVault).manager(), attacker);
        assertFalse(SpokeVault(c.spokeVault).onHubChain(), "an Arbitrum vault that thinks Arbitrum is a spoke");
        // The real fund's hub Across adapter address now holds an adapter owned by the attacker's vault.
        assertEq(AcrossBridgeAdapter(c.acrossBridgeAdapter).vault(), c.spokeVault);

        // The real manager can never create fund n: the hub Uniswap adapter salt is gone.
        Mandate memory m = _buildMandate(factory, fundId, _plan(manager));
        IFundFactory.HubParams memory p =
            _hubParams(n, _plan(manager), _coreVaultCreationCode(hubDeployment.coreVaultLogic));
        bytes32 salt = factory.saltOf(fundId, factory.ROLE_UNISWAP_V4_ADAPTER(), HUB);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(Create3.SaltAlreadyUsed.selector, salt));
        factory.createFund(m, p);
        assertEq(factory.nextCreationNumber(), n, "the number never advances: the factory is bricked");
        assertFalse(factory.isFund(factory.addressOf(fundId, "CoreVault", HUB)));
    }

    /// @dev FF-OQ-1 made concrete (DEC-001, DEC-054): the predictions depend on `fundId` only, never on the manager,
    ///      so on the spoke a stranger who names themselves Manager creates the real fund's Spoke Vault first, at the
    ///      exact address the hub's Mandate names as bridge recipient and report emitter, and the real manager is
    ///      locked out with `SpokeAlreadyCreated`. The Mandate is immutable, so the fund has no spoke on that chain.
    function test_DEC001_verify_spokeVaultOfARealFundSquattedByAnotherManager() public {
        Mandate memory m = _buildMandate(factory, factory.fundIdOf(HUB, 1), _plan(manager));
        vm.prank(manager);
        IFundFactory.FundAddresses memory a =
            factory.createFund(m, _hubParams(1, _plan(manager), _coreVaultCreationCode(hubDeployment.coreVaultLogic)));
        bytes32 hubMandateHash = MandateLib.hash(m);

        address hubFactory = address(factory);
        FundFactory spokeFactory = _spokeFactory();
        assertEq(address(spokeFactory), hubFactory, "same factory address on every chain");

        // Same fund id, same predicted addresses, another manager.
        Mandate memory forged = _buildMandate(spokeFactory, a.fundId, _plan(attacker));
        assertEq(forged.spokes[0].spokeVault, m.spokes[0].spokeVault, "the prediction ignores the manager");
        vm.prank(attacker);
        IFundFactory.ChainAddresses memory c =
            spokeFactory.createSpoke(a.fundId, forged, _spokeParams(MandateLib.hash(forged), _plan(attacker)));

        address named = address(uint160(uint256(m.spokes[0].spokeVault)));
        assertEq(c.spokeVault, named, "the hub's bridge recipient and report emitter");
        assertEq(SpokeVault(named).manager(), attacker);
        assertEq(SpokeVault(named).coreVault(), a.coreVault, "it points at the real Core Vault");
        assertTrue(SpokeVault(named).mandateHash() != hubMandateHash);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.SpokeAlreadyCreated.selector, a.fundId, named));
        spokeFactory.createSpoke(a.fundId, m, _spokeParams(hubMandateHash, _plan(manager)));
    }

    /// @dev Checks-effects-interactions across an invalid Mandate: the factory checks predictions before validation,
    ///      and `MandateLib.validate` only runs inside the Spoke Vault constructor after the adapters were deployed.
    ///      The whole creation must still unwind: no adapter code left behind, no number consumed (DEC-053, DEC-058).
    function test_DEC058_verify_invalidMandateLeavesNoPartialDeployment() public {
        bytes32 fundId = factory.fundIdOf(HUB, 1);
        Mandate memory m = _buildMandate(factory, fundId, _plan(manager));
        // An adapter on a chain that is neither the hub nor a spoke, at its predicted address.
        AdapterConfig[] memory adapters = new AdapterConfig[](m.adapters.length + 1);
        for (uint256 i; i < m.adapters.length; ++i) {
            adapters[i] = m.adapters[i];
        }
        adapters[m.adapters.length] = AdapterConfig(999, factory.addressOf(fundId, "UniswapV4Adapter", 999));
        m.adapters = adapters;
        IFundFactory.HubParams memory p =
            _hubParams(1, _plan(manager), _coreVaultCreationCode(hubDeployment.coreVaultLogic));

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
