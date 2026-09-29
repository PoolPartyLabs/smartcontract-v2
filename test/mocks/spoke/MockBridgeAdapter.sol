// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdapterGuard} from "../../../src/adapters/AdapterGuard.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";

/// @notice Bridge adapter mock that builds a real Across `depositV3` call against `target`.
/// @dev Knobs make it lie about the target or the amount to arrive, for the vault's custody checks.
contract MockBridgeAdapter is AdapterGuard, IBridgeAdapter {
    uint32 public constant FILL_DEADLINE_SECONDS = 21_600;

    address public vault;
    address public immutable target;

    address public builtTargetOverride;
    uint256 public amountToArriveDelta;

    constructor(address guardian_, address target_) AdapterGuard(guardian_) {
        target = target_;
    }

    function setVault(address vault_) external {
        vault = vault_;
    }

    function setBuiltTargetOverride(address target_) external {
        builtTargetOverride = target_;
    }

    function setAmountToArriveDelta(uint256 delta) external {
        amountToArriveDelta = delta;
    }

    function protocolId() external pure returns (bytes32) {
        return keccak256("ACROSS_V3");
    }

    function fillDeadlineSeconds() external pure returns (uint32) {
        return FILL_DEADLINE_SECONDS;
    }

    function buildSend(SendRequest calldata req, address depositor) external view returns (BridgeCall memory call) {
        if (req.inputAmount == 0 || req.outputAmount == 0 || req.outputAmount > req.inputAmount) {
            revert InvalidAmounts(req.inputAmount, req.outputAmount);
        }
        if (req.recipient == bytes32(0) || depositor == address(0)) revert InvalidParty();
        uint32 fillDeadline = uint32(block.timestamp) + FILL_DEADLINE_SECONDS;
        call.target = builtTargetOverride == address(0) ? target : builtTargetOverride;
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
                fillDeadline,
                req.exclusivityDeadline,
                req.message
            )
        );
        call.transitRef = bytes32(uint256(IAcrossSpokePool(target).numberOfDeposits()));
        call.amountToArrive = req.outputAmount + amountToArriveDelta;
        call.fillDeadline = fillDeadline;
    }
}
