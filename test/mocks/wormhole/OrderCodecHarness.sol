// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";

/// @notice Exposes the internal `OrderCodec` functions.
contract OrderCodecHarness {
    function encode(OrderCodec.Order memory o) external pure returns (bytes memory) {
        return OrderCodec.encode(o);
    }

    function decode(bytes memory payload) external pure returns (OrderCodec.Order memory) {
        return OrderCodec.decode(payload);
    }

    function versionOf(bytes memory payload) external pure returns (uint256) {
        return OrderCodec.versionOf(payload);
    }

    function orderId(OrderCodec.Order memory o) external pure returns (bytes32) {
        return OrderCodec.orderId(o);
    }

    function check(OrderCodec.Order memory o) external pure returns (OrderCodec.Order memory) {
        OrderCodec.check(o);
        return o;
    }
}

/// @notice Stand-in for the Core Vault's publishing entry points (WP-09 / WP-10 / WP-12): a payable entry that passes
///         its `msg.value` to `OrderCodec.publish`, so this contract is the emitter.
contract OrderPublisherHarness {
    event OrderPublished(uint8 kind, bytes32 orderId, uint64 sequence);

    function publish(address core, OrderCodec.Order memory o) external payable returns (uint64 sequence) {
        sequence = OrderCodec.publish(core, o, msg.value);
        emit OrderPublished(o.kind, OrderCodec.orderId(o), sequence);
    }
}
