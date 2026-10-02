// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {ManagerFeeVault} from "../../../src/core/ManagerFeeVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {AaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {FundMandate} from "../../../script/FundMandate.sol";
import {FundSeed} from "../../utils/FundSeed.sol";

/// @notice The operator's deployment (script/FactoryDeployment.sol) and a fund's creation against the live protocols of
///         Arbitrum One (Hub Chain) and Robinhood Chain (Spoke Chain), pinned to the .env fork blocks: the factory lands
///         at the same address on both chains, `createFund` puts every contract at its predicted address wired to the
///         real Across SpokePool, Aave V3 Pool, Uniswap V4 and Wormhole Core, and `createSpoke` puts the Spoke Vault at
///         the address the hub's Mandate already names (DEC-053, DEC-054).
contract FundFactoryForkTest is Test, FactoryDeployment, FundMandate, FundSeed {
    /// @dev docs/INTEGRATIONS.md fork-test pools.
    bytes32 internal constant ARB_WETH_USDC_POOL_ID =
        0xfc7b3ad139daaf1e9c3637ed921c154d1b04286f8a82b805a6c352da57028653;
    bytes32 internal constant RH_WETH_USDG_POOL_ID = 0xfcfae8fa0bd6da961bcf5d990f27690932deac4f093e99bf3e871691c6586593;
    address internal constant ARB_AUSDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637;

    uint256 internal arbitrumFork;
    uint256 internal robinhoodFork;

    address internal manager = makeAddr("manager");
    address internal recipient = makeAddr("protocolRecipient");
    address internal guardian = makeAddr("guardian");
    address internal registryOwner = makeAddr("registryOwner");

    function setUp() public {
        arbitrumFork = vm.createFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        robinhoodFork = vm.createFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));
    }

    function _plan() internal view returns (FundPlan memory plan) {
        plan.manager = manager;
        plan.hubChainId = ARBITRUM;
        plan.hubWormholeChainId = WORMHOLE_ARBITRUM;
        plan.usdc = ARB_USDC;
        plan.hubPool = PoolKey(Currency.wrap(ARB_WETH), Currency.wrap(ARB_USDC), 500, 10, IHooks(address(0)));
        plan.hubAaveAsset = ARB_USDC;
        plan.spokeChainId = ROBINHOOD;
        plan.spokeWormholeChainId = WORMHOLE_ROBINHOOD;
        plan.spokeToken = RH_USDG;
        plan.spokePool = PoolKey(Currency.wrap(RH_WETH), Currency.wrap(RH_USDG), 500, 10, IHooks(address(0)));
        plan.spokeCap = 1_000_000e6;
        // Ruling 2026-09-29: Robinhood 1,587 s plus one block, rounded up.
        plan.maxReportAge = 1588;
        plan.spokeOperatingCashFloor = 5e6;
        plan.spokeOperatingCashTopUp = 10e6;
        plan.minFirstDeposit = 100e6;
        plan.performanceFeeBps = 2000;
    }

    function _chainIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = ARBITRUM;
        ids[1] = ROBINHOOD;
    }

    function _hubDeployment() internal returns (Deployment memory d) {
        vm.selectFork(arbitrumFork);
        d = _deployProtocol(recipient, guardian, registryOwner, registryOwner);
    }

    function test_DEC054_forkCreateFundOnArbitrumThenCreateSpokeOnRobinhood() public {
        Deployment memory d = _hubDeployment();
        FundPlan memory plan = _plan();
        assertEq(PoolId.unwrap(plan.hubPool.toId()), ARB_WETH_USDC_POOL_ID, "INTEGRATIONS pool id");
        assertEq(PoolId.unwrap(plan.spokePool.toId()), RH_WETH_USDG_POOL_ID, "INTEGRATIONS pool id");

        uint256 n = d.factory.nextCreationNumber();
        IFundFactory.FundAddresses memory predicted = d.factory.predictAddresses(n, manager, _chainIds());
        Mandate memory m = _buildMandate(d.factory, predicted.fundId, plan);
        IFundFactory.HubParams memory p = _hubParams(n, plan, _coreVaultCreationCode(d));
        uint256 gasBefore = gasleft();
        _fundManagerSeed(ARB_USDC, manager, address(d.factory), p.seedAmount);
        vm.prank(manager);
        IFundFactory.FundAddresses memory a = d.factory.createFund(m, p);
        emit log_named_uint("createFund gas (execution, Arbitrum One)", gasBefore - gasleft());

        _assertHubPredicted(a, predicted);
        _assertHubWired(d, a, MandateLib.hash(m));
        _createSpokeOnRobinhood(d, plan, m, predicted);
    }

    /// @dev Every predicted hub address has code and is what `createFund` returned.
    function _assertHubPredicted(IFundFactory.FundAddresses memory a, IFundFactory.FundAddresses memory predicted)
        internal
        view
    {
        IFundFactory.ChainAddresses memory hub = a.chains[0];
        assertEq(a.coreVault, predicted.coreVault);
        assertEq(a.shareToken, predicted.shareToken);
        assertEq(a.managerFeeVault, predicted.managerFeeVault);
        assertEq(a.valueReportReceiver, predicted.valueReportReceiver);
        assertEq(hub.spokeVault, predicted.chains[0].spokeVault);
        assertEq(hub.uniswapV4Adapter, predicted.chains[0].uniswapV4Adapter);
        assertEq(hub.aaveV3Adapter, predicted.chains[0].aaveV3Adapter);
        assertEq(hub.acrossBridgeAdapter, predicted.chains[0].acrossBridgeAdapter);
        address[8] memory deployed = [
            a.coreVault,
            a.shareToken,
            a.managerFeeVault,
            a.valueReportReceiver,
            hub.spokeVault,
            hub.uniswapV4Adapter,
            hub.aaveV3Adapter,
            hub.acrossBridgeAdapter
        ];
        for (uint256 i; i < deployed.length; ++i) {
            assertTrue(deployed[i].code.length != 0, "predicted address has code");
        }
    }

    /// @dev Adapters' vault(), receiver's coreVault(), Core Vault's hubSpokeVault(), share token PP-{n}, real protocols.
    function _assertHubWired(Deployment memory d, IFundFactory.FundAddresses memory a, bytes32 mandateHash)
        internal
        view
    {
        IFundFactory.ChainAddresses memory hub = a.chains[0];
        CoreVault core = CoreVault(a.coreVault);
        assertEq(core.hubSpokeVault(), hub.spokeVault);
        assertEq(core.reportReceiver(), a.valueReportReceiver);
        assertEq(core.shareToken(), a.shareToken);
        assertEq(core.managerFeeVault(), a.managerFeeVault);
        assertEq(core.managerRegistry(), d.managerRegistry);
        assertEq(core.priceSource(), d.priceSource);
        assertEq(core.acrossSpokePool(), ARB_ACROSS_SPOKE_POOL);
        assertEq(core.mandateHash(), mandateHash);
        string memory number = vm.toString(a.creationNumber);
        assertEq(ShareToken(a.shareToken).symbol(), string.concat("PP-", number));
        assertEq(ShareToken(a.shareToken).name(), string.concat("Pool Party Fund ", number));
        assertEq(ManagerFeeVault(a.managerFeeVault).manager(), manager);
        assertEq(ValueReportReceiver(a.valueReportReceiver).coreVault(), a.coreVault);
        assertEq(ValueReportReceiver(a.valueReportReceiver).coreBridge(), ARB_WORMHOLE_CORE);
        assertEq(SpokeVault(hub.spokeVault).coreVault(), a.coreVault);
        assertEq(UniswapV4Adapter(hub.uniswapV4Adapter).vault(), hub.spokeVault);
        assertEq(address(UniswapV4Adapter(hub.uniswapV4Adapter).poolManager()), ARB_V4_POOL_MANAGER);
        (address token0, address token1) = UniswapV4Adapter(hub.uniswapV4Adapter).poolTokens(ARB_WETH_USDC_POOL_ID);
        assertEq(token0, ARB_WETH);
        assertEq(token1, ARB_USDC);
        assertEq(AaveV3Adapter(hub.aaveV3Adapter).vault(), hub.spokeVault);
        assertEq(address(AaveV3Adapter(hub.aaveV3Adapter).pool()), ARB_AAVE_V3_POOL);
        (token0,) = AaveV3Adapter(hub.aaveV3Adapter).poolTokens(bytes32(uint256(uint160(ARB_USDC))));
        assertEq(token0, ARB_USDC);
        assertEq(AcrossBridgeAdapter(hub.acrossBridgeAdapter).vault(), a.coreVault);
        assertEq(AcrossBridgeAdapter(hub.acrossBridgeAdapter).spokePool(), ARB_ACROSS_SPOKE_POOL);
        assertTrue(d.factory.isFund(a.coreVault));
        assertEq(d.factory.fundByNumber(a.creationNumber), a.coreVault);
    }

    /// @dev Same operator, same salt: the Robinhood factory sits at the hub factory's address, so the Mandate built on
    ///      the hub names the right Spoke Vault.
    function _createSpokeOnRobinhood(
        Deployment memory d,
        FundPlan memory plan,
        Mandate memory m,
        IFundFactory.FundAddresses memory predicted
    ) internal {
        vm.selectFork(robinhoodFork);
        Deployment memory rd = _deployProtocol(recipient, guardian, registryOwner, registryOwner);
        assertEq(address(rd.factory), address(d.factory), "same factory address on both chains");
        assertEq(rd.spokeCrossChainLib, d.spokeCrossChainLib, "chain-independent library address");
        assertEq(rd.spokeUnwindLib, d.spokeUnwindLib, "chain-independent unwind library address");

        // A Mandate whose spoke entry is not the prediction is refused on the spoke too.
        Mandate memory forged = _buildMandate(rd.factory, predicted.fundId, plan);
        bytes32 foreign = bytes32(uint256(uint160(makeAddr("foreignSpokeVault"))));
        forged.spokes[0].spokeVault = foreign;
        IFundFactory.SpokeParams memory forgedParams = _spokeParams(MandateLib.hash(forged), plan);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IFundFactory.SpokeVaultMismatch.selector, ROBINHOOD, m.spokes[0].spokeVault, foreign)
        );
        rd.factory.createSpoke(predicted.creationNumber, forged, forgedParams);

        IFundFactory.SpokeParams memory sp = _spokeParams(MandateLib.hash(m), plan);
        uint256 gasBefore = gasleft();
        vm.prank(manager);
        IFundFactory.ChainAddresses memory spoke = rd.factory.createSpoke(predicted.creationNumber, m, sp);
        emit log_named_uint("createSpoke gas (execution, Robinhood Chain)", gasBefore - gasleft());

        assertEq(spoke.spokeVault, predicted.chains[1].spokeVault);
        assertEq(bytes32(uint256(uint160(spoke.spokeVault))), m.spokes[0].spokeVault);
        assertEq(spoke.uniswapV4Adapter, predicted.chains[1].uniswapV4Adapter);
        assertEq(spoke.acrossBridgeAdapter, predicted.chains[1].acrossBridgeAdapter);
        assertTrue(spoke.spokeVault.code.length != 0);
        assertTrue(spoke.uniswapV4Adapter.code.length != 0);
        assertTrue(spoke.acrossBridgeAdapter.code.length != 0);
        _assertSpokeWired(spoke, predicted, MandateLib.hash(m));
    }

    function _assertSpokeWired(
        IFundFactory.ChainAddresses memory spoke,
        IFundFactory.FundAddresses memory predicted,
        bytes32 mandateHash
    ) internal {
        SpokeVault vault = SpokeVault(spoke.spokeVault);
        assertEq(vault.coreVault(), predicted.coreVault, "the hub Core Vault");
        assertEq(vault.fundId(), predicted.fundId);
        assertEq(vault.mandateHash(), mandateHash);
        assertEq(vault.baseToken(), RH_USDG);
        assertEq(vault.wormholeCore(), RH_WORMHOLE_CORE);
        assertEq(vault.acrossSpokePool(), RH_ACROSS_SPOKE_POOL);
        assertEq(UniswapV4Adapter(spoke.uniswapV4Adapter).vault(), spoke.spokeVault);
        (address token0, address token1) = UniswapV4Adapter(spoke.uniswapV4Adapter).poolTokens(RH_WETH_USDG_POOL_ID);
        assertEq(token0, RH_WETH);
        assertEq(token1, RH_USDG);
        assertEq(AcrossBridgeAdapter(spoke.acrossBridgeAdapter).vault(), spoke.spokeVault);
        assertEq(AcrossBridgeAdapter(spoke.acrossBridgeAdapter).spokePool(), RH_ACROSS_SPOKE_POOL);

        // The linked SpokeCrossChainLib runs: the new Spoke Vault publishes its first report on the real Wormhole Core.
        (uint64 sequence,) = vault.report();
        assertEq(sequence, 1);
    }

    function test_DEC054_forkMandateSpokeEntryNotPredictedReverts() public {
        Deployment memory d = _hubDeployment();
        FundPlan memory plan = _plan();
        uint256 n = d.factory.nextCreationNumber();
        bytes32 fundId = d.factory.fundIdOf(ARBITRUM, n, manager);
        Mandate memory m = _buildMandate(d.factory, fundId, plan);
        bytes32 predicted = m.spokes[0].spokeVault;
        bytes32 foreign = bytes32(uint256(uint160(makeAddr("foreignSpokeVault"))));
        m.spokes[0].spokeVault = foreign;
        IFundFactory.HubParams memory p = _hubParams(n, plan, _coreVaultCreationCode(d));
        _fundManagerSeed(ARB_USDC, manager, address(d.factory), p.seedAmount);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IFundFactory.SpokeVaultMismatch.selector, ROBINHOOD, predicted, foreign));
        d.factory.createFund(m, p);
    }

    function test_DEC058_forkForeignCoreVaultCreationCodeReverts() public {
        Deployment memory d = _hubDeployment();
        FundPlan memory plan = _plan();
        uint256 n = d.factory.nextCreationNumber();
        Mandate memory m = _buildMandate(d.factory, d.factory.fundIdOf(ARBITRUM, n, manager), plan);
        // The Core Vault linked to another library: same contract, foreign code.
        d.coreVaultLogic = d.spokeCrossChainLib;
        bytes memory foreignCode = _coreVaultCreationCode(d);
        IFundFactory.HubParams memory p = _hubParams(n, plan, foreignCode);
        bytes32 role = d.factory.ROLE_CORE_VAULT();
        bytes memory reason = abi.encodeWithSelector(
            IFundFactory.ForeignCreationCode.selector, role, keccak256(foreignCode), d.factory.creationCodeHash(role)
        );
        _fundManagerSeed(ARB_USDC, manager, address(d.factory), p.seedAmount);
        vm.prank(manager);
        vm.expectRevert(reason);
        d.factory.createFund(m, p);
    }
}
