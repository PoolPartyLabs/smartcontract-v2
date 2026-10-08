// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Mandate} from "../../../src/mandate/Mandate.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";

library OrderHarnessRecorder {
    function setReentry(bytes storage data, bytes calldata vaa) external {
        while (data.length != 0) data.pop();
        for (uint256 index; index < vaa.length; ++index) {
            data.push(vaa[index]);
        }
    }

    function reason(mapping(uint256 => bytes) storage data) external view returns (bytes memory) {
        return data[0];
    }

    function executed(uint8[] storage kinds) external view returns (uint8[] memory) {
        return kinds;
    }

    function record(
        SpokeVaultTypes.State storage state,
        uint8[] storage executedKinds,
        bytes storage reentryVaa,
        mapping(uint256 => bytes) storage failures,
        OrderCodec.Order memory order
    ) external {
        if (order.kind == OrderCodec.COLLECT) {
            state.income.reportBlob = abi.encode(OrderCodec.orderId(order));
        } else {
            state.unwind.reportBlob = abi.encode(OrderCodec.orderId(order), order.fracNum, order.fracDen);
        }
        executedKinds.push(order.kind);
        delete failures[0];
        if (reentryVaa.length == 0) return;
        try SpokeVault(address(this)).executeOrder(reentryVaa) {}
        catch (bytes memory failure) {
            failures[0] = failure;
        }
    }
}

/// @notice A Spoke Vault with stand-in order executors for dispatch and report tests:
///         each records the kind and writes the order's id into the book its report field comes from, so a test sees
///         the order checks, the dispatch and the report published in the same transaction. Optionally re-enters
///         `executeOrder` from inside an executor and keeps the revert data.
contract SpokeVaultOrderHarness is SpokeVault {
    uint8[] internal _executed;
    bytes internal _reentryVaa;
    mapping(uint256 => bytes) internal _reentryRevert;

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
    function setReentry(bytes calldata vaa) external {
        OrderHarnessRecorder.setReentry(_reentryVaa, vaa);
    }

    function reentryRevert() external view returns (bytes memory) {
        return OrderHarnessRecorder.reason(_reentryRevert);
    }

    /// @notice The kinds the executors ran, in order.
    function executed() external view returns (uint8[] memory) {
        return OrderHarnessRecorder.executed(_executed);
    }

    /// @notice The lowest order sequence the vault still accepts (`OrderVerifier.Cursor`).
    function orderCursor() external view returns (uint64) {
        return _s.orders.minSequence;
    }

    function _executeUnwindOrder(OrderCodec.Order memory o) internal override {
        _record(o);
    }

    function _executeCloseOrder(OrderCodec.Order memory o) internal override {
        _record(o);
    }

    function _executeCollectOrder(OrderCodec.Order memory o) internal override {
        _record(o);
    }

    function _record(OrderCodec.Order memory o) private {
        OrderHarnessRecorder.record(_s, _executed, _reentryVaa, _reentryRevert, o);
    }
}
