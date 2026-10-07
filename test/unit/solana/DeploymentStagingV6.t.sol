pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SolanaDeploymentV6} from "../../../src/factory/SolanaDeploymentV6.sol";
import {SolanaMandateV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {SolanaFixture} from "./SolanaFixture.sol";

/// @notice DEC-200/202: signed config and deployed registry must retain identical policy commitments.
contract DeploymentStagingV6Test is Test {
    SolanaMandateV6.Config private pending;

    function testStoreAndClearRetainEveryNativeCommitment() public {
        SolanaMandateV6.Config memory native = SolanaFixture.nativeConfig();
        native.swapPolicyHash = keccak256("sealed-policy");
        SolanaDeploymentV6.store(pending, native);
        SolanaMandateV6.Config memory stored = pending;
        assertEq(SolanaMandateV6.hash(stored), SolanaMandateV6.hash(native));
        assertEq(stored.swapPolicyHash, native.swapPolicyHash);
        SolanaDeploymentV6.clear(pending);
        assertEq(pending.swapPolicyHash, bytes32(0));
        assertEq(pending.assets.length, 0);
        assertEq(pending.venues.length, 0);
        native.swapPolicyHash = bytes32(0);
        SolanaDeploymentV6.store(pending, native);
        stored = pending;
        assertEq(SolanaMandateV6.hash(stored), SolanaMandateV6.hash(native));
    }
}
