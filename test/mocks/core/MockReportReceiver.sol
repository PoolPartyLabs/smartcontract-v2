// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";

/// @notice ValueReportReceiver stand-in: stores the latest report per spoke and notifies the Core Vault.
contract MockReportReceiver {
    address public coreVault;
    mapping(uint256 => bytes) internal _reports;
    mapping(uint256 => uint32) public maxReportAge;
    mapping(uint256 => uint64) public acceptedAt;

    function setCoreVault(address core) external {
        coreVault = core;
    }

    function setMaxReportAge(uint256 spokeIndex, uint32 age) external {
        maxReportAge[spokeIndex] = age;
    }

    /// @notice Stores `report` as the latest for `spokeIndex` and calls `onReportAccepted`.
    function deliver(uint256 spokeIndex, ReportCodec.Report memory report) external {
        _reports[spokeIndex] = abi.encode(report);
        acceptedAt[spokeIndex] = uint64(block.timestamp);
        ICoreVault(coreVault).onReportAccepted(spokeIndex);
    }

    /// @notice Stores a report without notifying (to test the notification guard).
    function store(uint256 spokeIndex, ReportCodec.Report memory report) external {
        _reports[spokeIndex] = abi.encode(report);
    }

    function hasReport(uint256 spokeIndex) external view returns (bool) {
        return _reports[spokeIndex].length != 0;
    }

    function latestReport(uint256 spokeIndex)
        external
        view
        returns (ReportCodec.Report memory report, uint64 wormholeSequence, uint64 at)
    {
        require(_reports[spokeIndex].length != 0, "no report");
        report = abi.decode(_reports[spokeIndex], (ReportCodec.Report));
        wormholeSequence = report.sequence;
        at = acceptedAt[spokeIndex];
    }

    function isReportFresh(uint256 spokeIndex) external view returns (bool) {
        if (_reports[spokeIndex].length == 0) return false;
        ReportCodec.Report memory report = abi.decode(_reports[spokeIndex], (ReportCodec.Report));
        return block.timestamp - report.timestamp <= maxReportAge[spokeIndex];
    }
}
