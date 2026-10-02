// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Mandate} from "../../../src/mandate/Mandate.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";

/// @notice A Spoke Vault whose order executors (stubs in production until the order work exists, WP-07 D4) succeed:
///         each records the kind and writes the order's id into the book its report field comes from, so a test sees
///         the order checks, the dispatch and the report published in the same transaction. Optionally re-enters
///         `executeOrder` from inside an executor and keeps the revert data.
contract SpokeVaultOrderHarness is SpokeVault {
    uint8[] internal _executed;
    bool internal _reenter;
    bytes32 public reentryRevertHash;

    constructor(
        Mandate memory mandate_,
        bytes32 fundId_,
        uint256 chainId_,
        address coreVault_,
        address baseToken_,
        address acrossSpokePool_,
        address wormholeCore_,
        address transitEscrowImplementation_,
        address excessRecipient_
    )
        SpokeVault(
            mandate_,
            fundId_,
            chainId_,
            coreVault_,
            baseToken_,
            acrossSpokePool_,
            wormholeCore_,
            transitEscrowImplementation_,
            excessRecipient_
        )
    {}

    /// @notice From now on every executor tries `executeOrder(vaa)` again before returning.
    function setReentry(bool enabled) external {
        _reenter = enabled;
    }

    /// @notice The kinds the executors ran, in order.
    function executed() external view returns (uint8[] memory) {
        return _executed;
    }

    /// @notice The lowest order sequence the vault still accepts (`OrderVerifier.Cursor`).
    function orderCursor() external view returns (uint64) {
        return _s.orders.minSequence;
    }

    function _executeUnwindOrder(OrderCodec.Order memory o) internal override {
        _s.unwind.reportBlob = abi.encode(OrderCodec.orderId(o), o.fracNum, o.fracDen);
        _record(o);
    }

    function _executeCloseOrder(OrderCodec.Order memory o) internal override {
        _executeUnwindOrder(o);
    }

    function _executeCollectOrder(OrderCodec.Order memory o) internal override {
        _s.income.reportBlob = abi.encode(OrderCodec.orderId(o));
        _record(o);
    }

    function _record(OrderCodec.Order memory o) private {
        _executed.push(o.kind);
        if (!_reenter) return;
        try this.executeOrder("") {}
        catch (bytes memory reason) {
            reentryRevertHash = keccak256(reason);
        }
    }
}
