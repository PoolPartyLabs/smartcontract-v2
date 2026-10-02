// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {CoreBridgeVM, GuardianSignature} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {SpokeBCrossChainBase} from "./SpokeBCrossChainBase.sol";

/// @notice Wormhole Core stand-in that behaves like the real `Implementation.publishMessage`: checks the fee, uses the
///         emitter's sequence and only emits `LogMessagePublished` (8 gas per payload byte), without storing the
///         payload the way the fixture's recording mock does. Same storage layout as `MockWormholeCore` (slot 0 fee,
///         slot 1 per-emitter sequence) so it can be etched over it and continue its sequence.
contract LogOnlyWormholeCore {
    event LogMessagePublished(
        address indexed sender, uint64 sequence, uint32 nonce, bytes payload, uint8 consistencyLevel
    );

    uint256 public messageFee;
    mapping(address => uint64) public nextSequence;

    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        external
        payable
        returns (uint64 sequence)
    {
        require(msg.value == messageFee, "invalid fee");
        sequence = nextSequence[msg.sender]++;
        emit LogMessagePublished(msg.sender, sequence, nonce, payload, consistencyLevel);
    }
}

/// @notice spoke-b review fixture on top of core-b's real-contract fixture (real CoreVault + CoreVaultLogic, real
///         ValueReportReceiver over a Core Bridge stand-in, real Robinhood SpokeVault + SpokeCrossChainLib). Adds:
///         a log-only Wormhole Core on the spoke, cold-storage gas measurement helpers and the manager's and a
///         stranger's cheap ways to grow a report (dust sends home, dust positions, dust arrivals).
abstract contract SpokeBFixture is SpokeBCrossChainBase {
    bytes32 internal constant LOG_MESSAGE_PUBLISHED =
        keccak256("LogMessagePublished(address,uint64,uint32,bytes,uint8)");

    uint256 internal incomeNonce;

    function setUp() public virtual override {
        super.setUp();
        vm.etch(address(wormhole), address(new LogOnlyWormholeCore()).code);
        // Port to main (security review S-14): `sendToSpoke` reverts `SpokeNotReporting` until the receiver accepted a
        // report from the spoke, so the keeper delivers the new spoke's first (empty) report before any send.
        (bytes memory payload, uint64 seq) = _publishPayload();
        vm.prank(keeper);
        receiver.deliver(_vaa(payload, seq));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Report publication and delivery
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev `report()` on the spoke; returns the payload read from the Core's log, the Wormhole sequence and the gas
    ///      `report()` used with every slot of the spoke, its adapters and the Core cold.
    function _publishMeasured() internal returns (bytes memory payload, uint64 wormholeSequence, uint256 gasUsed) {
        vm.cool(address(spoke));
        vm.cool(address(spokeAdapter));
        vm.cool(address(wormhole));
        vm.recordLogs();
        uint256 g = gasleft();
        (, wormholeSequence) = spoke.report();
        gasUsed = g - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(wormhole) && logs[i].topics[0] == LOG_MESSAGE_PUBLISHED) {
                (,, payload,) = abi.decode(logs[i].data, (uint64, uint32, bytes, uint8));
            }
        }
        require(payload.length != 0, "no publication");
    }

    function _publishPayload() internal returns (bytes memory payload, uint64 wormholeSequence) {
        (payload, wormholeSequence,) = _publishMeasured();
    }

    function _vaa(bytes memory payload, uint64 wormholeSequence) internal view returns (bytes memory) {
        CoreBridgeVM memory vmm;
        vmm.version = 1;
        vmm.timestamp = uint32(block.timestamp);
        vmm.emitterChainId = WH_SPOKE;
        vmm.emitterAddress = bytes32(uint256(uint160(address(spoke))));
        vmm.sequence = wormholeSequence;
        vmm.consistencyLevel = 1;
        vmm.payload = payload;
        vmm.signatures = new GuardianSignature[](0);
        return abi.encode(vmm);
    }

    /// @dev Execution gas of `deliver` with the receiver's and the Core Vault's storage cold (the payload slots hold
    ///      the report stored in an earlier transaction). Excludes the 21,000 base and the calldata (see `_intrinsic`).
    function _deliverMeasured(bytes memory vaa) internal returns (uint256 gasUsed) {
        vm.cool(address(receiver));
        vm.cool(address(vault));
        vm.cool(address(coreBridge));
        vm.prank(keeper);
        uint256 g = gasleft();
        receiver.deliver(vaa);
        gasUsed = g - gasleft();
    }

    /// @dev `deliver` with an explicit gas budget, as a keeper's transaction capped at `budget` would run it.
    function _deliverWithGas(bytes memory vaa, uint256 budget) internal returns (bool ok) {
        vm.cool(address(receiver));
        vm.cool(address(vault));
        vm.cool(address(coreBridge));
        vm.prank(keeper);
        (ok,) = address(receiver).call{gas: budget}(abi.encodeCall(IValueReportReceiver.deliver, (vaa)));
    }

    /// @dev Transaction base cost plus EIP-2028 calldata cost of a `deliver(vaa)` transaction (Arbitrum's L1 data
    ///      component is on top and not counted here).
    function _intrinsic(bytes memory vaa) internal pure returns (uint256 gas) {
        bytes memory data = abi.encodeCall(IValueReportReceiver.deliver, (vaa));
        gas = 21_000;
        for (uint256 i; i < data.length; ++i) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    /// @dev Gas of one deposit of `amount` by `who` with the Core Vault's and the receiver's storage cold.
    function _depositMeasured(address who, uint256 amount) internal returns (uint256 gasUsed) {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(vault), amount);
        vm.cool(address(receiver));
        vm.cool(address(vault));
        vm.prank(who);
        uint256 g = gasleft();
        vault.deposit(amount, 0);
        gasUsed = g - gasleft();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Ways to grow a report
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Manager: `n` sends home of one base unit each (fee 0, so `_checkQuote` accepts any `maxBridgeFeeBps`).
    function _dustSendsHome(uint256 n, TransferKind kind) internal {
        vm.startPrank(manager);
        for (uint256 i; i < n; ++i) {
            spoke.sendToHub(1, kind, 0);
        }
        vm.stopPrank();
    }

    /// @dev Manager: `n` positions of one USDG base unit each in the Mandate pool.
    function _dustPositions(uint256 n) internal {
        vm.startPrank(manager);
        for (uint256 i; i < n; ++i) {
            spoke.openPosition(address(spokeAdapter), SPOKE_POOL, 0, 1, "");
        }
        vm.stopPrank();
    }

    /// @dev Stranger: `n` self-relayed Across fills of 1 USDG each with fresh ids (listed in the 256-id window).
    function _dustArrivals(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _dustArrival();
        }
    }

    /// @dev An Income-kind fill to the spoke (a stranger's, or income the fund received), crediting the collected bucket.
    function _incomeArrival(uint256 amount) internal {
        usdg.mint(address(spokeAcross), amount);
        spokeAcross.fill(
            address(spoke),
            address(usdg),
            amount,
            TransitMessage.encode(FUND_ID, HUB, keccak256(abi.encode("income", ++incomeNonce)), TransferKind.Income)
        );
    }
}
