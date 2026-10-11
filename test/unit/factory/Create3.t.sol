// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Create3} from "../../../src/factory/Create3.sol";
import {CodeStore} from "../../../src/factory/CodeStore.sol";
import {Create3Deployer} from "../../../src/factory/Create3Deployer.sol";
import {
    Create3Harness,
    Create3Child,
    Create3OtherChild,
    Create3RevertingChild,
    Create3Parent
} from "../../mocks/factory/Create3Harness.sol";

/// @notice CREATE3 determinism (DEC-053, DEC-054: hub and spoke addresses known to each other at creation) and the
///         code store the factory reads creation code from.
contract Create3Test is Test {
    Create3Harness internal harness;

    function setUp() public {
        harness = new Create3Harness();
    }

    function _child(uint256 tag) internal pure returns (bytes memory) {
        return abi.encodePacked(type(Create3Child).creationCode, abi.encode(tag));
    }

    function test_DEC054_proxyInitCodeHashIsTheConstant() public pure {
        assertEq(Create3.PROXY_INITCODE_HASH, keccak256(Create3.PROXY_INITCODE));
        assertEq(Create3.PROXY_INITCODE.length, 30);
    }

    function test_DEC054_deploysAtThePredictedAddress() public {
        bytes32 salt = keccak256("salt");
        address predicted = harness.addressOf(salt);
        assertEq(predicted.code.length, 0);
        address deployed = harness.deploy(salt, _child(7));
        assertEq(deployed, predicted);
        assertEq(Create3Child(deployed).tag(), 7);
    }

    /// @dev The property the Mandate relies on: the address is fixed before the creation code is known.
    function test_DEC054_addressIsIndependentOfTheInitCode() public {
        bytes32 salt = keccak256("same salt");
        address predicted = harness.addressOf(salt);
        uint256 snapshot = vm.snapshotState();

        address a = harness.deploy(salt, _child(1));
        vm.revertToState(snapshot);
        address b = harness.deploy(salt, _child(2));
        vm.revertToState(snapshot);
        address c = harness.deploy(salt, type(Create3OtherChild).creationCode);

        assertEq(a, predicted);
        assertEq(b, predicted);
        assertEq(c, predicted);
        assertEq(Create3OtherChild(c).kind(), "other");
    }

    function testFuzz_DEC054_addressIsIndependentOfTheInitCode(bytes32 salt, uint256 tagA, uint256 tagB) public {
        address predicted = harness.addressOf(salt);
        uint256 snapshot = vm.snapshotState();
        assertEq(harness.deploy(salt, _child(tagA)), predicted);
        vm.revertToState(snapshot);
        assertEq(harness.deploy(salt, _child(tagB)), predicted);
    }

    function test_DEC054_addressDependsOnDeployerAndSalt() public {
        Create3Harness other = new Create3Harness();
        bytes32 salt = keccak256("salt");
        assertTrue(harness.addressOf(salt) != other.addressOf(salt), "deployer");
        assertTrue(harness.addressOf(salt) != harness.addressOf(keccak256("other salt")), "salt");
    }

    function test_DEC054_addressMatchesTheCanonicalFormula() public view {
        bytes32 salt = keccak256("formula");
        address proxy = vm.computeCreate2Address(salt, Create3.PROXY_INITCODE_HASH, address(harness));
        assertEq(harness.addressOf(salt), vm.computeCreateAddress(proxy, 1));
    }

    function test_DEC054_childSeesTheProxyAsCreator() public {
        bytes32 salt = keccak256("creator");
        address deployed = harness.deploy(salt, _child(1));
        address proxy = vm.computeCreate2Address(salt, Create3.PROXY_INITCODE_HASH, address(harness));
        assertEq(Create3Child(deployed).creator(), proxy);
    }

    function test_DEC054_saltCannotBeReused() public {
        bytes32 salt = keccak256("once");
        harness.deploy(salt, _child(1));
        vm.expectRevert(abi.encodeWithSelector(Create3.SaltAlreadyUsed.selector, salt));
        harness.deploy(salt, _child(2));
    }

    /// @dev DEC-066: a constructor revert (the Across adapter's FillDeadlineBufferTooShort) surfaces as the reason.
    function test_DEC066_constructorRevertBubblesUp() public {
        vm.expectRevert(abi.encodeWithSelector(Create3RevertingChild.ConstructorRefused.selector, 42));
        harness.deploy(keccak256("reverts"), type(Create3RevertingChild).creationCode);
    }

    function test_DEC054_emptyRuntimeRefused() public {
        bytes32 salt = keccak256("empty");
        vm.expectRevert(abi.encodeWithSelector(Create3.DeploymentWithoutCode.selector, salt));
        harness.deploy(salt, hex"00");
    }

    /// @dev Ruling 2026-09-29: the factory predicts the ShareToken (nonce 1) and ManagerFeeVault (nonce 2) the Core
    ///      Vault creates in its constructor.
    function test_DEC054_createAddressOfConstructorChildren() public {
        Create3Parent parent = Create3Parent(harness.deploy(keccak256("parent"), type(Create3Parent).creationCode));
        assertEq(parent.first(), harness.createAddress(address(parent), 1));
        assertEq(parent.second(), harness.createAddress(address(parent), 2));
        assertEq(harness.createAddress(address(parent), 1), vm.computeCreateAddress(address(parent), 1));
    }

    function test_DEC054_createAddressRejectsMultiByteNonces() public {
        vm.expectRevert(abi.encodeWithSelector(Create3.NonceOutOfRange.selector, 0));
        harness.createAddress(address(this), 0);
        vm.expectRevert(abi.encodeWithSelector(Create3.NonceOutOfRange.selector, 128));
        harness.createAddress(address(this), 128);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Create3Deployer: one factory address on every chain, per operator
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC054_deployerBindsTheSaltToTheCaller() public {
        Create3Deployer deployer = new Create3Deployer();
        address operator = makeAddr("operator");
        address stranger = makeAddr("stranger");
        bytes32 salt = keccak256("factory");
        address predicted = deployer.addressOf(operator, salt);
        assertTrue(predicted != deployer.addressOf(stranger, salt));

        // Constructor arguments differ per chain; the address does not.
        uint256 snapshot = vm.snapshotState();
        vm.prank(operator);
        assertEq(deployer.deploy(salt, _child(42_161)), predicted);
        vm.revertToState(snapshot);
        vm.prank(operator);
        assertEq(deployer.deploy(salt, _child(4663)), predicted);
        assertEq(Create3Child(predicted).tag(), 4663);

        // A stranger using the same salt lands elsewhere.
        vm.prank(stranger);
        assertTrue(deployer.deploy(salt, _child(1)) != predicted);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // CodeStore
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC058_codeStoreRoundTripsAcrossChunks() public {
        bytes memory data = new bytes(CodeStore.MAX_CHUNK * 2 + 17);
        for (uint256 i; i < data.length; ++i) {
            data[i] = bytes1(uint8(uint256(keccak256(abi.encode(i)))));
        }
        address[] memory chunks = harness.write(data);
        assertEq(chunks.length, 3);
        assertEq(chunks[0].code.length, CodeStore.MAX_CHUNK + 1);
        for (uint256 index; index < chunks.length; ++index) {
            assertGe(24_576 - chunks[index].code.length, 1000);
        }
        assertEq(chunks[2].code.length, 18);
        assertEq(uint8(chunks[0].code[0]), 0, "leading STOP");
        assertEq(keccak256(harness.read(chunks)), keccak256(data));
    }

    function testFuzz_DEC058_codeStoreRoundTrips(bytes memory data) public {
        vm.assume(data.length != 0);
        assertEq(keccak256(harness.read(harness.write(data))), keccak256(data));
    }

    /// @dev A data chunk is not callable: its runtime starts with STOP.
    function test_DEC058_codeStoreChunkIsInert() public {
        address[] memory chunks = harness.write(hex"deadbeef");
        (bool ok, bytes memory ret) = chunks[0].call(hex"12345678");
        assertTrue(ok);
        assertEq(ret.length, 0);
        assertEq(keccak256(harness.read(chunks)), keccak256(hex"deadbeef"));
    }

    function test_DEC058_codeStoreRejectsEmptyInputAndEmptyChunks() public {
        vm.expectRevert(CodeStore.EmptyCode.selector);
        harness.write("");
        address[] memory chunks = new address[](1);
        chunks[0] = makeAddr("no code");
        vm.expectRevert(abi.encodeWithSelector(CodeStore.EmptyChunk.selector, chunks[0]));
        harness.read(chunks);
    }
}
