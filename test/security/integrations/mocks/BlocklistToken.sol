// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable ERC-20 with Circle-style compliance controls: a blocklist (a blocklisted address can neither send
///         nor receive) and a global pause, the two powers the live USDC (FiatTokenV2_2) and USDG contracts hold.
contract BlocklistToken is ERC20 {
    uint8 private immutable _decimals;
    mapping(address => bool) public blocklisted;
    bool public paused;

    error Blocklisted(address account);
    error Paused();

    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocklisted(address account, bool value) external {
        blocklisted[account] = value;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert Paused();
        if (blocklisted[from]) revert Blocklisted(from);
        if (blocklisted[to]) revert Blocklisted(to);
        super._update(from, to, value);
    }
}
