// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreBridgeVM, GuardianSignature} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {OrderCodec} from "../../src/libraries/OrderCodec.sol";
import {OrderVerifier, OrderVaaHead, IOrderVaaParser} from "../../src/libraries/OrderVerifier.sol";
import {ICoreVault} from "../../src/interfaces/ICoreVault.sol";
import {MockOrderCore} from "../mocks/wormhole/MockOrderCore.sol";
import {OrderPublisherHarness} from "../mocks/wormhole/OrderCodecHarness.sol";
import {OrderReceiverHarness, OrderVerifierHarness} from "../mocks/wormhole/OrderVerifierHarness.sol";

/// @notice OrderVerifier: the Spoke Vault's checks on an order VAA (DEC-111, DEC-120 item 2, DEC-139, DEC-093).
/// @dev One mock Core plays both chains: what the Core Vault publishes is turned into the VAA a guardian quorum would
///      sign with the Hub's Wormhole chain id (23) as the emitter chain.
contract OrderVerifierTest is Test {
    uint16 internal constant WH_ARBITRUM = 23;
    uint16 internal constant WH_ROBINHOOD = 72;
    bytes32 internal constant FUND = keccak256("pool-party/fund/1");

    MockOrderCore internal core;
    OrderPublisherHarness internal coreVault;
    OrderReceiverHarness internal spokeVault;
    OrderVerifierHarness internal verifier;

    function setUp() public {
        core = new MockOrderCore(WH_ARBITRUM);
        coreVault = new OrderPublisherHarness();
        spokeVault = new OrderReceiverHarness(address(core), WH_ARBITRUM, address(coreVault), FUND);
        verifier = new OrderVerifierHarness();
    }

    function _unwind(uint32 attempt) internal pure returns (OrderCodec.Order memory o) {
        o.kind = OrderCodec.UNWIND;
        o.fundId = FUND;
        o.requestId = keccak256(abi.encode(address(0xA11CE), uint256(1)));
        o.attempt = attempt;
        o.fracNum = 1457;
        o.fracDen = 10_000;
        o.payoutMode = uint8(ICoreVault.PayoutMode.Standard);
    }

    /// @dev The Core Vault publishes `o`; returns the VAA of that message.
    function _publish(OrderCodec.Order memory o) internal returns (bytes memory vaa, uint64 sequence) {
        sequence = coreVault.publish(address(core), o);
        vaa = core.vaaOf(core.publishedCount() - 1);
    }

    function _coreVaultEmitter() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(coreVault))));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Accepted
    // -----------------------------------------------------------------------------------------------------------------

    function test_DEC120_anyoneDeliversTheCoreVaultsOrder() public {
        OrderCodec.Order memory o = _unwind(1);
        (bytes memory vaa, uint64 published) = _publish(o);
        assertEq(published, 0);

        vm.expectEmit(address(spokeVault));
        emit OrderReceiverHarness.OrderExecuted(OrderCodec.UNWIND, OrderCodec.orderId(o), 0);
        vm.prank(makeAddr("anyone")); // DEC-120 item 2: permissionless delivery
        (OrderCodec.Order memory d, uint64 sequence) = spokeVault.execute(vaa);

        assertEq(keccak256(abi.encode(d)), keccak256(abi.encode(o)));
        assertEq(sequence, 0, "the first order of an emitter has sequence 0 and is accepted");
        assertEq(spokeVault.minSequence(), 1);
        assertEq(spokeVault.executedCount(), 1);
    }

    function test_DEC093_ordersAreAcceptedInSequenceAcrossKinds() public {
        (bytes memory first,) = _publish(_unwind(1));
        OrderCodec.Order memory collect;
        collect.kind = OrderCodec.COLLECT;
        collect.fundId = FUND;
        collect.requestId = bytes32(uint256(1));
        (bytes memory second,) = _publish(collect);
        OrderCodec.Order memory close;
        close.kind = OrderCodec.CLOSE;
        close.fundId = FUND;
        (bytes memory third,) = _publish(close);

        spokeVault.execute(first);
        spokeVault.execute(second);
        (OrderCodec.Order memory d, uint64 sequence) = spokeVault.execute(third);
        assertEq(sequence, 2);
        assertEq(d.kind, OrderCodec.CLOSE);
        assertEq(d.fracNum, 1, "DEC-147: a closure is everything");
        assertEq(d.fracDen, 1);
        assertEq(spokeVault.executedCount(), 3);
    }

    function test_DEC093_aGapInSequencesIsAccepted() public {
        _publish(_unwind(1)); // sequence 0, never delivered to this spoke
        (bytes memory vaa,) = _publish(_unwind(2)); // sequence 1
        (, uint64 sequence) = spokeVault.execute(vaa);
        assertEq(sequence, 1);
        assertEq(spokeVault.minSequence(), 2);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Rejected, one check at a time
    // -----------------------------------------------------------------------------------------------------------------

    function test_DEC086_rejectsAVaaTheCoreRefuses() public {
        (bytes memory vaa,) = _publish(_unwind(1));
        core.setInvalid("VM signature invalid");
        vm.expectRevert(abi.encodeWithSelector(OrderVerifier.InvalidOrderVaa.selector, "VM signature invalid"));
        spokeVault.execute(vaa);
        assertEq(spokeVault.minSequence(), 0);
    }

    function test_DEC120_rejectsAnotherEmitterChain() public {
        bytes memory payload = OrderCodec.encode(_unwind(1));
        uint16[3] memory chains = [WH_ROBINHOOD, 2, 0];
        for (uint256 i; i < chains.length; ++i) {
            // the Core Vault's address on another chain (the CREATE3 address is the same everywhere, DEC-054)
            bytes memory vaa = core.craft(chains[i], _coreVaultEmitter(), 0, 200, payload);
            vm.expectRevert(abi.encodeWithSelector(OrderVerifier.OrderEmitterChainMismatch.selector, chains[i]));
            spokeVault.execute(vaa);
        }
    }

    function test_DEC111_rejectsAnotherEmitter() public {
        OrderPublisherHarness stranger = new OrderPublisherHarness();
        stranger.publish(address(core), _unwind(1));
        bytes memory vaa = core.vaaOf(0);
        bytes32 strangerEmitter = bytes32(uint256(uint160(address(stranger))));
        vm.expectRevert(abi.encodeWithSelector(OrderVerifier.OrderEmitterMismatch.selector, strangerEmitter));
        spokeVault.execute(vaa);
    }

    function test_DEC111_rejectsTheCoreVaultAddressWithDirtyHighBytes() public {
        bytes32 dirty = _coreVaultEmitter() | bytes32(uint256(1) << 200);
        bytes memory vaa = core.craft(WH_ARBITRUM, dirty, 0, 200, OrderCodec.encode(_unwind(1)));
        vm.expectRevert(abi.encodeWithSelector(OrderVerifier.OrderEmitterMismatch.selector, dirty));
        spokeVault.execute(vaa);
    }

    function test_DEC093_rejectsAReplay() public {
        (bytes memory vaa,) = _publish(_unwind(1));
        spokeVault.execute(vaa);
        vm.expectRevert(abi.encodeWithSelector(OrderVerifier.OrderSequenceTooLow.selector, 1, 0));
        spokeVault.execute(vaa);
        assertEq(spokeVault.executedCount(), 1);
    }

    /// @dev The register's rule (DEC-093) drops an older order delivered after a newer one; the request's retry
    ///      (DEC-151) republishes it.
    function test_DEC093_rejectsAnOlderOrderDeliveredAfterANewerOne() public {
        (bytes memory older,) = _publish(_unwind(1)); // sequence 0
        (bytes memory newer,) = _publish(_unwind(2)); // sequence 1
        spokeVault.execute(newer);
        vm.expectRevert(abi.encodeWithSelector(OrderVerifier.OrderSequenceTooLow.selector, 2, 0));
        spokeVault.execute(older);
    }

    function test_DEC111_rejectsAnotherFundsOrder() public {
        OrderCodec.Order memory o = _unwind(1);
        o.fundId = keccak256("pool-party/fund/2");
        (bytes memory vaa,) = _publish(o);
        vm.expectRevert(abi.encodeWithSelector(OrderVerifier.OrderFundMismatch.selector, o.fundId));
        spokeVault.execute(vaa);
    }

    function test_rejectsAPayloadThatIsNotAnOrder() public {
        // a signed message from the Core Vault in an unknown layout (e.g. a future version)
        bytes memory vaa = core.craft(WH_ARBITRUM, _coreVaultEmitter(), 0, 200, abi.encode(uint256(2), _unwind(1)));
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.UnsupportedOrderVersion.selector, 2));
        spokeVault.execute(vaa);
    }

    function test_DEC137_rejectsASignedUnwindAboveEverything() public {
        OrderCodec.Order memory o = _unwind(1);
        o.fracNum = o.fracDen + 1;
        bytes memory vaa = core.craft(WH_ARBITRUM, _coreVaultEmitter(), 0, 200, abi.encode(OrderCodec.VERSION, o));
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.InvalidOrderFraction.selector, o.fracNum, o.fracDen));
        spokeVault.execute(vaa);
    }

    /// @dev The verifier reads only the head of the Core's result (`OrderVaaHead`); a full result with a guardian
    ///      signature array, a guardian set index and a hash after the payload decodes to the same head.
    function test_headDecodeReadsTheSameFieldsAsTheFullResult() public {
        OrderCodec.Order memory o = _unwind(1);
        CoreBridgeVM memory full;
        full.version = 1;
        full.timestamp = uint32(block.timestamp);
        full.nonce = 7;
        full.emitterChainId = WH_ARBITRUM;
        full.emitterAddress = _coreVaultEmitter();
        full.sequence = 41;
        full.consistencyLevel = 200;
        full.payload = OrderCodec.encode(o);
        full.guardianSetIndex = 4;
        full.signatures = new GuardianSignature[](13);
        for (uint256 i; i < 13; ++i) {
            full.signatures[i] = GuardianSignature(keccak256(abi.encode(i)), keccak256(abi.encode(i + 1)), 27, uint8(i));
        }
        full.hash = keccak256("hash");
        bytes memory vaa = abi.encode(full);

        (OrderVaaHead memory head, bool valid,) = IOrderVaaParser(address(core)).parseAndVerifyVM(vaa);
        assertTrue(valid);
        assertEq(head.version, full.version);
        assertEq(head.timestamp, full.timestamp);
        assertEq(head.nonce, full.nonce);
        assertEq(head.emitterChainId, full.emitterChainId);
        assertEq(head.emitterAddress, full.emitterAddress);
        assertEq(head.sequence, full.sequence);
        assertEq(head.consistencyLevel, full.consistencyLevel);
        assertEq(head.payload, full.payload);

        (OrderCodec.Order memory d, uint64 sequence) = spokeVault.execute(vaa);
        assertEq(sequence, 41);
        assertEq(keccak256(abi.encode(d)), keccak256(abi.encode(o)));
    }

    /// @dev The Core Vault is the only accepted emitter and fixes the level; the verifier does not read it.
    function test_DEC120_consistencyLevelIsNotAnAcceptanceRule() public {
        bytes memory vaa = core.craft(WH_ARBITRUM, _coreVaultEmitter(), 0, 1, OrderCodec.encode(_unwind(1)));
        (, uint64 sequence) = spokeVault.execute(vaa);
        assertEq(sequence, 0);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------------------------------------------------------------

    function testFuzz_DEC093_acceptsASequenceIffAtLeastTheMinimum(uint64 minSequence, uint64 sequence) public {
        bytes memory vaa = core.craft(WH_ARBITRUM, _coreVaultEmitter(), sequence, 200, OrderCodec.encode(_unwind(1)));
        if (sequence < minSequence) {
            vm.expectRevert(abi.encodeWithSelector(OrderVerifier.OrderSequenceTooLow.selector, minSequence, sequence));
            verifier.verify(address(core), vaa, WH_ARBITRUM, address(coreVault), minSequence, FUND);
        } else {
            (, uint64 accepted) =
                verifier.verify(address(core), vaa, WH_ARBITRUM, address(coreVault), minSequence, FUND);
            assertEq(accepted, sequence);
        }
    }

    function testFuzz_DEC111_onlyTheCoreVaultOnTheHubChainIsAccepted(uint16 chain, bytes32 emitter) public {
        vm.assume(chain != WH_ARBITRUM || emitter != _coreVaultEmitter());
        bytes memory vaa = core.craft(chain, emitter, 0, 200, OrderCodec.encode(_unwind(1)));
        vm.expectRevert();
        verifier.verify(address(core), vaa, WH_ARBITRUM, address(coreVault), 0, FUND);
    }
}
