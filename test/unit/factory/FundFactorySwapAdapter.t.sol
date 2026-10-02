// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {MockAcrossSpokePool} from "../../mocks/across/MockAcrossSpokePool.sol";
import {MockAaveV3Pool} from "../../mocks/aave/MockAaveV3Pool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {MockV3Factory, MockMiswiredPeriphery} from "../../mocks/swap/MockV3.sol";
import {AnyPriceSource} from "../../mocks/core/AnyPriceSource.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {FundMandate} from "../../../script/FundMandate.sol";
import {FundSeed} from "../../utils/FundSeed.sol";
import {V3Stub} from "../../utils/V3Stub.sol";

/// @notice WP-07 B2 and B4 (DEC-136 and its closing note, DEC-153; reading D-01): the factory deploys one
///         `UniswapV3SwapAdapter` per fund chain at its predicted CREATE3 address, wired to that chain's Spoke Vault,
///         base token, Mandate tokens, Uniswap V3 deployment and API key, before the Spoke Vault, which pins it with
///         its codehash. The Across adapters take no API key (DEC-176).
contract FundFactorySwapAdapterTest is Test, FactoryDeployment, FundMandate, FundSeed {
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
    address internal apiSigner = makeAddr("pool-party-api");
    address internal registry = address(new MockManagerRegistry());
    address internal prices = address(new AnyPriceSource());

    uint256 internal cleanState;
    FundFactory internal factory;
    Deployment internal hubDeployment;
    IFundFactory.ProtocolWiring internal hubWiring;

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
        spokeWormhole.setChainId(72);
        cleanState = vm.snapshotState();
        vm.chainId(HUB);
        hubWiring = _wiring(true);
        factory = _factory(hubWiring, true);
        _fundManagerSeed(address(usdc), manager, address(factory), 10_000e6);
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
        V3Stub.wire(w);
        w.apiSigner = apiSigner;
        w.managerRegistry = hub ? registry : address(0);
        w.priceSource = hub ? prices : address(0);
        w.protocolRecipient = recipient;
        w.guardian = guardian;
        w.flowFeeBps = 25;
    }

    function _factory(IFundFactory.ProtocolWiring memory w, bool hub) internal returns (FundFactory) {
        Deployment memory d;
        d = _deployFactory(w, hub, d);
        if (hub) hubDeployment = d;
        return d.factory;
    }

    function _spokeFactory() internal returns (FundFactory f, IFundFactory.ProtocolWiring memory w) {
        vm.revertToState(cleanState);
        vm.chainId(SPOKE);
        w = _wiring(false);
        f = _factory(w, false);
    }

    function _poolKey(address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 500, 10, IHooks(address(0)));
    }

    function _plan() internal view returns (FundPlan memory plan) {
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
    }

    function _mandate(FundFactory f) internal view returns (Mandate memory) {
        return _buildMandate(f, f.fundIdOf(HUB, 1, manager), _plan());
    }

    function _createFund() internal returns (IFundFactory.FundAddresses memory a, Mandate memory m) {
        m = _mandate(factory);
        vm.prank(manager);
        a = factory.createFund(m, _hubParams(1, _plan(), _coreVaultCreationCode(hubDeployment)));
    }

    function _chainIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = HUB;
        ids[1] = SPOKE;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Wiring and predictions
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC136_factoryRecordsTheV3WiringTheApiKeyAndTheSwapAdapterCode() public view {
        assertEq(factory.ROLE_UNISWAP_V3_SWAP_ADAPTER(), bytes32("UniswapV3SwapAdapter"));
        IFundFactory.ProtocolWiring memory w = factory.wiring();
        assertEq(w.uniswapV3Factory, hubWiring.uniswapV3Factory);
        assertEq(w.uniswapV3SwapRouter02, hubWiring.uniswapV3SwapRouter02);
        assertEq(w.uniswapV3QuoterV2, hubWiring.uniswapV3QuoterV2);
        assertEq(w.apiSigner, apiSigner);
        assertEq(
            factory.creationCodeHash(factory.ROLE_UNISWAP_V3_SWAP_ADAPTER()),
            keccak256(vm.getCode("UniswapV3SwapAdapter.sol:UniswapV3SwapAdapter")),
            "the stored creation code, pinned by hash"
        );
    }

    /// @dev DEC-053, DEC-054: the swap adapter of every chain is known before any contract exists, and the Mandate
    ///      the scripts build names exactly those.
    function test_DEC136_predictedSwapAdaptersAreTheMandateOnes() public view {
        IFundFactory.FundAddresses memory p = factory.predictAddresses(1, manager, _chainIds());
        bytes32 fundId = factory.fundIdOf(HUB, 1, manager);
        bytes32 role = factory.ROLE_UNISWAP_V3_SWAP_ADAPTER();
        assertEq(p.chains[0].uniswapV3SwapAdapter, factory.addressOf(fundId, role, HUB));
        assertEq(p.chains[1].uniswapV3SwapAdapter, factory.addressOf(fundId, role, SPOKE));
        assertTrue(p.chains[0].uniswapV3SwapAdapter != p.chains[1].uniswapV3SwapAdapter, "one per chain");

        Mandate memory m = _mandate(factory);
        assertEq(m.swapAdapters.length, 2);
        assertEq(m.swapAdapters[0].chainId, HUB);
        assertEq(m.swapAdapters[0].adapter, p.chains[0].uniswapV3SwapAdapter);
        assertEq(m.swapAdapters[1].chainId, SPOKE);
        assertEq(m.swapAdapters[1].adapter, p.chains[1].uniswapV3SwapAdapter);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // createFund and createSpoke
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC136_createFundDeploysTheHubSwapAdapterWiredAndPinned() public {
        IFundFactory.FundAddresses memory predicted = factory.predictAddresses(1, manager, _chainIds());
        (IFundFactory.FundAddresses memory a,) = _createFund();
        IFundFactory.ChainAddresses memory hub = a.chains[0];
        assertEq(hub.uniswapV3SwapAdapter, predicted.chains[0].uniswapV3SwapAdapter, "at the predicted address");

        UniswapV3SwapAdapter swap = UniswapV3SwapAdapter(hub.uniswapV3SwapAdapter);
        assertEq(swap.vault(), hub.spokeVault, "outputs go to the hub Spoke Vault (DEC-136 item 2)");
        assertEq(swap.guardian(), guardian);
        assertEq(swap.baseToken(), address(usdc));
        assertEq(swap.routeSigner(), apiSigner, "D-01: the API key signs routes");
        assertEq(address(swap.v3Factory()), hubWiring.uniswapV3Factory);
        assertEq(address(swap.swapRouter()), hubWiring.uniswapV3SwapRouter02);
        assertEq(address(swap.quoterV2()), hubWiring.uniswapV3QuoterV2);
        assertTrue(swap.isMandateToken(address(usdc)));
        assertTrue(swap.isMandateToken(address(weth)));
        assertFalse(swap.isMandateToken(address(usdg)), "only this chain's Mandate tokens");
        assertFalse(swap.isMandateToken(address(spokeWeth)));

        SpokeVault hubVault = SpokeVault(hub.spokeVault);
        address[] memory pinned = hubVault.swapAdapters();
        assertEq(pinned.length, 1);
        assertEq(pinned[0], address(swap));
        assertEq(hubVault.adapterCodehash(address(swap)), address(swap).codehash, "Q17-4: codehash pinned");

        assertEq(CoreVault(a.coreVault).wormholeCore(), address(hubWormhole), "D-15: the Hub's Core");
    }

    function test_DEC136_createSpokeDeploysTheSpokeSwapAdapterWiredAndPinned() public {
        (IFundFactory.FundAddresses memory a, Mandate memory m) = _createFund();
        address hubFactory = address(factory);
        (FundFactory spokeFactory, IFundFactory.ProtocolWiring memory w) = _spokeFactory();
        assertEq(address(spokeFactory), hubFactory, "same factory address on every chain");
        vm.prank(manager);
        IFundFactory.ChainAddresses memory c =
            spokeFactory.createSpoke(a.creationNumber, m, _spokeParams(MandateLib.hash(m), _plan()));
        assertEq(c.uniswapV3SwapAdapter, m.swapAdapters[1].adapter, "the Mandate's spoke swap adapter");

        UniswapV3SwapAdapter swap = UniswapV3SwapAdapter(c.uniswapV3SwapAdapter);
        assertEq(swap.vault(), c.spokeVault);
        assertEq(swap.baseToken(), address(usdg));
        assertEq(swap.routeSigner(), apiSigner);
        assertEq(address(swap.v3Factory()), w.uniswapV3Factory, "the spoke chain's own V3 deployment");
        assertTrue(swap.isMandateToken(address(usdg)));
        assertTrue(swap.isMandateToken(address(spokeWeth)));
        assertFalse(swap.isMandateToken(address(usdc)));

        SpokeVault spokeVault = SpokeVault(c.spokeVault);
        assertEq(spokeVault.swapAdapters()[0], address(swap));
        assertEq(spokeVault.adapterCodehash(address(swap)), address(swap).codehash);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Refusals
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev DEC-053: a Mandate can name only the fund's own swap adapter.
    function test_DEC136_foreignSwapAdapterIsRefused() public {
        Mandate memory m = _mandate(factory);
        address foreign = makeAddr("foreignSwapAdapter");
        m.swapAdapters[0].adapter = foreign;
        IFundFactory.HubParams memory p = _hubParams(1, _plan(), _coreVaultCreationCode(hubDeployment));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.UnexpectedSwapAdapter.selector, HUB, foreign));
        factory.createFund(m, p);
    }

    /// @dev Every fund chain needs a swap adapter, so a chain without Uniswap V3 wiring hosts no fund.
    function test_DEC136_chainWithoutV3WiringHostsNoFund() public {
        vm.revertToState(cleanState);
        vm.chainId(HUB);
        IFundFactory.ProtocolWiring memory w = _wiring(true);
        w.uniswapV3Factory = address(0);
        factory = _factory(w, true);
        _fundManagerSeed(address(usdc), manager, address(factory), 10_000e6);
        Mandate memory m = _mandate(factory);
        IFundFactory.HubParams memory p = _hubParams(1, _plan(), _coreVaultCreationCode(hubDeployment));
        bytes32 role = factory.ROLE_UNISWAP_V3_SWAP_ADAPTER();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.ProtocolNotOnChain.selector, role));
        factory.createFund(m, p);
    }

    /// @dev The swap adapter refuses a router wired to another V3 factory; the creation reverts with its reason.
    function test_DEC136_miswiredRouterRevertsTheCreation() public {
        vm.revertToState(cleanState);
        vm.chainId(HUB);
        IFundFactory.ProtocolWiring memory w = _wiring(true);
        w.uniswapV3SwapRouter02 = address(new MockMiswiredPeriphery(address(new MockV3Factory())));
        factory = _factory(w, true);
        _fundManagerSeed(address(usdc), manager, address(factory), 10_000e6);
        Mandate memory m = _mandate(factory);
        IFundFactory.HubParams memory p = _hubParams(1, _plan(), _coreVaultCreationCode(hubDeployment));
        vm.prank(manager);
        vm.expectRevert(UniswapV3SwapAdapter.WiringMismatch.selector);
        factory.createFund(m, p);
    }
}
