// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ShareToken
/// @notice The fund's Share: an ERC-20 with 18 decimals, only whole shares, not transferable.
/// @dev DEC-091: ERC-20 with 18 decimals; every mint and burn is a multiple of 1e18, else revert.
/// @dev DEC-004: no ordinary share transfer and no delegated transfer that bypasses it; `transfer`, `transferFrom` and
///      `approve` revert, `allowance` is always 0, and there is no `permit` (Q58 OPEN, reading A). `Transfer` events
///      are therefore only emitted from address(0) (mint) or to address(0) (burn).
/// @dev DEC-011, DEC-054: only the Core Vault mints and burns. The Core Vault may burn from any holder without an
///      allowance (payout execution, DEC-047, DEC-077).
/// @dev Q59 OPEN: the name and symbol pattern is not decided; they are constructor strings chosen by the factory,
///      never manager text, with no setter.
contract ShareToken is ERC20 {
    /// @notice Base units of one whole share (DEC-091).
    uint256 public constant WHOLE_SHARE = 1e18;

    /// @notice The Core Vault, the only minter and burner; set once at construction.
    address public immutable coreVault;

    /// @notice Share transfers and approvals are disabled (DEC-004).
    error ShareTransfersDisabled();

    /// @notice Caller is not the Core Vault.
    error NotCoreVault(address caller);

    /// @notice A mint or burn amount is not a multiple of 1e18 (DEC-091).
    error NotWholeShares(uint256 amount);

    /// @notice Zero Core Vault address at construction.
    error ZeroCoreVault();

    constructor(string memory name_, string memory symbol_, address coreVault_) ERC20(name_, symbol_) {
        if (coreVault_ == address(0)) revert ZeroCoreVault();
        coreVault = coreVault_;
    }

    modifier onlyCoreVault() {
        if (msg.sender != coreVault) revert NotCoreVault(msg.sender);
        _;
    }

    /// @notice Mints whole shares to `to`. Core Vault only.
    /// @dev DEC-091: reverts with `NotWholeShares` unless `amount % 1e18 == 0`.
    function mint(address to, uint256 amount) external onlyCoreVault {
        if (amount % WHOLE_SHARE != 0) revert NotWholeShares(amount);
        _mint(to, amount);
    }

    /// @notice Burns whole shares from `from`, without allowance. Core Vault only.
    /// @dev DEC-091: reverts with `NotWholeShares` unless `amount % 1e18 == 0`. DEC-077: shares are burned only at
    ///      payout execution.
    function burn(address from, uint256 amount) external onlyCoreVault {
        if (amount % WHOLE_SHARE != 0) revert NotWholeShares(amount);
        _burn(from, amount);
    }

    /// @notice Disabled (DEC-004).
    function transfer(address, uint256) public pure override returns (bool) {
        revert ShareTransfersDisabled();
    }

    /// @notice Disabled (DEC-004).
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert ShareTransfersDisabled();
    }

    /// @notice Disabled (DEC-004, Q58b).
    function approve(address, uint256) public pure override returns (bool) {
        revert ShareTransfersDisabled();
    }

    /// @notice Always 0: no approval can exist (DEC-004).
    function allowance(address, address) public pure override returns (uint256) {
        return 0;
    }
}
