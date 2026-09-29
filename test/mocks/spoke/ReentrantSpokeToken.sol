// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC-20 whose every transfer out of a holder runs a configured call (an ERC-777-style hook), so a test can
///         try to re-enter the Spoke Vault while it is moving this token. Records how many hooks ran and how many of
///         the re-entries succeeded; the hook never reverts the transfer itself.
contract ReentrantSpokeToken is ERC20 {
    address public hookTarget;
    bytes internal _hookData;
    uint256 public hookCalls;
    uint256 public reentrySucceeded;
    bool internal _inHook;

    constructor() ERC20("Reentrant Token", "RTK") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        _hookData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hookTarget == address(0) || _inHook || from == address(0)) return;
        _inHook = true;
        ++hookCalls;
        (bool ok,) = hookTarget.call(_hookData);
        if (ok) ++reentrySucceeded;
        _inHook = false;
    }
}
