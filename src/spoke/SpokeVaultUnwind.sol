// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISpokeVaultUnwind} from "../interfaces/ISpokeVaultUnwind.sol";
import {OrderCodec} from "../libraries/OrderCodec.sol";
import {SpokeVaultBase} from "./SpokeVaultBase.sol";
import {SpokeUnwindLib} from "./SpokeUnwindLib.sol";

/// @title SpokeVaultUnwind
/// @notice The hub Spoke Vault's automatic unwind for a payout, and the executors of the Core Vault's unwind and
///         closure orders on a spoke. See ISpokeVault.
/// @dev The entry keeps the chain, caller and reentrancy checks; the body runs in the linked library `SpokeUnwindLib`
///      (DEC-131). Split out of SpokeVault (WP-07 A3) so the unwind has its own source file.
abstract contract SpokeVaultUnwind is SpokeVaultBase {
    /// @notice Largest shortfall below the pool's current price, in bps, that an automatic unwind swap accepts: the
    ///         swap's minimum output is at least the route's `IAdapter.spotQuote` less this share.
    /// @dev OPEN parameter (QA3: the price guard of hub positions is undecided; final verification). Measured from the
    ///      higher of the route's spot quote and the Core Vault's price-source value (security review S-2: a spot price
    ///      can be moved within a block by the claimant); a claimant hint may only raise the minimum. Applied by the
    ///      linked `SpokeUnwindLib`, whose constant this is (DEC-131).
    uint256 public constant MAX_UNWIND_SLIPPAGE_BPS = SpokeUnwindLib.MAX_UNWIND_SLIPPAGE_BPS;

    // ---------------------------------------------------------------------------------------------------------------
    // Automatic unwind (DEC-069, DEC-081, DEC-097, DEC-131)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeVaultUnwind
    /// @dev DEC-069, DEC-081, DEC-097, DEC-131: the body lives in the linked library `SpokeUnwindLib` (see
    ///      `SpokeUnwindLib.unwindForPayout`); the vault keeps the chain, caller and reentrancy checks.
    /// @param unwindHints `abi.encode(SpokeUnwindTypes.UnwindHint[])`, optional, one per position in registry order.
    function unwindForPayout(uint256 usdcTarget, bytes calldata unwindHints)
        external
        onlyOnHubChain
        nonReentrant
        returns (uint256 usdcProceeds)
    {
        if (msg.sender != coreVault) revert NotCoreVault(msg.sender);
        usdcProceeds = SpokeUnwindLib.unwindForPayout(_s, _config(), usdcTarget, unwindHints);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Orders (DEC-120, DEC-139; WP-07 D4)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Executes an accepted unwind order (`OrderCodec.UNWIND`): the same fraction of every position, proceeds
    ///         home through the bridge adapter (DEC-120 item 2, DEC-137, DEC-139). `SpokeVault.executeOrder` calls it
    ///         after the order checks and publishes the report after it.
    /// @dev Stub until the spoke unwind orders are built: the order is refused whole (the cursor does not move).
    function _executeUnwindOrder(OrderCodec.Order memory o) internal virtual {
        revert OrderKindNotSupported(o.kind);
    }

    /// @notice Executes an accepted closure order (`OrderCodec.CLOSE`): everything home (DEC-121, DEC-147, DEC-149).
    ///         `SpokeVault.executeOrder` calls it after the order checks and publishes the report after it.
    /// @dev Stub until the closure is built: the order is refused whole (the cursor does not move).
    function _executeCloseOrder(OrderCodec.Order memory o) internal virtual {
        revert OrderKindNotSupported(o.kind);
    }
}
