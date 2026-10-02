// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAcrossSpokePoolLive} from "./IAcrossSpokePoolLive.sol";

/// @title AcrossPoolObserver
/// @notice The founder's "standalone contract connection" (2026-10-02): everything a contract on the same chain can
///         learn about other users' recent Across deposits, read through the EVM only (no logs, no off-chain API).
/// @dev The EVM has no opcode that reads logs: LOG0..LOG4 only append to the transaction receipt, which no later
///      execution can access. What is left is public storage and balances, gathered here in one call.
contract AcrossPoolObserver {
    /// @notice One observation of a SpokePool.
    /// @param deposits The deposit counter (`numberOfDeposits`), the next deposit id.
    /// @param poolBalance The pool's balance of `token`, which every deposit, fill, refund and bundle moves.
    /// @param quoteTimeBuffer Maximum age of a quote timestamp (`depositQuoteTimeBuffer`).
    /// @param fillDeadlineBuffer Maximum distance of a fill deadline (`fillDeadlineBuffer`).
    /// @param depositsPaused Whether deposits are paused.
    struct Observation {
        uint32 deposits;
        uint256 poolBalance;
        uint32 quoteTimeBuffer;
        uint32 fillDeadlineBuffer;
        bool depositsPaused;
    }

    function observe(address spokePool, address token) external view returns (Observation memory o) {
        IAcrossSpokePoolLive pool = IAcrossSpokePoolLive(spokePool);
        o.deposits = pool.numberOfDeposits();
        o.poolBalance = IERC20(token).balanceOf(spokePool);
        o.quoteTimeBuffer = pool.depositQuoteTimeBuffer();
        o.fillDeadlineBuffer = pool.fillDeadlineBuffer();
        o.depositsPaused = pool.pausedDeposits();
    }

    /// @notice Whether the relay described by `relayData` is filled on this chain (destination side only). The caller
    ///         must already know every field of the deposit, amounts included: the status is keyed by their hash.
    function isFilled(address spokePool, IAcrossSpokePoolLive.V3RelayData calldata relayData)
        external
        view
        returns (bool)
    {
        IAcrossSpokePoolLive pool = IAcrossSpokePoolLive(spokePool);
        return pool.fillStatuses(pool.getV3RelayHash(relayData)) == 2;
    }
}
