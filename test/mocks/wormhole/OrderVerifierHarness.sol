// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {OrderVerifier} from "../../../src/libraries/OrderVerifier.sol";

/// @notice Exposes `OrderVerifier.verify` with every argument, for the stateless checks.
contract OrderVerifierHarness {
    function verify(
        address core,
        bytes calldata vaa,
        uint16 hubWormholeChainId,
        address coreVault,
        uint64 minSequence,
        bytes32 fundId
    ) external view returns (OrderCodec.Order memory o, uint64 sequence) {
        return OrderVerifier.verify(core, vaa, hubWormholeChainId, coreVault, minSequence, fundId);
    }
}

/// @notice Stand-in for `SpokeVault.executeOrder` (WP-07): permissionless delivery, the verifier's checks, then the
///         next acceptable sequence stored before anything else (checks-effects-interactions).
contract OrderReceiverHarness {
    address public immutable core;
    uint16 public immutable hubWormholeChainId;
    address public immutable coreVault;
    bytes32 public immutable fundId;

    /// @notice Lowest acceptable order sequence: 0 before the first order, then the last accepted one plus one.
    uint64 public minSequence;
    uint256 public executedCount;
    bytes32 public lastOrderId;

    event OrderExecuted(uint8 kind, bytes32 orderId, uint64 wormholeSequence);

    constructor(address core_, uint16 hubWormholeChainId_, address coreVault_, bytes32 fundId_) {
        core = core_;
        hubWormholeChainId = hubWormholeChainId_;
        coreVault = coreVault_;
        fundId = fundId_;
    }

    function execute(bytes calldata vaa) external returns (OrderCodec.Order memory o, uint64 sequence) {
        (o, sequence) = OrderVerifier.verify(core, vaa, hubWormholeChainId, coreVault, minSequence, fundId);
        minSequence = sequence + 1;
        executedCount += 1;
        lastOrderId = OrderCodec.orderId(o);
        emit OrderExecuted(o.kind, lastOrderId, sequence);
    }
}
