// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAcrossMessageHandler} from "../../../../src/interfaces/external/IAcrossMessageHandler.sol";
import {IAcrossSpokePool} from "../../../../src/interfaces/external/IAcrossSpokePool.sol";
import {CoreMockToken} from "../../../mocks/core/CoreMockTokens.sol";

/// @notice Across SpokePool stand-in for the cross-chain security proofs of concept: one instance per chain, serving
///         the real `AcrossBridgeAdapter` (it answers `fillDeadlineBuffer` and `numberOfDeposits`).
/// @dev Mirrors the live SpokePool rules the findings depend on:
///      - `depositV3` pulls `inputAmount` from the caller and records the deposit; the exclusivity parameter is turned
///        into an absolute deadline as the live pool does (0 none, up to 31,536,000 an offset from the deposit time,
///        larger an absolute timestamp) and a non-zero value requires a non-zero exclusive relayer;
///      - `fillRelay` runs on the destination chain and does NOT know whether the deposit exists on the origin chain
///        (the live pool does not either: a relayer who fills a deposit that was never made is simply not repaid), so
///        anyone can reach a vault's `handleV3AcrossMessage` with any message by paying the output amount; it rejects
///        a fill after `fillDeadline` and a non-exclusive relayer before the exclusivity deadline;
///      - `refundExpired` pays the full `inputAmount` back to the depositor after the fill deadline (DEC-063).
///      The relayer's capital is minted rather than pulled, so the proofs do not have to fund relayers.
contract SecAcrossSpokePool {
    using SafeERC20 for IERC20;

    struct Deposit {
        address depositor;
        address recipient;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        address exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes message;
    }

    error InvalidQuoteTimestamp();
    error InvalidFillDeadline();
    error InvalidExclusiveRelayer();
    error ExpiredFillDeadline();
    error NotExclusiveRelayer();
    error NotExpired();
    error AlreadyRefunded();

    uint32 public constant MAX_EXCLUSIVITY_PERIOD_SECONDS = 31_536_000;

    uint32 public fillDeadlineBuffer = 21_600;
    uint32 public depositQuoteTimeBuffer = 3600;

    Deposit[] internal _deposits;
    mapping(uint256 depositId => bool) public refunded;

    function numberOfDeposits() external view returns (uint32) {
        return uint32(_deposits.length);
    }

    function deposit(uint256 id) external view returns (Deposit memory) {
        return _deposits[id];
    }

    /// @dev `IAcrossSpokePool.depositV3`, decoded into one struct (twelve parameters exceed the legacy stack). The
    ///      parameter tuple's encoding equals the struct's tail, so an offset word is prepended.
    fallback() external {
        require(msg.sig == IAcrossSpokePool.depositV3.selector, "unknown selector");
        Deposit memory d = abi.decode(bytes.concat(abi.encode(uint256(0x20)), msg.data[4:]), (Deposit));
        if (block.timestamp < d.quoteTimestamp || block.timestamp - d.quoteTimestamp > depositQuoteTimeBuffer) {
            revert InvalidQuoteTimestamp();
        }
        if (d.fillDeadline > block.timestamp + fillDeadlineBuffer) revert InvalidFillDeadline();
        if (d.exclusivityDeadline != 0) {
            if (d.exclusiveRelayer == address(0)) revert InvalidExclusiveRelayer();
            if (d.exclusivityDeadline <= MAX_EXCLUSIVITY_PERIOD_SECONDS) {
                d.exclusivityDeadline = uint32(block.timestamp) + d.exclusivityDeadline;
            }
        }
        IERC20(d.inputToken).safeTransferFrom(msg.sender, address(this), d.inputAmount);
        _deposits.push(d);
    }

    /// @notice A relayer's fill on this (destination) chain of the relay `d` describes.
    function fillRelay(Deposit calldata d) external {
        if (d.fillDeadline < block.timestamp) revert ExpiredFillDeadline();
        if (d.exclusivityDeadline >= block.timestamp && d.exclusiveRelayer != msg.sender) {
            if (d.exclusiveRelayer != address(0)) revert NotExclusiveRelayer();
        }
        CoreMockToken(d.outputToken).mint(d.recipient, d.outputAmount);
        if (d.message.length != 0) {
            IAcrossMessageHandler(d.recipient)
                .handleV3AcrossMessage(d.outputToken, d.outputAmount, msg.sender, d.message);
        }
    }

    /// @notice The Across expiry refund of deposit `id` on this (origin) chain: the full input amount to the depositor.
    function refundExpired(uint256 id) external {
        Deposit memory d = _deposits[id];
        if (block.timestamp <= d.fillDeadline) revert NotExpired();
        if (refunded[id]) revert AlreadyRefunded();
        refunded[id] = true;
        IERC20(d.inputToken).safeTransfer(d.depositor, d.inputAmount);
    }
}
