// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {VaaLib, VaaBody} from "wormhole-sdk/libraries/VaaLib.sol";
import {CoreBridgeLib} from "wormhole-sdk/libraries/CoreBridge.sol";
import {toUniversalAddress} from "wormhole-sdk/Utils.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {OrderVerifier} from "../../../src/libraries/OrderVerifier.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {OrderPublisherHarness} from "../../mocks/wormhole/OrderCodecHarness.sol";
import {OrderReceiverHarness, OrderVerifierHarness} from "../../mocks/wormhole/OrderVerifierHarness.sol";

/// @notice The Hub-to-spoke order channel on both live chains (DEC-111, DEC-120 items 1-2, DEC-139, FV-18 path).
///         A stand-in Core Vault publishes on the real Arbitrum One Wormhole Core with instant consistency; the
///         message is read back from the Core's log, signed by a test guardian set written into the real Robinhood
///         Chain Core (`vm.store`, the SDK's WormholeOverride, as in `ValueReportReceiverFork.t.sol`) and verified there
///         through `OrderVerifier` by a stand-in Spoke Vault. Same-size guardian set and quorum as the live one, so the
///         verification gas is realistic.
/// @dev Fresh pins at run time (`ARBITRUM_FORK_BLOCK`, `ROBINHOOD_FORK_BLOCK`); no block-specific constants.
contract OrderChannelForkTest is Test {
    using AdvancedWormholeOverride for ICoreBridge;

    address internal constant ARB_WORMHOLE_CORE = 0xa5f208e072434bC67592E4C49C1B991BA79BCA46;
    address internal constant RH_WORMHOLE_CORE = 0x141fBa8AD5D61bdaB45A047cF60b5Ad9784987FB;
    uint16 internal constant WH_ARBITRUM = 23;
    uint16 internal constant WH_ROBINHOOD = 72;
    bytes32 internal constant FUND = keccak256("pool-party/fund/1");

    uint256 internal arbitrumFork;
    uint256 internal robinhoodFork;

    /// @dev On Arbitrum: the fund's Core Vault (emitter). On Robinhood: the fund's Spoke Vault and a bare verifier.
    OrderPublisherHarness internal coreVault;
    OrderReceiverHarness internal spokeVault;
    OrderVerifierHarness internal verifier;

    function setUp() public {
        arbitrumFork = vm.createFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        robinhoodFork = vm.createFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));

        vm.selectFork(arbitrumFork);
        assertEq(ICoreBridge(ARB_WORMHOLE_CORE).chainId(), WH_ARBITRUM);
        coreVault = new OrderPublisherHarness();

        vm.selectFork(robinhoodFork);
        ICoreBridge rhCore = ICoreBridge(RH_WORMHOLE_CORE);
        assertEq(rhCore.chainId(), WH_ROBINHOOD);
        rhCore.setUpOverride();
        spokeVault = new OrderReceiverHarness(RH_WORMHOLE_CORE, WH_ARBITRUM, address(coreVault), FUND);
        verifier = new OrderVerifierHarness();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    function _unwind(bytes32 fundId, uint32 attempt) internal pure returns (OrderCodec.Order memory o) {
        o.kind = OrderCodec.UNWIND;
        o.fundId = fundId;
        o.requestId = keccak256(abi.encode(address(0xA11CE), uint256(1)));
        o.attempt = attempt;
        o.fracNum = 1457; // the DEC-137 example: 14.57% of every position, 2% margin included
        o.fracDen = 10_000;
        o.maxLossBps = 150;
        o.payoutMode = uint8(ICoreVault.PayoutMode.Standard);
    }

    /// @dev Publishes `o` from `emitter` on the selected fork's Core, paying that Core's fee, and returns the message
    ///      as the Core logged it.
    function _publish(address core, OrderPublisherHarness emitter, OrderCodec.Order memory o)
        internal
        returns (VaaBody memory pm, uint256 gasUsed)
    {
        uint256 fee = ICoreBridge(core).messageFee();
        vm.recordLogs();
        uint256 gasBefore = gasleft();
        emitter.publish{value: fee}(core, o);
        gasUsed = gasBefore - gasleft();
        VaaBody[] memory published = ICoreBridge(core).fetchPublishedMessages(vm.getRecordedLogs());
        assertEq(published.length, 1);
        pm = published[0];
    }

    function _publishOnArbitrum(OrderPublisherHarness emitter, OrderCodec.Order memory o)
        internal
        returns (VaaBody memory pm)
    {
        vm.selectFork(arbitrumFork);
        (pm,) = _publish(ARB_WORMHOLE_CORE, emitter, o);
    }

    /// @dev The VAA the guardian quorum signs for `pm`, built on the Robinhood fork (whose Core holds the test set).
    function _signOnRobinhood(VaaBody memory pm) internal returns (bytes memory) {
        vm.selectFork(robinhoodFork);
        return VaaLib.encode(ICoreBridge(RH_WORMHOLE_CORE).sign(pm));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // The channel
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-120 items 1-2: published on Arbitrum with instant consistency, the Core Vault as emitter; delivered by
    ///      anyone on Robinhood and accepted there. Gas and the message fee of both ends are logged (FV-18 path).
    function test_DEC120_forkOrderPublishedOnArbitrumIsVerifiedOnRobinhood() public {
        vm.selectFork(arbitrumFork);
        ICoreBridge arbCore = ICoreBridge(ARB_WORMHOLE_CORE);
        uint64 expected = arbCore.nextSequence(address(coreVault));
        uint256 arbFee = arbCore.messageFee();
        OrderCodec.Order memory o = _unwind(FUND, 1);
        (VaaBody memory pm, uint256 publishGas) = _publish(ARB_WORMHOLE_CORE, coreVault, o);
        console2.log("Arbitrum Core messageFee (wei):", arbFee);
        console2.log("publish gas (entry + OrderCodec.publish + live Arbitrum Core):", publishGas);

        assertEq(pm.envelope.emitterChainId, WH_ARBITRUM, "DEC-120: the Hub's Wormhole chain");
        assertEq(pm.envelope.emitterAddress, toUniversalAddress(address(coreVault)), "DEC-111: Core Vault emits");
        assertEq(pm.envelope.sequence, expected);
        assertEq(pm.envelope.consistencyLevel, OrderCodec.CONSISTENCY_INSTANT, "DEC-120 item 1: instant");
        assertEq(pm.envelope.nonce, OrderCodec.NONCE);
        assertEq(pm.payload, OrderCodec.encode(o));
        assertEq(arbCore.nextSequence(address(coreVault)), expected + 1);

        bytes memory vaa = _signOnRobinhood(pm);
        console2.log("Robinhood Core messageFee (wei):", ICoreBridge(RH_WORMHOLE_CORE).messageFee());
        console2.log("order VAA bytes (live-size guardian quorum):", vaa.length);

        uint256 gasBefore = gasleft();
        verifier.verify(RH_WORMHOLE_CORE, vaa, WH_ARBITRUM, address(coreVault), 0, FUND);
        console2.log("OrderVerifier.verify gas (live Robinhood Core, quorum signatures):", gasBefore - gasleft());

        vm.prank(makeAddr("anyone")); // DEC-120 item 2: permissionless delivery
        gasBefore = gasleft();
        (OrderCodec.Order memory d, uint64 sequence) = spokeVault.execute(vaa);
        console2.log("execute gas (verify + three first-time stores):", gasBefore - gasleft());

        assertEq(keccak256(abi.encode(d)), keccak256(abi.encode(o)), "the order arrives as published");
        assertEq(sequence, expected);
        assertEq(spokeVault.minSequence(), expected + 1);
        assertEq(spokeVault.lastOrderId(), OrderCodec.orderId(o));
    }

    /// @dev The Core requires exactly its message fee; the publisher forwards the entry's `msg.value`.
    function test_DEC120_forkPublisherPaysANonZeroMessageFee() public {
        vm.selectFork(arbitrumFork);
        ICoreBridge arbCore = ICoreBridge(ARB_WORMHOLE_CORE);
        arbCore.setMessageFee(0.0001 ether);
        uint256 coreBalance = ARB_WORMHOLE_CORE.balance;
        OrderCodec.Order memory o = _unwind(FUND, 1);

        vm.expectRevert(bytes("invalid fee"));
        coreVault.publish(ARB_WORMHOLE_CORE, o);

        vm.deal(address(this), 1 ether);
        vm.recordLogs();
        coreVault.publish{value: 0.0001 ether}(ARB_WORMHOLE_CORE, o);
        assertEq(arbCore.fetchPublishedMessages(vm.getRecordedLogs()).length, 1);
        assertEq(ARB_WORMHOLE_CORE.balance, coreBalance + 0.0001 ether);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Rejections on the live Robinhood Core
    // -----------------------------------------------------------------------------------------------------------------

    function test_DEC093_forkRejectsAReplay() public {
        bytes memory vaa = _signOnRobinhood(_publishOnArbitrum(coreVault, _unwind(FUND, 1)));
        (, uint64 sequence) = spokeVault.execute(vaa);
        vm.expectRevert(abi.encodeWithSelector(OrderVerifier.OrderSequenceTooLow.selector, sequence + 1, sequence));
        spokeVault.execute(vaa);
    }

    /// @dev D-13: the register's rule; the older order's request is served by its retry (DEC-151).
    function test_DEC093_forkRejectsAnOlderOrderDeliveredAfterANewerOne() public {
        VaaBody memory first = _publishOnArbitrum(coreVault, _unwind(FUND, 1));
        VaaBody memory second = _publishOnArbitrum(coreVault, _unwind(FUND, 2));
        assertEq(second.envelope.sequence, first.envelope.sequence + 1);
        bytes memory older = _signOnRobinhood(first);
        bytes memory newer = _signOnRobinhood(second);

        spokeVault.execute(newer);
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderVerifier.OrderSequenceTooLow.selector, second.envelope.sequence + 1, first.envelope.sequence
            )
        );
        spokeVault.execute(older);
    }

    /// @dev DEC-054 puts the Core Vault at the same address on every chain; only the Hub chain's emitter counts. A
    ///      contract at that address on Robinhood publishes on the live Robinhood Core.
    function test_DEC120_forkRejectsTheCoreVaultAddressOnAnotherChain() public {
        vm.selectFork(robinhoodFork);
        OrderPublisherHarness twin = new OrderPublisherHarness();
        vm.etch(address(coreVault), address(twin).code);
        (VaaBody memory pm,) = _publish(RH_WORMHOLE_CORE, OrderPublisherHarness(address(coreVault)), _unwind(FUND, 1));
        assertEq(pm.envelope.emitterChainId, WH_ROBINHOOD);
        assertEq(pm.envelope.emitterAddress, toUniversalAddress(address(coreVault)));
        bytes memory vaa = _signOnRobinhood(pm);

        vm.expectRevert(abi.encodeWithSelector(OrderVerifier.OrderEmitterChainMismatch.selector, WH_ROBINHOOD));
        spokeVault.execute(vaa);
    }

    function test_DEC111_forkRejectsAnotherEmitterOnTheHub() public {
        vm.selectFork(arbitrumFork);
        OrderPublisherHarness stranger = new OrderPublisherHarness();
        bytes memory vaa = _signOnRobinhood(_publishOnArbitrum(stranger, _unwind(FUND, 1)));

        vm.expectRevert(
            abi.encodeWithSelector(OrderVerifier.OrderEmitterMismatch.selector, toUniversalAddress(address(stranger)))
        );
        spokeVault.execute(vaa);
    }

    function test_DEC111_forkRejectsAnotherFundsOrder() public {
        bytes32 otherFund = keccak256("pool-party/fund/2");
        bytes memory vaa = _signOnRobinhood(_publishOnArbitrum(coreVault, _unwind(otherFund, 1)));

        vm.expectRevert(abi.encodeWithSelector(OrderVerifier.OrderFundMismatch.selector, otherFund));
        spokeVault.execute(vaa);
    }

    function test_DEC086_forkRejectsATamperedVaa() public {
        bytes memory vaa = _signOnRobinhood(_publishOnArbitrum(coreVault, _unwind(FUND, 1)));
        vaa[vaa.length - 1] = bytes1(uint8(vaa[vaa.length - 1]) ^ 0x01); // one payload bit after signing

        vm.expectRevert(abi.encodeWithSelector(OrderVerifier.InvalidOrderVaa.selector, "VM signature invalid"));
        spokeVault.execute(vaa);
    }

    function test_DEC086_forkRejectsAVaaBelowTheGuardianQuorum() public {
        VaaBody memory pm = _publishOnArbitrum(coreVault, _unwind(FUND, 1));
        vm.selectFork(robinhoodFork);
        ICoreBridge rhCore = ICoreBridge(RH_WORMHOLE_CORE);
        uint256 quorum = CoreBridgeLib.minSigsForQuorum(rhCore.getGuardianPrivateKeysLength());
        bytes memory indices = new bytes(quorum - 1);
        for (uint256 i; i < indices.length; ++i) {
            indices[i] = bytes1(uint8(i));
        }
        bytes memory vaa = VaaLib.encode(rhCore.sign(pm, indices));

        vm.expectRevert(abi.encodeWithSelector(OrderVerifier.InvalidOrderVaa.selector, "no quorum"));
        spokeVault.execute(vaa);
    }
}
