// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ITransitEscrow
/// @notice Per-send depositor of record for a bridge transfer (Across `depositor`), so that a refund on expiry lands
///         in a dedicated address and is recognized as a refund instead of being mistaken for a donation (DEC-080).
/// @dev DEC-066: the depositor must be keyless: no EIP-1271, no `receive`, no way to sign an Across speed-up. QA6
///      (OPEN): the per-send escrow is the research proposal, pending the founder's confirmation. Deployed as an
///      EIP-1167 clone by the sending vault, one per transit.
interface ITransitEscrow {
    error AlreadyInitialized();
    error NotVault(address caller);

    /// @notice `initialize` got a zero vault or token; a zero vault would leave the clone initializable again.
    error ZeroAddress();

    /// @notice The vault that created this escrow and may release its balance.
    function vault() external view returns (address);

    /// @notice The token this escrow holds a refund of.
    function token() external view returns (address);

    /// @notice Binds the clone to its vault and token. Callable once; both must be non-zero.
    function initialize(address vault_, address token_) external;

    /// @notice Transfers the whole `token` balance to `to`. Vault only.
    /// @return amount Amount transferred (0 when no refund has arrived).
    function release(address to) external returns (uint256 amount);
}
