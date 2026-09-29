// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {MockAcrossSpokePool} from "./MockAcrossSpokePool.sol";

/// @notice IBridgeAdapter that builds an Across `depositV3` call against a MockAcrossSpokePool, with knobs to
///         misbehave (wrong target, wrong amount to arrive).
contract MockBridgeAdapter is IBridgeAdapter {
    address public immutable target;
    address public vault;
    bool public paused;
    bool public deprecated;
    address public badTarget;
    uint256 public arriveDelta;

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

    function guardian() external view returns (address) {
        return address(this);
    }

    function protocolId() external pure returns (bytes32) {
        return keccak256("ACROSS_V3");
    }

    function fillDeadlineSeconds() public pure returns (uint32) {
        return 21_600;
    }

    function buildSend(SendRequest calldata req, address depositor) external view returns (BridgeCall memory call) {
        if (req.inputAmount == 0 || req.outputAmount == 0 || req.outputAmount > req.inputAmount) {
            revert InvalidAmounts(req.inputAmount, req.outputAmount);
        }
        if (depositor == address(0) || req.recipient == bytes32(0)) revert InvalidParty();
        uint32 deadline = uint32(block.timestamp) + fillDeadlineSeconds();
        call.target = badTarget == address(0) ? target : badTarget;
        call.data = abi.encodeCall(
            IAcrossSpokePool.depositV3,
            (
                depositor,
                address(uint160(uint256(req.recipient))),
                req.inputToken,
                req.outputToken,
                req.inputAmount,
                req.outputAmount,
                req.destinationChainId,
                req.exclusiveRelayer,
                req.quoteTimestamp,
                deadline,
                req.exclusivityDeadline,
                req.message
            )
        );
        call.transitRef = bytes32(uint256(MockAcrossSpokePool(target).numberOfDeposits()));
        call.amountToArrive = req.outputAmount + arriveDelta;
        call.fillDeadline = deadline;
    }
}
