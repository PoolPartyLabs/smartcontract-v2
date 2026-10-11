// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";

/// @notice Independent verification plan F-12 (FF-10, SF-1, CF-V4-10): the deployment script refuses a wiring the
///         factory would accept but no fund could use, checked against the live Arbitrum One contracts.
contract FactoryWiringCheckForkTest is Test, FactoryDeployment {
    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
    }

    function _liveWiring() internal returns (IFundFactory.ProtocolWiring memory w) {
        w = _chainWiring(ARBITRUM);
        w.managerRegistry = address(new Dummy());
        w.priceSource = address(new Dummy());
    }

    function check(IFundFactory.ProtocolWiring memory w) external view {
        _checkWiring(w);
    }

    function test_REVIEW_F12_liveArbitrumWiringPasses() public {
        this.check(_liveWiring());
    }

    function test_REVIEW_SF1_codelessRegistryIsRefused() public {
        IFundFactory.ProtocolWiring memory w = _liveWiring();
        w.managerRegistry = makeAddr("typo");
        vm.expectRevert(abi.encodeWithSelector(WiringHasNoCode.selector, "managerRegistry", w.managerRegistry));
        this.check(w);
    }

    function test_REVIEW_CFV4_10_poolManagerOfAnotherDeploymentIsRefused() public {
        IFundFactory.ProtocolWiring memory w = _liveWiring();
        address live = w.uniswapV4PoolManager;
        w.uniswapV4PoolManager = w.wormholeCore; // has code, is not the PositionManager's PoolManager
        vm.expectRevert(
            abi.encodeWithSelector(
                V4WiringMismatch.selector, "positionManager.poolManager", live, w.uniswapV4PoolManager
            )
        );
        this.check(w);
    }
}

contract Dummy {}
