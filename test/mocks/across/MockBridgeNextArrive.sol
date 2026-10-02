// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

/// @notice Fixes the amount to arrive of the next send through a mock bridge adapter (core or spoke
///         `MockBridgeAdapter`), by writing its `NEXT_ARRIVE_SLOT` with `vm.store`.
/// @dev DEC-158, DEC-162: the vaults pass no amount to arrive; the adapter fixes it. Vault tests that need a given
///      amount set it on the mock adapter instead. A cheatcode write does not consume a pending `vm.prank`, so the
///      helper can run inside the argument list of a pranked send.
library MockBridgeNextArrive {
    bytes32 internal constant SLOT = keccak256("MockBridgeAdapter.nextArrivePlusOne");
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function set(address adapter, uint256 amountToArrive) internal {
        VM.store(adapter, SLOT, bytes32(amountToArrive + 1));
    }
}
