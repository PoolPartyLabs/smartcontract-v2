pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SolanaPdaV6} from "../../../src/mandate/SolanaPdaV6.sol";
import {SolanaPolicyV6} from "../../../src/mandate/SolanaPolicyV6.sol";
import {SolanaMandateV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {SolanaFixture} from "./SolanaFixture.sol";

contract PolicyV6Test is Test {
    function testCanonicalPdaGoldenVector() public pure {
        bytes32 program = 0xda075cb2ff5ec6817613de530c085e191675062a1ce4a10189ea49d29d739f06;
        bytes32 fund = SolanaPdaV6.fund(42161, 0x0202020202020202020202020202020202020202, 1,
            0x0303030303030303030303030303030303030303030303030303030303030303, program);
        assertEq(fund, 0x59196f6ece881da9abd0e61ea5a6cdac8c533accd9f6c553f9db86832c36eb11);
        assertEq(SolanaPdaV6.derive(abi.encodePacked("vault", fund), program),
            0xc221b91f19582a11c828666b04134c6098e18f28c2e40039b17dfc4843d45487);
        assertEq(SolanaPdaV6.derive(abi.encodePacked("emitter", fund), program),
            0x5de38779390fa0c56507176d77a6b982534d97b5348352ac9074025a46917432);
    }

    function testIdentityFreePolicyRetainsManagerAndFeePolicy() public pure {
        SolanaMandateV6.Config memory native = SolanaFixture.nativeConfig();
        bytes32 policy = SolanaPolicyV6.nativePolicyHash(native);
        bytes32 original = SolanaMandateV6.hash(native);
        assertEq(original, SolanaMandateV6.hash(native));
        native.spoke = bytes32(uint256(99));
        native.transport.mintRecipient = bytes32(uint256(98));
        native.transport.destinationCaller = bytes32(uint256(97));
        native.transport.remoteVaultAuthority = bytes32(uint256(96));
        assertEq(policy, SolanaPolicyV6.nativePolicyHash(native));
        native.transport.fastFeeCeiling += 1;
        assertNotEq(policy, SolanaPolicyV6.nativePolicyHash(native));
    }
}
