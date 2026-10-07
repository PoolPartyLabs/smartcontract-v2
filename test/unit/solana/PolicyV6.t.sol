pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SolanaPdaV6} from "../../../src/mandate/SolanaPdaV6.sol";
import {SolanaPolicyV6} from "../../../src/mandate/SolanaPolicyV6.sol";
import {SolanaMandateV6, SolanaSpokeRegistryV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {SolanaFixture} from "./SolanaFixture.sol";

contract PolicyV6Test is Test {
    function _swapPolicyBorsh() private pure returns (bytes memory) {
        return abi.encodePacked(
            bytes20(0x0101010101010101010101010101010101010101),
            bytes32(0x0202020202020202020202020202020202020202020202020202020202020202),
            bytes32(0x0303030303030303030303030303030303030303030303030303030303030303),
            bytes32(0x0404040404040404040404040404040404040404040404040404040404040404),
            bytes32(0x0505050505050505050505050505050505050505050505050505050505050505),
            hex"78000000000000006400320064000000"
        );
    }

    function _nativeGoldenConfig() private pure returns (SolanaMandateV6.Config memory native) {
        native.program = 0xda075cb2ff5ec6817613de530c085e191675062a1ce4a10189ea49d29d739f06;
        native.spoke = 0x1ee39f01232b2e295e21e516f476e557768949820bc25b6f3b5466250070b0f1;
        native.usdcMint = 0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61;
        native.managerKey = 0x0f0248bf50f38b8fa1b2f34e5ee9070476e3c10c3e72eefd4e4ddc58e0a5a3a1;
        native.chainId = 1;
        bytes32 vault = 0xf33ef011782bb01b1cf6ea9095db6c03278a314b670e89eb33101bd25dcd9dd4;
        native.transport = SolanaMandateV6.Transport(
            0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d,
            0x81D40F21F12A8F0E3252Bccb954D722d4c464B64,
            5,
            0x7982cec8701aa4528f0d651030ecac78bb73226fe7646083d8d29db7d79ceeaa,
            vault,
            0xa65fc81d0fefa8860cb3b83f089b0224be8a6687b7ae49f594c0b9b4d7e93893,
            vault,
            50_000
        );
        native.assets = new SolanaMandateV6.Asset[](1);
        native.assets[0] = SolanaMandateV6.Asset(native.usdcMint, 0x06DcaCb276039C31D0c4d13c8D7b4D129B4E7253, false);
        native.venues = new SolanaMandateV6.Venue[](1);
        native.venues[0] = SolanaMandateV6.Venue(
            0x04b2acb11258cce3682c418ba872ff3df91102712f15af12b6be69b3435b0008,
            0,
            0xb3ca896fdd9e7319a26e06cdf9ad5fee4e23f249bb4067c89d5b602acd22e06c,
            native.usdcMint,
            0
        );
    }

    function testSwapPolicyBorshGoldenVectorCoversEveryField() public pure {
        bytes memory policyBytes = _swapPolicyBorsh();
        assertEq(policyBytes.length, 164);
        bytes32 swapHash = keccak256(policyBytes);
        assertEq(swapHash, 0x94cb3ff011a748f6413901cc90b64fa6cd56661a6176fb194e5b82ea355046dd);
        SolanaMandateV6.Config memory native = SolanaFixture.nativeConfig();
        bytes32 disabled = SolanaPolicyV6.nativePolicyHash(native);
        native.swapPolicyHash = swapHash;
        bytes32 enabled = SolanaPolicyV6.nativePolicyHash(native);
        assertNotEq(disabled, enabled);
        uint256[11] memory offsets = [uint256(0), 20, 52, 84, 116, 148, 156, 158, 160, 162, 163];
        for (uint256 index; index < offsets.length; ++index) {
            bytes memory changed = _swapPolicyBorsh();
            changed[offsets[index]] ^= bytes1(uint8(1));
            native.swapPolicyHash = keccak256(changed);
            assertNotEq(native.swapPolicyHash, swapHash);
            assertNotEq(SolanaPolicyV6.nativePolicyHash(native), enabled);
        }
    }

    function testNativeAndIdentityFreePolicyRustParityGoldenVectors() public pure {
        SolanaMandateV6.Config memory native = _nativeGoldenConfig();
        assertEq(SolanaMandateV6.hash(native), 0xeb92676e65ef6ae54d79f9da90f7004a3ebdacd462e96e26370d49220e315e54);
        assertEq(
            SolanaPolicyV6.nativePolicyHash(native), 0x13e19d911a00b433419f6eb322eb86d8497b0e0266ab586cba7ceeb116d7f912
        );
        assertEq(
            SolanaPolicyV6.hash(bytes32(uint256(10)), SolanaPolicyV6.nativePolicyHash(native)),
            0xa3db19c185e184401fbc0fa32291aa263f4659c29af71f08546c627562ae8d95
        );
        native.swapPolicyHash = keccak256(_swapPolicyBorsh());
        assertEq(SolanaMandateV6.hash(native), 0xb7f76f146f4b9b3d8f135b818649a86000ad2dafc980feda33bc4966236b3a10);
        assertEq(
            SolanaPolicyV6.nativePolicyHash(native), 0x6fd2b84a212e37c12f12daebe2d4b3f802b14a4ef1ffe5feb4aed5dfae943a88
        );
        assertEq(
            SolanaPolicyV6.hash(bytes32(uint256(10)), SolanaPolicyV6.nativePolicyHash(native)),
            0xbced46d907ecb4ee054c8ab234a0c4b63fff5146aec07c4b796e004a0f69fb0f
        );
    }

    function testRegistryPreservesOptionalSwapPolicyCommitment() public {
        SolanaMandateV6.Config memory native = SolanaFixture.nativeConfig();
        native.swapPolicyHash = keccak256(_swapPolicyBorsh());
        SolanaSpokeRegistryV6 registry = new SolanaSpokeRegistryV6(native);
        SolanaMandateV6.Config memory stored = registry.nativeConfig();
        assertEq(stored.swapPolicyHash, native.swapPolicyHash);
        assertEq(SolanaMandateV6.hash(stored), registry.nativeMandateHash());
    }

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
        native.swapPolicyHash = keccak256(_swapPolicyBorsh());
        bytes32 policy = SolanaPolicyV6.nativePolicyHash(native);
        bytes32 original = SolanaMandateV6.hash(native);
        assertEq(original, SolanaMandateV6.hash(native));
        native.spoke = bytes32(uint256(99));
        native.transport.mintRecipient = bytes32(uint256(98));
        native.transport.destinationCaller = bytes32(uint256(97));
        native.transport.remoteVaultAuthority = bytes32(uint256(96));
        assertEq(policy, SolanaPolicyV6.nativePolicyHash(native));
        native.managerKey = bytes32(uint256(201));
        assertNotEq(policy, SolanaPolicyV6.nativePolicyHash(native));
        native.managerKey = bytes32(uint256(200));
        native.transport.fastFeeCeiling += 1;
        assertNotEq(policy, SolanaPolicyV6.nativePolicyHash(native));
    }
}
