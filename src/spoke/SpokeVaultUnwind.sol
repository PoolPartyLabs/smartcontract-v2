// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISpokeVaultUnwind} from "../interfaces/ISpokeVaultUnwind.sol";
import {OrderCodec} from "../libraries/OrderCodec.sol";
import {SpokeVaultBase} from "./SpokeVaultBase.sol";
import {SpokeUnwindLib} from "./SpokeUnwindLib.sol";
import {SpokeUnwindTypes} from "./SpokeUnwindTypes.sol";
import {SpokeCrossChainLib} from "./SpokeCrossChainLib.sol";
import {TransferKind} from "../interfaces/FundTypes.sol";

/// @title SpokeVaultUnwind
/// @notice The hub Spoke Vault's automatic unwind for a payout, and the executors of the Core Vault's unwind and
///         closure orders on a spoke. See ISpokeVault.
/// @dev The entries keep the chain, caller and reentrancy checks; the bodies run in the linked library
///      `SpokeUnwindLib` (DEC-131). Split out of SpokeVault (WP-07 A3) so the unwind has its own source file.
abstract contract SpokeVaultUnwind is SpokeVaultBase {
    function _requireSpokeOpen() internal view {
        if (_s.unwind.closed) revert SpokeUnwindTypes.SpokeClosed();
        if (_s.unwind.reservedBase != 0) revert SpokeUnwindTypes.UnwindProceedsReserved();
    }
    /// @notice DEC-141: in a Standard Payout the fund absorbs each unwind sale's loss up to this share of the value
    ///         sold, in bps; the requester bears the excess. Applied by the linked `SpokeUnwindLib`, whose constant
    ///         this is.
    uint256 public constant STANDARD_SALE_LOSS_ABSORB_BPS = SpokeUnwindLib.STANDARD_SALE_LOSS_ABSORB_BPS;

    // ---------------------------------------------------------------------------------------------------------------
    // Automatic unwind (DEC-137, DEC-140, DEC-141, DEC-148, DEC-151; DEC-131)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeVaultUnwind
    function unwindForPayout(UnwindRequest calldata request)
        external
        onlyOnHubChain
        nonReentrant
        returns (UnwindResult memory result)
    {
        if (msg.sender != coreVault) revert NotCoreVault(msg.sender);
        result = SpokeUnwindLib.unwindForPayout(_s, _config(), request);
    }

    /// @inheritdoc ISpokeVaultUnwind
    /// @dev Not `nonReentrant`: only this vault calls it, from inside `unwindForPayout`, which holds the guard.
    function unwindStep(bytes calldata step) external returns (bytes memory) {
        if (msg.sender != address(this)) revert SpokeUnwindTypes.UnwindStepNotSelf(msg.sender);
        return SpokeUnwindLib.unwindStep(_s, _config(), step);
    }

    /// @inheritdoc ISpokeVaultUnwind
    function unwindDelivered(bytes32 requestId, address adapter, bytes32 positionKey) external view returns (bool) {
        return _s.unwind.delivered[requestId][SpokeUnwindTypes.stepId(adapter, positionKey)];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Orders (DEC-120, DEC-139; WP-07 D4)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Executes an accepted unwind order (`OrderCodec.UNWIND`): the same fraction of every position, proceeds
    ///         home through the bridge adapter (DEC-120 item 2, DEC-137, DEC-139). `SpokeVault.executeOrder` calls it
    ///         after the order checks and publishes the report after it.
    function _executeUnwindOrder(OrderCodec.Order memory o) internal virtual {
        SpokeUnwindLib.executeUnwindOrder(_s, _config(), o);
    }

    /// @notice Executes an accepted closure order (`OrderCodec.CLOSE`): everything home (DEC-121, DEC-147, DEC-149).
    ///         `SpokeVault.executeOrder` calls it after the order checks and publishes the report after it.
    function _executeCloseOrder(OrderCodec.Order memory o) internal virtual {
        SpokeUnwindLib.executeUnwindOrder(_s, _config(), o);
    }

    function spokeClosed() external view returns (bool) {
        return _s.unwind.closed;
    }

    function closureCost() external view returns (uint256) {
        return _s.unwind.closureExcessCost;
    }

    function unwindSend(uint256 amount) external returns (bytes32 transitId) {
        if (msg.sender != address(this)) revert SpokeUnwindTypes.UnwindStepNotSelf(msg.sender);
        return SpokeCrossChainLib.sendHome(_s, _config(), amount, TransferKind.Principal, 0, "");
    }
}
