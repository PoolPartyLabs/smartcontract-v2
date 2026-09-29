// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";

/// @notice Core Vault stand-in for the receiver: records `onReportAccepted`, reads the stored report back inside the
///         callback (as the real Core Vault does) and can try to re-enter `deliver`.
contract MockReceiverCoreVault {
    IValueReportReceiver public receiver;
    uint256 public calls;
    uint256 public lastSpokeIndex;
    uint64 public sequenceSeenInCallback;
    bytes public reentryVaa;
    bool public revertOnCallback;

    function setReceiver(address receiver_) external {
        receiver = IValueReportReceiver(receiver_);
    }

    function setReentry(bytes calldata vaa) external {
        reentryVaa = vaa;
    }

    function setRevertOnCallback(bool value) external {
        revertOnCallback = value;
    }

    function onReportAccepted(uint256 spokeIndex) external {
        require(msg.sender == address(receiver), "not receiver");
        require(!revertOnCallback, "core vault rejects");
        ++calls;
        lastSpokeIndex = spokeIndex;
        (ReportCodec.Report memory r,,) = receiver.latestReport(spokeIndex);
        sequenceSeenInCallback = r.sequence;
        if (reentryVaa.length != 0) receiver.deliver(reentryVaa);
    }
}
