// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISpokeVaultUnwind} from "../interfaces/ISpokeVaultUnwind.sol";
import {SpokeVaultBase} from "./SpokeVaultBase.sol";
import {SpokeUnwindLib} from "./SpokeUnwindLib.sol";

/// @title SpokeVaultUnwind
/// @notice The hub Spoke Vault's automatic unwind for a payout. See ISpokeVault.
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
    /// @param unwindHints `abi.encode(SpokeVaultTypes.UnwindHint[])`, optional, one per position in registry order.
    function unwindForPayout(uint256 usdcTarget, bytes calldata unwindHints)
        external
        onlyOnHubChain
        nonReentrant
        returns (uint256 usdcProceeds)
    {
        if (msg.sender != coreVault) revert NotCoreVault(msg.sender);
        usdcProceeds = SpokeUnwindLib.unwindForPayout(_s, _config(), usdcTarget, unwindHints);
    }
}
