pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {FundMandate} from "../../../script/FundMandate.sol";
import {CheckAlphaDeployment} from "../../../script/CheckAlphaDeployment.s.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AlphaDeploymentCheckForkTest is Test, FactoryDeployment, FundMandate {
    function test_DEC134_checkPassesOnBothRealProtocolForks() public {
        uint256 hub = vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        address manager = address(123);
        Deployment memory deployment = _deployProtocol(address(456), address(789), address(987), address(987));
        FundPlan memory plan;
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
        plan.spokeCap = 10_000e6;
        plan.maxReportAge = 1588;
        plan.minFirstDeposit = 100e6;
        plan.performanceFeeBps = 2000;
        Mandate memory mandate =
            _buildMandate(deployment.factory, deployment.factory.fundIdOf(ARBITRUM, 1, manager), plan);
        deal(ARB_USDC, manager, 100e6);
        vm.startPrank(manager);
        IERC20(ARB_USDC).approve(address(deployment.factory), 100e6);
        deployment.factory.createFund(mandate, _hubParams(1, plan, _coreVaultCreationCode(deployment)));
        vm.stopPrank();
        _environment(deployment.factory, MandateLib.hash(mandate), manager);
        new CheckAlphaDeployment().run();
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));
        Deployment memory spoke = _deployProtocol(address(456), address(789), address(987), address(987));
        assertEq(address(spoke.factory), address(deployment.factory));
        vm.prank(manager);
        spoke.factory.createSpoke(1, mandate, _spokeParams(MandateLib.hash(mandate), plan));
        new CheckAlphaDeployment().run();
        vm.selectFork(hub);
        vm.setEnv("MANDATE_HASH", vm.toString(bytes32(uint256(1))));
        CheckAlphaDeployment checker = new CheckAlphaDeployment();
        vm.expectRevert();
        checker.run();
    }

    function _environment(FundFactory factory, bytes32 hash, address manager) private {
        vm.setEnv("FUND_FACTORY", vm.toString(address(factory)));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(address(this)));
        vm.setEnv("MANAGER", vm.toString(manager));
        vm.setEnv("CREATION_NUMBER", "1");
        vm.setEnv("MANDATE_HASH", vm.toString(hash));
        vm.setEnv("PROTOCOL_RECIPIENT", vm.toString(address(456)));
        vm.setEnv("ADAPTER_GUARDIAN", vm.toString(address(789)));
        vm.setEnv("API_SIGNER", vm.toString(address(987)));
        vm.setEnv("REGISTRY_OWNER", vm.toString(address(987)));
        vm.setEnv("SPOKE_CAP", "10000000000");
        vm.setEnv("MIN_FIRST_DEPOSIT", "100000000");
        vm.setEnv("PERFORMANCE_FEE_BPS", "2000");
        vm.setEnv("MANAGEMENT_FEE_BPS", "0");
        vm.setEnv("SPOKE_OPERATING_CASH_FLOOR", "0");
        vm.setEnv("SPOKE_OPERATING_CASH_TOP_UP", "0");
    }
}
