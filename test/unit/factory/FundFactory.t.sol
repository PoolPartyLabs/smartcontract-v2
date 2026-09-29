// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {Create3} from "../../../src/factory/Create3.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {ManagerFeeVault} from "../../../src/core/ManagerFeeVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {AaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {Mandate, MandateLib, AdapterConfig, PoolConfig} from "../../../src/mandate/Mandate.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {MockAcrossSpokePool} from "../../mocks/across/MockAcrossSpokePool.sol";
import {MockAaveV3Pool} from "../../mocks/aave/MockAaveV3Pool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {FundMandate} from "../../../script/FundMandate.sol";

/// @notice Fund Factory without the network: salt derivation, predictions, hub and spoke creation against mock
///         protocols, and every refusal. The hub and the spoke factory are two deployments at the same address, one per
///         simulated chain (state reverted in between), as on mainnet.
contract FundFactoryTest is Test, FactoryDeployment, FundMandate {
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
        factory = _hubFactory();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fixture
    // ---------------------------------------------------------------------------------------------------------------

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

    function _hubFactory() internal returns (FundFactory) {
        vm.chainId(HUB);
        Deployment memory d;
        d = _deployFactory(_wiring(true), true, d);
        hubDeployment = d;
        return d.factory;
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

    function _plan() internal view returns (FundPlan memory plan) {
        plan.manager = manager;
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

    function _mandate(uint256 creationNumber) internal view returns (Mandate memory) {
        return _buildMandate(factory, factory.fundIdOf(HUB, creationNumber, manager), _plan());
    }

    function _params(uint256 creationNumber) internal view returns (IFundFactory.HubParams memory) {
        return _hubParams(creationNumber, _plan(), _coreVaultCreationCode(hubDeployment.coreVaultLogic));
    }

    function _createFund() internal returns (IFundFactory.FundAddresses memory a, Mandate memory m) {
        m = _mandate(1);
        vm.prank(manager);
        a = factory.createFund(m, _params(1));
    }

    function _chainIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = HUB;
        ids[1] = SPOKE;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Salts, numbers and predictions
    // ---------------------------------------------------------------------------------------------------------------

    function test_Q59_fundIdAndSaltDerivation() public view {
        bytes32 fundId = factory.fundIdOf(HUB, 7, manager);
        assertEq(fundId, keccak256(abi.encode(HUB, address(factory), uint256(7), manager)));
        bytes32 role = factory.ROLE_SPOKE_VAULT();
        assertEq(role, bytes32("SpokeVault"));
        assertEq(factory.saltOf(fundId, role, SPOKE), keccak256(abi.encode(fundId, role, SPOKE)));
        // The address depends on (factory, salt) only.
        address proxy = vm.computeCreate2Address(
            factory.saltOf(fundId, role, SPOKE), Create3.PROXY_INITCODE_HASH, address(factory)
        );
        assertEq(factory.addressOf(fundId, role, SPOKE), vm.computeCreateAddress(proxy, 1));
    }

    function testFuzz_Q59_saltsAreDistinctPerRoleChainAndFund(uint256 n, uint256 chainA, uint256 chainB) public view {
        vm.assume(chainA != chainB);
        bytes32 fundId = factory.fundIdOf(HUB, n, manager);
        assertTrue(fundId != factory.fundIdOf(HUB, n ^ 1, manager));
        assertTrue(fundId != factory.fundIdOf(SPOKE, n, manager));
        // DEC-001, FF-OQ-1: another manager, another fund id, other addresses.
        assertTrue(fundId != factory.fundIdOf(HUB, n, address(0xB0B)));
        bytes32 role = factory.ROLE_UNISWAP_V4_ADAPTER();
        assertTrue(factory.addressOf(fundId, role, chainA) != factory.addressOf(fundId, role, chainB));
        assertTrue(
            factory.addressOf(fundId, role, chainA) != factory.addressOf(fundId, factory.ROLE_AAVE_V3_ADAPTER(), chainA)
        );
    }

    function test_Q59_numbersStartAfterTheOffset() public {
        assertEq(factory.NUMBER_OFFSET(), 0);
        assertEq(factory.nextCreationNumber(), 1);
        FundFactory spokeFactory = _spokeFactory();
        assertEq(spokeFactory.NUMBER_OFFSET(), 1_000_000);
        assertEq(spokeFactory.nextCreationNumber(), 1_000_001);
    }

    function test_DEC054_predictAddressesMatchesAddressOf() public view {
        IFundFactory.FundAddresses memory a = factory.predictAddresses(3, manager, _chainIds());
        bytes32 fundId = factory.fundIdOf(HUB, 3, manager);
        assertEq(a.creationNumber, 3);
        assertEq(a.fundId, fundId);
        assertEq(a.coreVault, factory.addressOf(fundId, factory.ROLE_CORE_VAULT(), HUB));
        assertEq(a.valueReportReceiver, factory.addressOf(fundId, factory.ROLE_VALUE_REPORT_RECEIVER(), HUB));
        assertEq(a.shareToken, vm.computeCreateAddress(a.coreVault, 1));
        assertEq(a.managerFeeVault, vm.computeCreateAddress(a.coreVault, 2));
        assertEq(a.chains.length, 2);
        assertEq(a.chains[1].chainId, SPOKE);
        assertEq(a.chains[1].spokeVault, factory.addressOf(fundId, factory.ROLE_SPOKE_VAULT(), SPOKE));
        assertEq(a.chains[1].uniswapV4Adapter, factory.addressOf(fundId, factory.ROLE_UNISWAP_V4_ADAPTER(), SPOKE));
        assertEq(a.chains[1].aaveV3Adapter, factory.addressOf(fundId, factory.ROLE_AAVE_V3_ADAPTER(), SPOKE));
        assertEq(
            a.chains[1].acrossBridgeAdapter, factory.addressOf(fundId, factory.ROLE_ACROSS_BRIDGE_ADAPTER(), SPOKE)
        );
    }

    function test_DEC058_constructorRecordsWiringAndCodeHashes() public view {
        IFundFactory.ProtocolWiring memory w = factory.wiring();
        assertEq(w.baseToken, address(usdc));
        assertEq(w.aaveV3Pool, address(aave));
        assertEq(w.coreVaultLogic, hubDeployment.coreVaultLogic);
        assertEq(w.spokeCrossChainLib, hubDeployment.spokeCrossChainLib);
        assertEq(w.coreVaultCreationCodeHash, keccak256(_coreVaultCreationCode(hubDeployment.coreVaultLogic)));
        assertEq(factory.creationCodeHash(factory.ROLE_CORE_VAULT()), w.coreVaultCreationCodeHash);
        assertEq(
            factory.creationCodeHash(factory.ROLE_SPOKE_VAULT()),
            keccak256(_spokeVaultCreationCode(hubDeployment.spokeCrossChainLib))
        );
        assertEq(
            factory.creationCodeHash(factory.ROLE_UNISWAP_V4_ADAPTER()),
            keccak256(vm.getCode("UniswapV4Adapter.sol:UniswapV4Adapter"))
        );
        assertTrue(factory.transitEscrowImplementation().code.length != 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // createFund
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC054_createFundDeploysEveryPredictedContractWired() public {
        IFundFactory.FundAddresses memory predicted = factory.predictAddresses(1, manager, _chainIds());
        (IFundFactory.FundAddresses memory a, Mandate memory m) = _createFund();
        IFundFactory.ChainAddresses memory hub = a.chains[0];

        assertEq(a.coreVault, predicted.coreVault);
        assertEq(a.shareToken, predicted.shareToken);
        assertEq(a.managerFeeVault, predicted.managerFeeVault);
        assertEq(a.valueReportReceiver, predicted.valueReportReceiver);
        assertEq(hub.spokeVault, predicted.chains[0].spokeVault);
        assertEq(hub.uniswapV4Adapter, predicted.chains[0].uniswapV4Adapter);
        assertEq(hub.aaveV3Adapter, predicted.chains[0].aaveV3Adapter);
        assertEq(hub.acrossBridgeAdapter, predicted.chains[0].acrossBridgeAdapter);

        CoreVault core = CoreVault(a.coreVault);
        assertEq(core.fundId(), a.fundId);
        assertEq(core.mandateHash(), MandateLib.hash(m));
        assertEq(core.manager(), manager);
        assertEq(core.hubSpokeVault(), hub.spokeVault);
        assertEq(core.reportReceiver(), a.valueReportReceiver);
        assertEq(core.shareToken(), a.shareToken);
        assertEq(core.managerFeeVault(), a.managerFeeVault);
        assertEq(core.protocolRecipient(), recipient);
        assertEq(core.excessRecipient(), recipient, "DEC-101: sweeps to the fee wallet");
        assertEq(core.flowFeeBps(), 25);
        assertEq(core.escrowImplementation(), factory.transitEscrowImplementation());
        address[] memory incomeTokens = core.incomeTokens();
        assertEq(incomeTokens.length, 2, "CV-OQ-3: USDC then WETH from the hub pools");
        assertEq(incomeTokens[0], address(usdc));
        assertEq(incomeTokens[1], address(weth));

        assertEq(ShareToken(a.shareToken).symbol(), "PP-1");
        assertEq(ShareToken(a.shareToken).name(), "Pool Party Fund 1");
        assertEq(ManagerFeeVault(a.managerFeeVault).fund(), a.coreVault);

        SpokeVault hubVault = SpokeVault(hub.spokeVault);
        assertTrue(hubVault.onHubChain());
        assertEq(hubVault.coreVault(), a.coreVault);
        assertEq(hubVault.fundId(), a.fundId);
        assertEq(hubVault.mandateHash(), MandateLib.hash(m));
        assertEq(hubVault.excessRecipient(), recipient);

        assertEq(UniswapV4Adapter(hub.uniswapV4Adapter).vault(), hub.spokeVault);
        assertEq(UniswapV4Adapter(hub.uniswapV4Adapter).guardian(), guardian);
        assertEq(AaveV3Adapter(hub.aaveV3Adapter).vault(), hub.spokeVault);
        assertEq(AcrossBridgeAdapter(hub.acrossBridgeAdapter).vault(), a.coreVault, "DEC-087: the Core Vault sends");
        assertEq(AcrossBridgeAdapter(hub.acrossBridgeAdapter).spokePool(), address(hubAcross));

        ValueReportReceiver receiver = ValueReportReceiver(a.valueReportReceiver);
        assertEq(receiver.coreVault(), a.coreVault);
        assertEq(receiver.fundId(), a.fundId);
        assertEq(receiver.coreBridge(), address(hubWormhole));
        assertEq(receiver.variationBandBps(), 0, "Q57 (d): disabled");

        assertTrue(factory.isFund(a.coreVault));
        assertFalse(factory.isFund(hub.spokeVault));
        assertEq(factory.fundByNumber(1), a.coreVault);
        assertEq(factory.nextCreationNumber(), 2);
    }

    function test_DEC054_createFundEmitsFundCreated() public {
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        vm.expectEmit(true, true, true, false, address(factory));
        emit IFundFactory.FundCreated(
            1,
            factory.fundIdOf(HUB, 1, manager),
            manager,
            MandateLib.hash(m),
            factory.predictAddresses(1, manager, _chainIds())
        );
        vm.prank(manager);
        factory.createFund(m, p);
    }

    function test_Q59_secondFundGetsTheNextNumber() public {
        _createFund();
        Mandate memory m = _mandate(2);
        vm.prank(manager);
        IFundFactory.FundAddresses memory a = factory.createFund(m, _params(2));
        assertEq(ShareToken(a.shareToken).symbol(), "PP-2");
        assertEq(factory.fundByNumber(2), a.coreVault);
    }

    function test_DEC001_createFundOnlyByTheMandateManager() public {
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.NotManager.selector, stranger, manager));
        factory.createFund(m, p);
    }

    function test_Q59_staleCreationNumberReverts() public {
        _createFund();
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.CreationNumberTaken.selector, 1, 2));
        factory.createFund(m, p);
    }

    function test_DEC058_foreignCoreVaultCreationCodeReverts() public {
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        // Same contract linked to another library address: foreign code under this fund id.
        p.coreVaultCreationCode = _coreVaultCreationCode(address(0xBEEF));
        bytes32 role = factory.ROLE_CORE_VAULT();
        bytes memory reason = abi.encodeWithSelector(
            IFundFactory.ForeignCreationCode.selector,
            role,
            keccak256(p.coreVaultCreationCode),
            factory.creationCodeHash(role)
        );
        vm.prank(manager);
        vm.expectRevert(reason);
        factory.createFund(m, p);
    }

    function test_DEC054_mandateSpokeEntryNotPredictedReverts() public {
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        bytes32 predicted = m.spokes[0].spokeVault;
        bytes32 foreign = bytes32(uint256(uint160(makeAddr("foreignSpokeVault"))));
        m.spokes[0].spokeVault = foreign;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.SpokeVaultMismatch.selector, SPOKE, predicted, foreign));
        factory.createFund(m, p);
    }

    function test_DEC053_mandateAdapterNotPredictedReverts() public {
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        address foreign = makeAddr("foreignAdapter");
        m.adapters[0].adapter = foreign;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.UnexpectedAdapter.selector, HUB, foreign));
        factory.createFund(m, p);
    }

    function test_DEC087_mandateBridgeAdapterNotPredictedReverts() public {
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        address foreign = makeAddr("foreignBridge");
        m.bridgeAdapters[1].adapter = foreign;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.UnexpectedBridgeAdapter.selector, SPOKE, foreign));
        factory.createFund(m, p);
    }

    function test_DEC030_poolKeyMustHashToTheMandatePool() public {
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        p.uniswapV4Pools[0].fee = 3000;
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFundFactory.PoolKeyMismatch.selector, 0, m.pools[0].poolKey, keccak256(abi.encode(p.uniswapV4Pools[0]))
            )
        );
        factory.createFund(m, p);
    }

    function test_DEC030_poolKeyCountMustMatchTheMandate() public {
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        p.uniswapV4Pools = new PoolKey[](2);
        p.uniswapV4Pools[0] = _plan().hubPool;
        p.uniswapV4Pools[1] = _plan().hubPool;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.PoolKeyCountMismatch.selector, 1, 2));
        factory.createFund(m, p);
    }

    function test_DEC011_createFundOnlyOnTheHubChain() public {
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        vm.chainId(SPOKE);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.NotHubChain.selector, SPOKE, HUB));
        factory.createFund(m, p);
    }

    function test_DEC011_mandateUsdcMustBeTheChainBaseToken() public {
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        m.usdc = address(usdg);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.BaseTokenMismatch.selector, address(usdg), address(usdc)));
        factory.createFund(m, p);
    }

    /// @dev DEC-066, Across verifier finding: a SpokePool whose fill deadline buffer is below 6 h fails the creation
    ///      with the adapter's own reason.
    function test_DEC066_shortFillDeadlineBufferSurfacesAtCreation() public {
        hubAcross.setFillDeadlineBuffer(3600);
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(AcrossBridgeAdapter.FillDeadlineBufferTooShort.selector, 3600));
        factory.createFund(m, p);
    }

    /// @dev OQ-08 stance: hub-only funds are accepted; no bridge adapter and no receiver spoke.
    function test_OQ08_hubOnlyFund() public {
        FundPlan memory plan = _plan();
        plan.spokeChainId = 0;
        plan.hubAaveAsset = address(0);
        Mandate memory m = _buildMandate(factory, factory.fundIdOf(HUB, 1, manager), plan);
        IFundFactory.HubParams memory p = _hubParams(1, plan, _coreVaultCreationCode(hubDeployment.coreVaultLogic));
        vm.prank(manager);
        IFundFactory.FundAddresses memory a = factory.createFund(m, p);
        assertEq(a.chains[0].acrossBridgeAdapter, address(0));
        assertEq(a.chains[0].aaveV3Adapter, address(0));
        assertTrue(a.chains[0].uniswapV4Adapter.code.length != 0);
        assertTrue(a.coreVault.code.length != 0);
    }

    function test_DEC054_spokeFactoryHasNoHubRole() public {
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        FundFactory spokeFactory = _spokeFactory();
        vm.chainId(HUB);
        vm.prank(manager);
        vm.expectRevert(IFundFactory.HubNotConfigured.selector);
        spokeFactory.createFund(m, p);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // createSpoke
    // ---------------------------------------------------------------------------------------------------------------

    function _createFundThenSpokeFactory()
        internal
        returns (IFundFactory.FundAddresses memory a, Mandate memory m, FundFactory spokeFactory)
    {
        (a, m) = _createFund();
        address hubFactory = address(factory);
        spokeFactory = _spokeFactory();
        assertEq(address(spokeFactory), hubFactory, "same factory address on every chain");
    }

    function test_DEC054_createSpokeAtThePredictedAddress() public {
        (IFundFactory.FundAddresses memory a, Mandate memory m, FundFactory spokeFactory) =
            _createFundThenSpokeFactory();
        bytes32 mandateHash = MandateLib.hash(m);
        vm.prank(manager);
        IFundFactory.ChainAddresses memory c =
            spokeFactory.createSpoke(a.creationNumber, m, _spokeParams(mandateHash, _plan()));

        assertEq(bytes32(uint256(uint160(c.spokeVault))), m.spokes[0].spokeVault);
        assertEq(c.uniswapV4Adapter, m.adapters[2].adapter);
        assertEq(c.acrossBridgeAdapter, m.bridgeAdapters[1].adapter);
        assertEq(c.aaveV3Adapter, address(0));

        SpokeVault vault = SpokeVault(c.spokeVault);
        assertFalse(vault.onHubChain());
        assertEq(vault.coreVault(), a.coreVault, "the hub's Core Vault, predicted on the spoke");
        assertEq(vault.fundId(), a.fundId);
        assertEq(vault.mandateHash(), mandateHash);
        assertEq(vault.baseToken(), address(usdg));
        assertEq(vault.wormholeCore(), address(spokeWormhole));
        assertEq(vault.maxReportAge(), 1588);
        assertEq(UniswapV4Adapter(c.uniswapV4Adapter).vault(), c.spokeVault);
        assertEq(AcrossBridgeAdapter(c.acrossBridgeAdapter).vault(), c.spokeVault);
        assertEq(AcrossBridgeAdapter(c.acrossBridgeAdapter).spokePool(), address(spokeAcross));
    }

    function test_DEC054_createSpokeRejectsAMandateHashOtherThanTheHubs() public {
        (IFundFactory.FundAddresses memory a, Mandate memory m, FundFactory spokeFactory) =
            _createFundThenSpokeFactory();
        bytes32 hubHash = MandateLib.hash(m);
        m.performanceFeeBps = 2500;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.MandateHashMismatch.selector, MandateLib.hash(m), hubHash));
        spokeFactory.createSpoke(a.creationNumber, m, _spokeParams(hubHash, _plan()));
    }

    function test_DEC054_createSpokeRejectsASpokeEntryOtherThanThePrediction() public {
        (IFundFactory.FundAddresses memory a, Mandate memory m, FundFactory spokeFactory) =
            _createFundThenSpokeFactory();
        bytes32 predicted = m.spokes[0].spokeVault;
        bytes32 foreign = bytes32(uint256(uint160(makeAddr("foreignSpokeVault"))));
        m.spokes[0].spokeVault = foreign;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.SpokeVaultMismatch.selector, SPOKE, predicted, foreign));
        spokeFactory.createSpoke(a.creationNumber, m, _spokeParams(MandateLib.hash(m), _plan()));
    }

    function test_DEC001_createSpokeOnlyByTheMandateManager() public {
        (IFundFactory.FundAddresses memory a, Mandate memory m, FundFactory spokeFactory) =
            _createFundThenSpokeFactory();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.NotManager.selector, stranger, manager));
        spokeFactory.createSpoke(a.creationNumber, m, _spokeParams(MandateLib.hash(m), _plan()));
    }

    function test_DEC054_createSpokeOnlyOnce() public {
        (IFundFactory.FundAddresses memory a, Mandate memory m, FundFactory spokeFactory) =
            _createFundThenSpokeFactory();
        IFundFactory.SpokeParams memory p = _spokeParams(MandateLib.hash(m), _plan());
        vm.prank(manager);
        IFundFactory.ChainAddresses memory c = spokeFactory.createSpoke(a.creationNumber, m, p);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.SpokeAlreadyCreated.selector, a.fundId, c.spokeVault));
        spokeFactory.createSpoke(a.creationNumber, m, p);
    }

    function test_DEC054_createSpokeRejectsACreationNumberTheMandateWasNotBuiltFor() public {
        (IFundFactory.FundAddresses memory a, Mandate memory m, FundFactory spokeFactory) =
            _createFundThenSpokeFactory();
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IFundFactory.UnexpectedAdapter.selector, HUB, a.chains[0].uniswapV4Adapter)
        );
        spokeFactory.createSpoke(a.creationNumber + 1, m, _spokeParams(MandateLib.hash(m), _plan()));
    }

    function test_DEC054_createSpokeOnAChainTheMandateDoesNotList() public {
        (IFundFactory.FundAddresses memory a, Mandate memory m, FundFactory spokeFactory) =
            _createFundThenSpokeFactory();
        vm.chainId(999);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.UnknownSpokeChain.selector, 999));
        spokeFactory.createSpoke(a.creationNumber, m, _spokeParams(MandateLib.hash(m), _plan()));
    }

    /// @dev DEC-011, DEC-054, verifier finding (blocking): the hub's own Spoke Vault is `createFund`'s; `createSpoke`
    ///      on the Mandate's Hub Chain reverts before any deployment, so the fund ids this factory derives for
    ///      `createFund` are unreachable through `createSpoke`.
    function test_DEC054_createSpokeOnTheHubChainReverts() public {
        uint256 n = factory.nextCreationNumber();
        Mandate memory m = _mandate(n);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.SpokeOnHubChain.selector, HUB));
        factory.createSpoke(n, m, _spokeParams(MandateLib.hash(m), _plan()));
        // Nothing was consumed: fund n is still created.
        vm.prank(manager);
        IFundFactory.FundAddresses memory a = factory.createFund(m, _params(n));
        assertEq(factory.fundByNumber(n), a.coreVault);
    }

    function test_DEC028_aaveAdapterOnAChainWithoutAaveReverts() public {
        FundFactory spokeFactory = _spokeFactory();
        factory = spokeFactory;
        bytes32 fundId = spokeFactory.fundIdOf(HUB, 1, manager);
        Mandate memory m = _buildMandate(spokeFactory, fundId, _plan());
        // Add an Aave adapter and pool on the spoke.
        address spokeAave = spokeFactory.addressOf(fundId, spokeFactory.ROLE_AAVE_V3_ADAPTER(), SPOKE);
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
        bytes memory reason =
            abi.encodeWithSelector(IFundFactory.ProtocolNotOnChain.selector, spokeFactory.ROLE_AAVE_V3_ADAPTER());
        vm.prank(manager);
        vm.expectRevert(reason);
        spokeFactory.createSpoke(1, m, _spokeParams(MandateLib.hash(m), _plan()));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------------------------

    function _stores() internal returns (IFundFactory.CreationCodeStores memory) {
        return _writeCodeStores(false, hubDeployment.spokeCrossChainLib);
    }

    function test_DEC022_constructorRejectsZeroWiring() public {
        IFundFactory.ProtocolWiring memory w = _wiring(true);
        w.spokeCrossChainLib = hubDeployment.spokeCrossChainLib;
        IFundFactory.CreationCodeStores memory s = _stores();
        w.guardian = address(0);
        vm.expectRevert(IFundFactory.ZeroAddress.selector);
        new FundFactory(w, s);
    }

    function test_DEC110_constructorRejectsAFlowFeeAboveTheCap() public {
        IFundFactory.ProtocolWiring memory w = _wiring(true);
        w.spokeCrossChainLib = hubDeployment.spokeCrossChainLib;
        IFundFactory.CreationCodeStores memory s = _stores();
        w.flowFeeBps = 101;
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.FlowFeeAboveCap.selector, 101));
        new FundFactory(w, s);
    }

    function test_DEC058_constructorRejectsALibraryWithoutCode() public {
        IFundFactory.ProtocolWiring memory w = _wiring(true);
        IFundFactory.CreationCodeStores memory s = _stores();
        w.spokeCrossChainLib = makeAddr("noCode");
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.LibraryHasNoCode.selector, w.spokeCrossChainLib));
        new FundFactory(w, s);
    }

    function test_DEC054_roleWithoutStoredCodeReverts() public {
        IFundFactory.ProtocolWiring memory w = _wiring(true);
        w.spokeCrossChainLib = hubDeployment.spokeCrossChainLib;
        w.coreVaultLogic = hubDeployment.coreVaultLogic;
        w.coreVaultCreationCodeHash = keccak256(_coreVaultCreationCode(hubDeployment.coreVaultLogic));
        // No Aave or receiver code stored: a hub fund cannot be created.
        FundFactory incomplete = new FundFactory(w, _stores());
        factory = incomplete;
        Mandate memory m = _mandate(1);
        IFundFactory.HubParams memory p = _params(1);
        bytes memory reason =
            abi.encodeWithSelector(IFundFactory.RoleNotConfigured.selector, incomplete.ROLE_AAVE_V3_ADAPTER());
        vm.prank(manager);
        vm.expectRevert(reason);
        incomplete.createFund(m, p);
    }
}
