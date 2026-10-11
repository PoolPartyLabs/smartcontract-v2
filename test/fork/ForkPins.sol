// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

/// @notice CR-19: fork pins come from the environment, never from source. `ARBITRUM_FORK_BLOCK` and
///         `ROBINHOOD_FORK_BLOCK` pin a run (a gate records them); unset, a fork starts at the chain head minus
///         `HEAD_LAG` blocks. Public RPCs keep only ~6-8k blocks of state (~10-35 min), so a pin written into a test
///         stops working within hours and only passes from a local RPC cache.
library ForkPins {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Blocks behind the head when no pin is set: far enough to be final-ish, well inside public retention.
    uint256 internal constant HEAD_LAG = 100;

    function arbitrum() internal returns (uint256) {
        return pin("ARBITRUM_FORK_BLOCK", "ARBITRUM_RPC_URL");
    }

    function robinhood() internal returns (uint256) {
        return pin("ROBINHOOD_FORK_BLOCK", "ROBINHOOD_RPC_URL");
    }

    /// @notice CCTP suites may pin their own block (live Circle state); otherwise they share the Arbitrum pin.
    function cctpArbitrum() internal returns (uint256 blockNumber) {
        blockNumber = VM.envOr("CCTP_ARBITRUM_FORK_BLOCK", uint256(0));
        if (blockNumber == 0) blockNumber = arbitrum();
    }

    /// @notice `blockVar` when set and non-zero, else the head of `rpcVar`'s chain minus `HEAD_LAG`.
    function pin(string memory blockVar, string memory rpcVar) internal returns (uint256 blockNumber) {
        blockNumber = VM.envOr(blockVar, uint256(0));
        if (blockNumber != 0) return blockNumber;
        bytes memory head = VM.rpc(VM.envString(rpcVar), "eth_blockNumber", "[]");
        for (uint256 index; index < head.length; ++index) {
            blockNumber = (blockNumber << 8) | uint8(head[index]);
        }
        blockNumber -= HEAD_LAG;
    }
}
