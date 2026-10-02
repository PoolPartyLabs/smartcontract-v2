// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {ITransitEscrow} from "../../../src/interfaces/ITransitEscrow.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";

/// @notice Test vault that executes a bridge send exactly as IBridgeAdapter prescribes: per-send keyless escrow as
///         depositor (DEC-066), target pinned at creation, the adapter's amount to arrive above zero and not above the
///         amount sent (DEC-162), exact approval, plain CALL without value, exact balance debit, approval reset to
///         zero. It also relays `noteExpiry`, as the vaults do once a send is known not to arrive.
contract AcrossHarnessVault {
    using SafeERC20 for IERC20;

    error AlreadyPinned();
    error TargetMismatch(address expected, address actual);
    error CodehashMismatch();
    error InexactDebit(uint256 expected, uint256 actual);
    error AmountToArriveOutOfRange(uint256 amountSent, uint256 amountToArrive);

    address public immutable escrowImplementation;

    IBridgeAdapter public adapter;
    address public pinnedTarget;
    bytes32 public pinnedCodehash;

    constructor() {
        escrowImplementation = address(new TransitEscrow());
    }

    /// @notice Pins the adapter, its target and its codehash once, as a vault does at creation (Q17-4 reading O2).
    function pin(IBridgeAdapter adapter_) external {
        if (address(adapter) != address(0)) revert AlreadyPinned();
        adapter = adapter_;
        pinnedTarget = adapter_.target();
        pinnedCodehash = address(adapter_).codehash;
    }

    /// @notice Executes one send without `bridgeData`. Bubbles the bridge protocol's revert data unchanged.
    function send(IBridgeAdapter.SendRequest calldata req)
        external
        returns (IBridgeAdapter.BridgeCall memory call, address escrow)
    {
        return _send(req, "");
    }

    /// @notice Executes one send with `bridgeData` passed through to the adapter untouched.
    function send(IBridgeAdapter.SendRequest calldata req, bytes calldata bridgeData)
        external
        returns (IBridgeAdapter.BridgeCall memory call, address escrow)
    {
        return _send(req, bridgeData);
    }

    /// @notice Tells the adapter a send expired, as the vaults do on proven non-arrival (DEC-162).
    function noteExpiry(bytes32 transitRef) external {
        adapter.noteExpiry(transitRef);
    }

    function _send(IBridgeAdapter.SendRequest calldata req, bytes memory bridgeData)
        internal
        returns (IBridgeAdapter.BridgeCall memory call, address escrow)
    {
        if (address(adapter).codehash != pinnedCodehash) revert CodehashMismatch();
        escrow = Clones.clone(escrowImplementation);
        ITransitEscrow(escrow).initialize(address(this), req.inputToken);

        call = adapter.buildSend(req, escrow, bridgeData);
        if (call.target != pinnedTarget) revert TargetMismatch(pinnedTarget, call.target);
        if (call.amountToArrive == 0 || call.amountToArrive > req.inputAmount) {
            revert AmountToArriveOutOfRange(req.inputAmount, call.amountToArrive);
        }

        IERC20 token = IERC20(req.inputToken);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.forceApprove(call.target, req.inputAmount);
        (bool ok, bytes memory ret) = call.target.call(call.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        uint256 debit = balanceBefore - token.balanceOf(address(this));
        if (debit != req.inputAmount) revert InexactDebit(req.inputAmount, debit);
        token.forceApprove(call.target, 0);
    }
}
