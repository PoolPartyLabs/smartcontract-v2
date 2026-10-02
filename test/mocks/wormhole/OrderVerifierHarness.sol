// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {OrderVerifier} from "../../../src/libraries/OrderVerifier.sol";

/// @notice Exposes `OrderVerifier.accept` with every argument and a cursor the test can place, for the bare checks.
///         It stores nothing itself: the cursor moves only inside the library.
contract OrderVerifierHarness {
    OrderVerifier.Cursor internal _cursor;

    function setMinSequence(uint64 minSequence) external {
        _cursor.minSequence = minSequence;
    }

    function minSequence() external view returns (uint64) {
        return _cursor.minSequence;
    }

    function accept(address core, bytes calldata vaa, uint16 hubWormholeChainId, address coreVault, bytes32 fundId)
        external
        returns (OrderCodec.Order memory o, uint64 sequence)
    {
        return OrderVerifier.accept(_cursor, core, vaa, hubWormholeChainId, coreVault, fundId);
    }
}

/// @notice Stand-in for `SpokeVault.executeOrder` (WP-07): permissionless delivery, then the library's checks, which
///         also move the cursor, before anything else (checks-effects-interactions).
contract OrderReceiverHarness {
    address public immutable core;
    uint16 public immutable hubWormholeChainId;
    address public immutable coreVault;
    bytes32 public immutable fundId;

    OrderVerifier.Cursor internal _orders;
    uint256 public executedCount;
    bytes32 public lastOrderId;

    event OrderExecuted(uint8 kind, bytes32 orderId, uint64 wormholeSequence);

    constructor(address core_, uint16 hubWormholeChainId_, address coreVault_, bytes32 fundId_) {
        core = core_;
        hubWormholeChainId = hubWormholeChainId_;
        coreVault = coreVault_;
        fundId = fundId_;
    }

    /// @notice Lowest acceptable order sequence: 0 before the first order, then the last accepted one plus one.
    function minSequence() external view returns (uint64) {
        return _orders.minSequence;
    }

    function execute(bytes calldata vaa) external returns (OrderCodec.Order memory o, uint64 sequence) {
        (o, sequence) = OrderVerifier.accept(_orders, core, vaa, hubWormholeChainId, coreVault, fundId);
        executedCount += 1;
        lastOrderId = OrderCodec.orderId(o);
        emit OrderExecuted(o.kind, lastOrderId, sequence);
    }
}
