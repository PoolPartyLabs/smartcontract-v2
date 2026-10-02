// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISpokeVaultIncome} from "../interfaces/ISpokeVaultIncome.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {OrderCodec} from "../libraries/OrderCodec.sol";
import {SpokeVaultTypes} from "./SpokeVaultTypes.sol";
import {SpokeLedger} from "./SpokeLedger.sol";
import {SpokeIncomeLib} from "./SpokeIncomeLib.sol";
import {SpokeVaultBase} from "./SpokeVaultBase.sol";

/// @title SpokeVaultIncome
/// @notice The Spoke Vault's collected income verbs: the swap of collected income into the base token (Spoke Chains)
///         and the forward of collected income to the Core Vault (Hub Chain), and the executor of the Core Vault's
///         income collection orders on a spoke. See ISpokeVault.
/// @dev Split out of SpokeVault (WP-07 A3, DEC-131 pattern) so the income verbs have their own source file; DEC-092:
///      collected income stays in its own bucket, outside Share Assets.
abstract contract SpokeVaultIncome is SpokeVaultBase {
    using SafeERC20 for IERC20;
    using SpokeLedger for SpokeVaultTypes.State;

    // ---------------------------------------------------------------------------------------------------------------
    // Collected income (DEC-092; CV-OQ-2, ruling 2026-09-29)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeVaultIncome
    /// @dev CV-OQ-2, ruling 2026-09-29, DEC-092: collected income in, base token out, both inside the collected income
    ///      bucket, through a Mandate swap adapter (DEC-136; founder, 2026-10-02: never in a fund pool). Same custody
    ///      and ledger checks as the manager's swap (`SpokeLedger.swapThrough`); a swap into the base token is an exit
    ///      and runs while the adapter is paused or deprecated (DEC-056).
    function swapCollectedIncome(
        address swapAdapter,
        address tokenIn,
        uint256 amountIn,
        uint16 maxLossBps,
        bytes calldata route
    ) external onlyOnSpokeChain onlyManager nonReentrant returns (uint256 amountOut) {
        _topUpOperatingCash();
        uint256 spotOut;
        uint256 minOut;
        (amountOut, spotOut, minOut) =
            _s.swapThrough(swapAdapter, tokenIn, baseToken, amountIn, maxLossBps, route, true);
        emit IncomeSwapped(swapAdapter, tokenIn, baseToken, amountIn, amountOut, spotOut, maxLossBps, minOut);
    }

    /// @inheritdoc ISpokeVaultIncome
    /// @dev DEC-092: collected income is handed to the Core Vault's Attributed Income bucket; the destination is fixed.
    function forwardIncomeToCoreVault(address token) external onlyOnHubChain nonReentrant returns (uint256 amount) {
        amount = _s.collectedIncome[token];
        if (amount == 0) revert ZeroAmount();
        _s.collectedIncome[token] = 0;
        IERC20(token).safeTransfer(coreVault, amount);
        ICoreVault(coreVault).receiveCollectedIncome(token, amount);
        emit IncomeForwardedToCoreVault(token, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Orders (DEC-122, DEC-124, DEC-161; WP-07 D4)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Executes an accepted income collection order (`OrderCodec.COLLECT`): collect the positions' income and
    ///         send it home (DEC-122 item 5, DEC-124, DEC-161). `SpokeVault.executeOrder` calls it after the order
    ///         checks and publishes the report after it.
    /// @dev The body runs in the linked library `SpokeIncomeLib` (WP-07 D5), which refuses the order until the
    ///      collection orders are built (the order is refused whole and the cursor does not move).
    function _executeCollectOrder(OrderCodec.Order memory o) internal virtual {
        SpokeIncomeLib.executeCollectOrder(_s, _config(), o);
    }
}
