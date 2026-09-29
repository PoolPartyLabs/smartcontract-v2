// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Income token that re-enters a target with fixed calldata on every outbound `transfer`, once per call.
///         Stands in for a hook-bearing token in the Mandate pool list (verification of the reentrancy guard on
///         Income Withdrawal and on the full-burn income payment).
contract ReenteringIncomeToken is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    bytes public lastRevert;

    constructor() ERC20("Reentering", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool ok, bytes memory ret) = target.call(payload);
            if (!ok) {
                lastRevert = ret;
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return super.transfer(to, amount);
    }
}
