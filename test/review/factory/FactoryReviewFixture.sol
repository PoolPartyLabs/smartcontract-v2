// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreBridgeVM, GuardianSignature} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {ManagerRegistry} from "../../../src/core/ManagerRegistry.sol";
import {IAcrossMessageHandler} from "../../../src/interfaces/external/IAcrossMessageHandler.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {MockAcrossSpokePool} from "../../mocks/across/MockAcrossSpokePool.sol";
import {MockAaveV3Pool} from "../../mocks/aave/MockAaveV3Pool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {MockCoreBridge} from "../../mocks/receiver/MockCoreBridge.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {FundMandate} from "../../../script/FundMandate.sol";

/// @notice Review fixture (factory): the REAL deployment path (`script/FactoryDeployment.sol` and
///         `script/FundMandate.sol`, as the repository's factory tests use them) on two simulated chains, with every fund
///         contract created by the real `FundFactory` from the stored creation code: Core Vault (+ CoreVaultLogic),
///         ShareToken, ManagerFeeVault, ValueReportReceiver, hub and spoke Spoke Vaults (+ SpokeCrossChainLib), Uniswap V4,
///         Aave V3 and Across adapters. The hub factory and the spoke factory sit at the same address, as on mainnet, so
///         they live in two EVM states (`hubState` and the spoke state built from `cleanState`); data crosses between
///         them only as test-memory values (report payloads, transit ids), the way the chains exchange them.
/// @dev Mocked: the tokens, both Across SpokePools (deposits; fills are simulated by `_acrossFill` the way the live
///      pool does them: transfer first, callback only when the recipient has code and the message is not empty, see
///      Fork_AcrossFillToCodelessSpokeVault.t.sol), the Aave pool, the Wormhole Core on the spoke (records payloads),
///      the Core Bridge on the hub (a VAA is `abi.encode(CoreBridgeVM)`), the price source. Uniswap V4 contracts are
///      bare addresses: no position is ever opened.
abstract contract FactoryReviewFixture is Test, FactoryDeployment, FundMandate {
    uint256 internal constant HUB = 42_161;
    uint256 internal constant SPOKE = 4663;
    uint16 internal constant WH_SPOKE = 72;
    uint256 internal constant T0 = 1_800_000_000;
    /// @dev DEC-086 measured fact (docs/DECISIONS.md): a finalized Robinhood VAA exists about 925 to 1,190 s after
    ///      publication. A report can never be delivered earlier than this.
    uint256 internal constant FINALITY = 925;

    MockToken internal usdc;
    MockToken internal weth;
    MockToken internal usdg;
    MockToken internal spokeWeth;
    MockAcrossSpokePool internal hubAcross;
    MockAcrossSpokePool internal spokeAcross;
    MockAaveV3Pool internal aave;
    MockCoreBridge internal hubCore;
    MockWormholeCore internal spokeCore;
    MockPriceSource internal prices;
    ManagerRegistry internal registry;

    address internal manager = makeAddr("manager");
    address internal managerRelayer = makeAddr("managerRelayer");
    address internal protocolAdmin = makeAddr("protocolAdmin");
    address internal recipient = makeAddr("protocolRecipient");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal relayer = makeAddr("relayer");

    uint256 internal cleanState;

    function setUp() public virtual {
        vm.warp(T0);
        usdc = new MockToken("USDC", 6);
        weth = new MockToken("WETH", 18);
        usdg = new MockToken("USDG", 6);
        spokeWeth = new MockToken("WETH", 18);
        hubAcross = new MockAcrossSpokePool(0);
        spokeAcross = new MockAcrossSpokePool(0);
        aave = new MockAaveV3Pool(MockAaveV3Pool.Rounding.HalfUp);
        aave.listReserve(address(usdc));
        hubCore = new MockCoreBridge();
        spokeCore = new MockWormholeCore();
        prices = new MockPriceSource();
        // The Core Vault refuses a hub pool token its price source cannot price (independent review M-03).
        _refreshPrices();
        registry = new ManagerRegistry(protocolAdmin);
        cleanState = vm.snapshotState();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Chains
    // ---------------------------------------------------------------------------------------------------------------

    function _wiring(bool hub) internal returns (IFundFactory.ProtocolWiring memory w) {
        w.numberOffset = hub ? 0 : 1_000_000;
        w.baseToken = hub ? address(usdc) : address(usdg);
        w.acrossSpokePool = hub ? address(hubAcross) : address(spokeAcross);
        w.wormholeCore = hub ? address(hubCore) : address(spokeCore);
        w.uniswapV4PoolManager = makeAddr(hub ? "hubPoolManager" : "spokePoolManager");
        w.uniswapV4PositionManager = makeAddr(hub ? "hubPositionManager" : "spokePositionManager");
        w.uniswapV4StateView = makeAddr(hub ? "hubStateView" : "spokeStateView");
        w.permit2 = makeAddr("permit2");
        w.aaveV3Pool = hub ? address(aave) : address(0);
        w.managerRegistry = hub ? address(registry) : address(0);
        w.priceSource = hub ? address(prices) : address(0);
        w.protocolRecipient = recipient;
        w.guardian = guardian;
        w.flowFeeBps = 25;
    }

    /// @dev The operator's Arbitrum deployment (clean state, hub chain id).
    function _hubChain() internal returns (Deployment memory d) {
        require(vm.revertToState(cleanState), "clean state");
        vm.chainId(HUB);
        d = _deployFactory(_wiring(true), true, d);
    }

    /// @dev The operator's Robinhood deployment (clean state, spoke chain id): same factory address.
    function _spokeChain() internal returns (FundFactory) {
        require(vm.revertToState(cleanState), "clean state");
        vm.chainId(SPOKE);
        Deployment memory d;
        return _deployFactory(_wiring(false), false, d).factory;
    }

    function _enterHub(uint256 hubState, uint256 timestamp) internal {
        require(vm.revertToState(hubState), "hub state");
        vm.chainId(HUB);
        vm.warp(timestamp);
        _refreshPrices();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fund
    // ---------------------------------------------------------------------------------------------------------------

    function _poolKey(address a, address b, uint24 fee, int24 tickSpacing) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, tickSpacing, IHooks(address(0)));
    }

    /// @dev The Mandate values the repository's factory tests use, with a 200,000 USDC Spoke Cap.
    function _plan() internal view returns (FundPlan memory plan) {
        plan.manager = manager;
        plan.hubChainId = HUB;
        plan.usdc = address(usdc);
        plan.hubPool = _poolKey(address(weth), address(usdc), 500, 10);
        plan.hubAaveAsset = address(usdc);
        plan.spokeChainId = SPOKE;
        plan.spokeWormholeChainId = WH_SPOKE;
        plan.spokeToken = address(usdg);
        plan.spokePool = _poolKey(address(spokeWeth), address(usdg), 500, 10);
        plan.spokeCap = 200_000e6;
        plan.maxReportAge = 1588;
        plan.spokeOperatingCashFloor = 5e6;
        plan.spokeOperatingCashTopUp = 10e6;
        plan.minFirstDeposit = 100e6;
        plan.performanceFeeBps = 2000;
        plan.maxBridgeFeeBps = 50;
    }

    function _createFund(Deployment memory d, FundPlan memory plan)
        internal
        returns (IFundFactory.FundAddresses memory a, Mandate memory m)
    {
        uint256 n = d.factory.nextCreationNumber();
        m = _buildMandate(d.factory, d.factory.fundIdOf(HUB, n, manager), plan);
        IFundFactory.HubParams memory p = _hubParams(n, plan, _coreVaultCreationCode(d.coreVaultLogic));
        vm.prank(manager);
        a = d.factory.createFund(m, p);
    }

    function _createSpoke(FundFactory f, uint256 creationNumber, FundPlan memory plan)
        internal
        returns (SpokeVault spoke, Mandate memory m)
    {
        m = _buildMandate(f, f.fundIdOf(HUB, creationNumber, manager), plan);
        IFundFactory.SpokeParams memory p = _spokeParams(MandateLib.hash(m), plan);
        vm.prank(manager);
        spoke = SpokeVault(f.createSpoke(creationNumber, m, p).spokeVault);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------------------------

    function _refreshPrices() internal {
        prices.setPrice(address(usdg), 1e18);
        prices.setPrice(address(weth), 2.5e9);
        prices.setPrice(address(spokeWeth), 2.5e9);
    }

    function _deposit(CoreVault vault, address who, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        (shares,) = vault.deposit(amount, 0);
        vm.stopPrank();
    }

    /// @dev An Across fill as the live SpokePool performs it (`_fillRelayV3`): the output tokens are transferred to the
    ///      recipient first, and `handleV3AcrossMessage` is called only when the message is not empty AND the
    ///      recipient has code (verified on the live Robinhood pool by Fork_AcrossFillToCodelessSpokeVault.t.sol).
    function _acrossFill(address pool, MockToken token, address to, uint256 amount, bytes memory message) internal {
        token.mint(to, amount);
        if (message.length != 0 && to.code.length != 0) {
            vm.prank(pool);
            IAcrossMessageHandler(to).handleV3AcrossMessage(address(token), amount, relayer, message);
        }
    }

    /// @dev Anyone: `report()` on a spoke; returns the published payload and its Wormhole sequence.
    function _publish(SpokeVault spoke) internal returns (bytes memory payload, uint64 wormholeSequence) {
        (, wormholeSequence) = spoke.report();
        payload = spokeCore.published(spokeCore.publishedCount() - 1).payload;
    }

    /// @dev A finalized VAA of `emitter` on Robinhood (Wormhole chain `WH_SPOKE`) carrying `payload`.
    function _vaa(address emitter, bytes memory payload, uint64 wormholeSequence) internal view returns (bytes memory) {
        return _vaaFrom(WH_SPOKE, emitter, payload, wormholeSequence);
    }

    function _vaaFrom(uint16 emitterChain, address emitter, bytes memory payload, uint64 wormholeSequence)
        internal
        view
        returns (bytes memory)
    {
        CoreBridgeVM memory vmm;
        vmm.version = 1;
        vmm.timestamp = uint32(block.timestamp);
        vmm.emitterChainId = emitterChain;
        vmm.emitterAddress = bytes32(uint256(uint160(emitter)));
        vmm.sequence = wormholeSequence;
        vmm.consistencyLevel = 1;
        vmm.payload = payload;
        vmm.signatures = new GuardianSignature[](0);
        return abi.encode(vmm);
    }

    function _deliver(ValueReportReceiver receiver, bytes memory vaa) internal {
        vm.prank(keeper);
        receiver.deliver(vaa);
    }

    function _principal(bytes32 fundId, uint256 originChainId, bytes32 transitId) internal pure returns (bytes memory) {
        return TransitMessage.encode(fundId, originChainId, transitId, TransferKind.Principal);
    }
}
