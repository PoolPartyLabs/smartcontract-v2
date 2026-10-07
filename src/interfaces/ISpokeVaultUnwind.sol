// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ICoreVaultPayouts} from "./ICoreVaultPayouts.sol";

/// @title ISpokeVaultUnwind
/// @notice The hub Spoke Vault's automatic unwind for a payout: the same fraction of every position (DEC-137), each
///         position delivering its share or left out (DEC-148), with the memory of what delivered (DEC-151). Part of
///         ISpokeVault.
/// @dev Split out of ISpokeVault (WP-07 A4) so the unwind verbs and events sit with `SpokeVaultUnwind` and
///      `SpokeUnwindLib`. ISpokeVault inherits it.
interface ISpokeVaultUnwind {
    event UnwindBridgeExcluded(bytes32 indexed requestId, uint256 amount, uint256 amountToArrive, uint16 maxLossBps);

    function spokeClosed() external view returns (bool);
    function closureCost() external view returns (uint256);

    function unwindSend(uint256 amount) external returns (bytes32 transitId);

    /// @notice What the Core Vault asks of the hub Spoke Vault's automatic unwind for one Payout Request.
    /// @param requestId The Payout Request (`ICoreVaultPayouts.PayoutRequest.requestId`): what delivered is remembered
    ///        under it (DEC-151).
    /// @param fracNum Numerator of the share of every position and of every non-base Unallocated Balance to unwind,
    ///        the 2% margin included (DEC-137, DEC-081). 0: no position is touched; only the base token's Unallocated
    ///        Balance is paid into Idle.
    /// @param fracDen Denominator of that share; non-zero and at least `fracNum` when `fracNum` is non-zero.
    /// @param maxLossBps The requester's maximum loss per sale against the mid value before it, in bps; 0 or >= 10,000
    ///        for none (DEC-140, DEC-148, D-23).
    /// @param mode The request's mode, which decides who bears each sale's Market Cost (DEC-118, DEC-141).
    struct UnwindRequest {
        bytes32 requestId;
        uint256 fracNum;
        uint256 fracDen;
        uint16 maxLossBps;
        ICoreVaultPayouts.PayoutMode mode;
    }

    /// @notice What one automatic unwind did.
    /// @param proceeds Base token paid into the Core Vault's Idle through `ICoreVault.returnToIdle` (DEC-080): the base
    ///        token's Unallocated Balance (D-11) plus what the exits and sales of this call delivered.
    /// @param spotOut Sum of the sales' mid values before each sale (DEC-118, D-19).
    /// @param marketCost Sum of what the sales lost against those mid values (fee plus price impact, DEC-118 item 2).
    /// @param leaverCost The part of `marketCost` the requester bears: all of it for an Instant Payout (DEC-118); for
    ///        a Standard Payout, what exceeds 1% of the value of each sale (DEC-141).
    /// @param delivered Positions and Unallocated Balance tokens that delivered their share in this call.
    /// @param excluded Positions and Unallocated Balance tokens left out in this call: their exit or a sale reverted, a
    ///        sale above `maxLossBps` included (DEC-148); `UnwindStepExcluded` names each.
    struct UnwindResult {
        uint256 proceeds;
        uint256 spotOut;
        uint256 marketCost;
        uint256 leaverCost;
        uint256 delivered;
        uint256 excluded;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Hub only: an automatic unwind for Payout Request `requestId` ran at `fracNum / fracDen` (DEC-137).
    event UnwoundForPayout(bytes32 indexed requestId, uint256 fracNum, uint256 fracDen, UnwindResult result);

    /// @notice Hub only: a position (or, with `adapter` zero, the Unallocated Balance of the token in the low 160 bits
    ///         of `positionKey`) did not deliver its share for `requestId`; it is unwound at the next attempt
    ///         (DEC-148, DEC-151). `reason` is the revert data of its exit or sale (`ISwapAdapter.InsufficientOutput`
    ///         for a sale above the requester's maximum).
    event UnwindStepExcluded(
        bytes32 indexed requestId, address indexed adapter, bytes32 indexed positionKey, bytes reason
    );

    // ---------------------------------------------------------------------------------------------------------------
    // Hub Chain interplay with the Core Vault
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Automatic unwind for a payout. Core Vault only; hub only.
    /// @dev DEC-137, DEC-151: for every non-base Unallocated Balance token, then every open position (a snapshot of the
    ///      registry), not yet delivered for `requestId`: one atomic step (`unwindStep`) exits `fracNum / fracDen` of
    ///      it (`IAdapter.unwindExitParams`, at its size now, D-25) and sells every non-base principal the exit
    ///      returned into the base token through the Mandate swap adapter (DEC-136 item 4: never in a position's pool):
    ///      the tier `ISwapAdapter.bestDirectFee` chooses, once per token per call (D-21), then `swapDirect` with
    ///      `maxLossBps`. A step that reverts, a sale above the maximum included, is undone and left out (DEC-148); a
    ///      step whose exit returns only the base token has no sale and always delivers when its exit does (D-24).
    ///      Exit income goes to the collected income bucket, never to the proceeds (DEC-092). Then the whole base
    ///      token Unallocated Balance is paid into the Core Vault's Idle (D-11). No oracle and no price floor
    ///      (DEC-132, DEC-118); the requester's maximum is the only limit (DEC-140).
    function unwindForPayout(UnwindRequest calldata request) external returns (UnwindResult memory result);

    /// @notice One atomic step of `unwindForPayout`, called by this vault on itself so that a revert undoes the step
    ///         alone (DEC-148). Reverts `UnwindStepNotSelf` for any other caller.
    /// @param step `abi.encode(SpokeUnwindTypes.Step)`.
    /// @return `abi.encode(SpokeUnwindTypes.StepResult)`.
    function unwindStep(bytes calldata step) external returns (bytes memory);

    /// @notice Whether the position `positionKey` of `adapter` (or, with `adapter` zero, the Unallocated Balance of the
    ///         token in the low 160 bits of `positionKey`) already delivered its share for `requestId` (DEC-151).
    function unwindDelivered(bytes32 requestId, address adapter, bytes32 positionKey) external view returns (bool);
}
