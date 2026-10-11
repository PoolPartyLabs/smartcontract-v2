// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {MockAcrossSpokePool} from "./MockAcrossSpokePool.sol";

/// @notice IBridgeAdapter that builds an Across `depositV3` call against a MockAcrossSpokePool, with knobs to
///         misbehave (wrong target, wrong amount to arrive, failing `noteExpiry`).
/// @dev The amount to arrive is the adapter's, as DEC-162 requires, in this order: when `bridgeData` is a single word,
///      that word (a stand-in for a quote the adapter verifies itself; the vault never reads `bridgeData`); else, when
///      a test wrote `NEXT_ARRIVE_SLOT` with `vm.store` (value plus one), that value, for the next send only (the Spoke
///      Vault's send home passes no `bridgeData`, so vault tests fix the amount there); else `inputAmount - fee`, with
///      a settable flat `fee`, 0 by default.
contract MockBridgeAdapter is IBridgeAdapter {
    address public immutable target;
    address public vault;
    bool public paused;
    bool public deprecated;
    address public badTarget;
    uint256 public arriveDelta;
    uint256 public fee;
    bool public noteExpiryReverts;

    /// @notice Times `noteExpiry` was called for each transit reference.
    mapping(bytes32 transitRef => uint256) public expiryNotes;
    bytes32 public lastExpiryRef;

    error NoteExpiryRefused(bytes32 transitRef);

    /// @notice Storage slot a test writes with `vm.store` to fix the next send's amount to arrive, plus one.
    bytes32 public constant NEXT_ARRIVE_SLOT = keccak256("MockBridgeAdapter.nextArrivePlusOne");

    constructor(address target_) {
        target = target_;
    }

    function setVault(address v) external {
        vault = v;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function deprecate() external {
        deprecated = true;
    }

    function setUndeprecated() external {
        deprecated = false;
    }

    function setBadTarget(address t) external {
        badTarget = t;
    }

    function setArriveDelta(uint256 d) external {
        arriveDelta = d;
    }

    function setFee(uint256 f) external {
        fee = f;
    }

    function setNoteExpiryReverts(bool value) external {
        noteExpiryReverts = value;
    }

    function guardian() external view returns (address) {
        return address(this);
    }

    function protocolId() external pure returns (bytes32) {
        return keccak256("ACROSS_V3");
    }

    function fillDeadlineSeconds() public pure returns (uint32) {
        return 21_600;
    }

    function quoteSend(address, uint256, uint256 inputAmount, bytes calldata bridgeData)
        public
        view
        returns (uint256 amountToArrive, uint256 rateWad)
    {
        if (bridgeData.length == 32) return (abi.decode(bridgeData, (uint256)), 0);
        bytes32 slot = NEXT_ARRIVE_SLOT;
        uint256 nextPlusOne;
        assembly ("memory-safe") {
            nextPlusOne := sload(slot)
        }
        amountToArrive = nextPlusOne != 0 ? nextPlusOne - 1 : inputAmount - fee;
        rateWad = 0;
    }

    function buildSend(SendRequest calldata req, address depositor, bytes calldata bridgeData)
        external
        returns (BridgeCall memory call)
    {
        if (depositor == address(0) || req.recipient == bytes32(0)) revert InvalidParty();
        (uint256 amountToArrive,) = quoteSend(req.inputToken, req.destinationChainId, req.inputAmount, bridgeData);
        bytes32 slot = NEXT_ARRIVE_SLOT;
        assembly ("memory-safe") {
            sstore(slot, 0)
        }
        uint32 deadline = uint32(block.timestamp) + fillDeadlineSeconds();
        call.target = badTarget == address(0) ? target : badTarget;
        call.data = _encode(req, depositor, amountToArrive, deadline);
        call.transitRef = bytes32(uint256(MockAcrossSpokePool(target).numberOfDeposits()));
        call.amountToArrive = amountToArrive + arriveDelta;
        call.fillDeadline = deadline;
    }

    function _encode(SendRequest calldata req, address depositor, uint256 amountToArrive, uint32 deadline)
        private
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            IAcrossSpokePool.depositV3,
            (
                depositor,
                address(uint160(uint256(req.recipient))),
                req.inputToken,
                req.outputToken,
                req.inputAmount,
                amountToArrive,
                req.destinationChainId,
                address(0),
                uint32(block.timestamp),
                deadline,
                0,
                req.message
            )
        );
    }

    function noteExpiry(bytes32 transitRef) external {
        if (noteExpiryReverts) revert NoteExpiryRefused(transitRef);
        ++expiryNotes[transitRef];
        lastExpiryRef = transitRef;
    }

    function feeState(uint256) external pure returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }
}
