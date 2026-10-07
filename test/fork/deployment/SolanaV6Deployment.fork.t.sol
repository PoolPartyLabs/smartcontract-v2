pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SolanaV6Deployment} from "../../../script/SolanaV6Deployment.sol";
import {SolanaPriceSourceV6} from "../../../src/report/SolanaPriceSourceV6.sol";
import {ValueReportReceiverV6} from "../../../src/report/ValueReportReceiverV6.sol";

/// @notice DEC-188/196/198: fork-test the exact deploy path, with no contract size-limit override.
contract SolanaV6DeploymentForkTest is Test, SolanaV6Deployment {
    function testVersionedFactoryIdentityMatchesBothPublicForks() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envOr("ARBITRUM_FORK_BLOCK", uint256(512_239_244)));
        V6Deployment memory hub = _deploy();
        assertGt(address(hub.factory).code.length, 0);
        assertLe(address(hub.factory).code.length, 24_576);
        assertEq(hub.factory.creationCodeHash(hub.factory.ROLE_CORE_VAULT()), keccak256(hub.coreCode));
        assertEq(
            hub.factory.creationCodeHash(hub.factory.ROLE_VALUE_REPORT_RECEIVER()),
            keccak256(type(ValueReportReceiverV6).creationCode)
        );
        SolanaPriceSourceV6 source = SolanaPriceSourceV6(hub.common.priceSource);
        assertGt(source.TSLA_USD().code.length, 0);
        assertGt(source.NVDA_USD().code.length, 0);
        assertGt(source.SOL_USD().code.length, 0);
        bytes32 fund = hub.factory.fundIdOf(42_161, hub.factory.NUMBER_OFFSET() + 1, address(123));
        address predicted = hub.factory.addressOf(fund, "SpokeVault", 4663);
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));
        V6Deployment memory spoke = _deploy();
        assertEq(address(hub.factory), address(spoke.factory));
        assertEq(spoke.factory.addressOf(fund, "SpokeVault", 4663), predicted);
        assertEq(spoke.common.priceSource, address(0));
        assertEq(spoke.common.managerRegistry, address(0));
    }

    function _deploy() private returns (V6Deployment memory) {
        return _deployV6(address(11), address(12), address(13), address(13), 1_791_293_400, 1_791_316_800, 3600);
    }
}
