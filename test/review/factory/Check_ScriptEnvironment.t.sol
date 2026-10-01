// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Lead 3 (script defaults): what `vm.envOr` and `vm.envAddress` return for an unset and for an empty variable,
///         the two cases `script/CreateFund.s.sol` and `script/DeployFactory.s.sol` meet when `.env` is copied from
///         `.env.example` and edited.
contract Check_ScriptEnvironment is Test {
    function test_lead3_envOrOnUnsetReturnsTheDefault() public view {
        assertEq(vm.envOr("PP_REVIEW_UNSET_SPOKE_CAP", uint256(10_000e6)), 10_000e6);
    }

    function test_lead3_envOrOnEmptyValue() public {
        vm.setEnv("PP_REVIEW_EMPTY_SPOKE_CAP", "");
        // An empty value is not "unset": record what forge does with it.
        try this.envOrUint("PP_REVIEW_EMPTY_SPOKE_CAP", 10_000e6) returns (uint256 v) {
            emit log_named_uint("envOr on an empty value returned", v);
        } catch {
            emit log("envOr on an empty value reverted");
        }
    }

    function test_lead3_envAddressOnEmptyValueReverts() public {
        vm.setEnv("PP_REVIEW_EMPTY_RECIPIENT", "");
        vm.expectRevert();
        this.envAddr("PP_REVIEW_EMPTY_RECIPIENT");
    }

    function envOrUint(string calldata name, uint256 fallback_) external view returns (uint256) {
        return vm.envOr(name, fallback_);
    }

    function envAddr(string calldata name) external view returns (address) {
        return vm.envAddress(name);
    }
}
