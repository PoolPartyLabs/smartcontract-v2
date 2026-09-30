// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {MockPriceSource} from "../core/MockPriceSource.sol";

/// @notice Core Vault mock for the hub Spoke Vault: records `returnToIdle` and `receiveCollectedIncome`, and drives the
///         Core Vault-only verbs of the vault.
contract MockCoreVault {
    using SafeERC20 for IERC20;

    uint256 public idleReturned;
    uint256 public returnToIdleCalls;
    uint256 public lastReturnBalance;
    mapping(address => uint256) public incomeReceived;
    address public usdc;
    /// @notice The Core Vault's price source, which the hub Spoke Vault reads for the unwind swap floor (security
    ///         review S-2); prices are set by the test.
    address public priceSource;

    constructor(address usdc_) {
        usdc = usdc_;
        priceSource = address(new MockPriceSource());
    }

    /// @dev Records the amount and checks the tokens arrived before the call.
    function returnToIdle(uint256 amount) external {
        idleReturned += amount;
        ++returnToIdleCalls;
        lastReturnBalance = IERC20(usdc).balanceOf(address(this));
        require(lastReturnBalance >= idleReturned, "not transferred first");
    }

    function receiveCollectedIncome(address token, uint256 amount) external {
        incomeReceived[token] += amount;
        require(IERC20(token).balanceOf(address(this)) >= incomeReceived[token], "not transferred first");
    }

    /// @dev Transfers USDC it holds to the vault and credits it (DEC-017, DEC-072).
    function allocate(ISpokeVault vault, uint256 amount) external {
        IERC20(usdc).safeTransfer(address(vault), amount);
        vault.receiveFromCoreVault(amount);
    }

    function credit(ISpokeVault vault, uint256 amount) external {
        vault.receiveFromCoreVault(amount);
    }

    function unwind(ISpokeVault vault, uint256 usdcTarget, bytes calldata hints) external returns (uint256) {
        return vault.unwindForPayout(usdcTarget, hints);
    }
}
