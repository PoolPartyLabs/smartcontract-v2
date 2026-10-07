// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";

/// @notice Offline stand-in for the Across SpokePool: the subset `IAcrossSpokePool` declares, with the deposit
///         checks of the live implementation that matter to the adapter (quote age, fill deadline, exclusivity).
/// @dev Not declared `is IAcrossSpokePool`: `depositV3` is dispatched through `fallback` (see below).
contract MockAcrossSpokePool {
    using SafeERC20 for IERC20;

    error InvalidQuoteTimestamp();
    error InvalidFillDeadline();
    error InvalidExclusiveRelayer();
    error UnknownSelector(bytes4 selector);

    uint32 public fillDeadlineBuffer = 21_600;
    uint32 public depositQuoteTimeBuffer = 3600;
    uint32 public numberOfDeposits;

    constructor(uint32 initialDepositId) {
        numberOfDeposits = initialDepositId;
    }

    function setFillDeadlineBuffer(uint32 buffer) external {
        fillDeadlineBuffer = buffer;
    }

    function setNumberOfDeposits(uint32 count) external {
        numberOfDeposits = count;
    }

    function getCurrentTime() public view returns (uint256) {
        return block.timestamp;
    }

    /// @notice Last deposit's depositor, recipient and id, for offline assertions (the live `FundsDeposited` event
    ///         is asserted field by field on the forks).
    address public lastDepositor;
    address public lastRecipient;
    uint256 public lastDepositId;

    /// @notice Minimal stand-in for `FundsDeposited` (the full 13-field event needs via-IR in a 12-argument frame).
    event MockDeposited(uint256 indexed depositId, address indexed depositor, address recipient, uint256 inputAmount);

    /// @dev `depositV3` is served by `fallback`: decoding its twelve arguments in one frame is too deep for the
    ///      legacy code generator, so the calldata is decoded in two slices.
    fallback() external {
        if (msg.sig != IAcrossSpokePool.depositV3.selector) revert UnknownSelector(msg.sig);
        (address depositor, address recipient, address inputToken,, uint256 inputAmount) =
            abi.decode(msg.data[4:], (address, address, address, address, uint256));
        (address exclusiveRelayer, uint32 quoteTimestamp, uint32 fillDeadline, uint32 exclusivityDeadline) =
            abi.decode(msg.data[4 + 7 * 32:], (address, uint32, uint32, uint32));
        _checkDeposit(quoteTimestamp, fillDeadline, exclusivityDeadline, exclusiveRelayer);
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
        uint256 depositId = numberOfDeposits++;
        lastDepositor = depositor;
        lastRecipient = recipient;
        lastDepositId = depositId;
        emit MockDeposited(depositId, depositor, recipient, inputAmount);
    }

    function _checkDeposit(
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        address exclusiveRelayer
    ) private view {
        uint256 currentTime = getCurrentTime();
        if (currentTime < quoteTimestamp || currentTime - quoteTimestamp > depositQuoteTimeBuffer) {
            revert InvalidQuoteTimestamp();
        }
        if (fillDeadline > currentTime + fillDeadlineBuffer) revert InvalidFillDeadline();
        if (exclusivityDeadline > 0 && exclusiveRelayer == address(0)) revert InvalidExclusiveRelayer();
    }
}
