// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICoreBridge, CoreBridgeVM} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {IValueReportReceiver} from "../interfaces/IValueReportReceiver.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {SpokeConfig} from "../mandate/Mandate.sol";

/// @title ValueReportReceiver
/// @notice Hub contract that accepts a fund's Wormhole value reports and keeps the latest one per Mandate spoke.
///         See IValueReportReceiver.
/// @dev DEC-086: Wormhole carries the reports and the emitter must be the fund's Spoke Vault on that chain.
/// @dev DEC-093: finalized consistency only; anyone may deliver; strictly increasing sequence per (emitter chain,
///      emitter address). The Core Bridge does not deduplicate application messages, so replay protection is ours:
///      the emitter pair is fixed by the Mandate (one pair per spoke index) and both the VAA sequence and the report
///      sequence must be strictly greater than the last accepted ones.
/// @dev DEC-094, DEC-099: a report older than the spoke's `maxReportAge` at delivery is rejected. The value is a
///      Mandate parameter (OPEN, Q57 / Q66; research value for Robinhood 1,587 s plus one block).
/// @dev DEC-022, DEC-058: no proxy, no owner, no setter; every parameter is fixed at construction.
contract ValueReportReceiver is IValueReportReceiver, ReentrancyGuard {
    /// @notice Wormhole consistency level of a finalized message (DEC-093).
    uint8 public constant FINALIZED = 1;

    /// @notice Basis-point denominator.
    uint16 internal constant BPS = 10_000;

    /// @notice What the receiver needs from one Mandate spoke.
    struct Spoke {
        uint256 chainId;
        bytes32 spokeVault;
        uint16 wormholeChainId;
        uint32 maxReportAge;
    }

    /// @notice Acceptance state of one spoke. `acceptedAt == 0` means no report was ever accepted.
    struct SpokeState {
        uint64 lastWormholeSequence;
        uint64 lastReportSequence;
        uint64 reportTimestamp;
        uint64 acceptedAt;
    }

    /// @notice A constructor address is zero.
    error ZeroAddress();

    /// @notice The fund id is zero.
    error ZeroFundId();

    /// @notice A Mandate spoke lacks a field the receiver needs.
    error InvalidSpoke(uint256 spokeIndex);

    /// @notice Two Mandate spokes share an emitter pair.
    error DuplicateEmitter(uint16 emitterChainId, bytes32 emitterAddress);

    /// @notice The variation band exceeds 100%.
    error VariationBandAboveMax(uint16 bps);

    /// @notice The spoke index is not a Mandate spoke.
    error UnknownSpoke(uint256 spokeIndex);

    /// @inheritdoc IValueReportReceiver
    address public immutable coreBridge;

    /// @inheritdoc IValueReportReceiver
    address public immutable coreVault;

    /// @inheritdoc IValueReportReceiver
    bytes32 public immutable fundId;

    /// @inheritdoc IValueReportReceiver
    /// @dev OPEN (Q57 (d), erratum 12): stored, never enforced. With 0 (the MVP value) the band is disabled.
    uint16 public immutable variationBandBps;

    Spoke[] internal _spokes;
    mapping(uint256 spokeIndex => SpokeState) internal _state;
    mapping(uint256 spokeIndex => bytes) internal _payload;

    /// @dev Emitter pair => spoke index + 1 (0 = unknown emitter).
    mapping(bytes32 emitterKey => uint256) internal _spokeIndexPlusOne;

    /// @param coreBridge_ Wormhole Core Bridge on the hub.
    /// @param coreVault_ The fund's Core Vault (may be a CREATE2-predicted address not yet deployed).
    /// @param fundId_ Fund identifier the Spoke Vaults write in every report.
    /// @param spokes The Mandate's spokes, in Mandate order: the index here is the Mandate spoke index.
    /// @param variationBandBps_ Variation band in bps; 0 disables it (Q57 (d) OPEN, never enforced in the MVP).
    constructor(
        address coreBridge_,
        address coreVault_,
        bytes32 fundId_,
        SpokeConfig[] memory spokes,
        uint16 variationBandBps_
    ) {
        if (coreBridge_ == address(0) || coreVault_ == address(0)) revert ZeroAddress();
        if (fundId_ == bytes32(0)) revert ZeroFundId();
        if (variationBandBps_ > BPS) revert VariationBandAboveMax(variationBandBps_);
        coreBridge = coreBridge_;
        coreVault = coreVault_;
        fundId = fundId_;
        variationBandBps = variationBandBps_;

        for (uint256 i; i < spokes.length; ++i) {
            SpokeConfig memory s = spokes[i];
            // DEC-086: the emitter pair must be known; DEC-099: a zero lifetime would reject every report.
            if (s.chainId == 0 || s.wormholeChainId == 0 || s.spokeVault == bytes32(0) || s.maxReportAge == 0) {
                revert InvalidSpoke(i);
            }
            bytes32 key = _emitterKey(s.wormholeChainId, s.spokeVault);
            if (_spokeIndexPlusOne[key] != 0) revert DuplicateEmitter(s.wormholeChainId, s.spokeVault);
            _spokeIndexPlusOne[key] = i + 1;
            _spokes.push(
                Spoke({
                    chainId: s.chainId,
                    spokeVault: s.spokeVault,
                    wormholeChainId: s.wormholeChainId,
                    maxReportAge: s.maxReportAge
                })
            );
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Delivery
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IValueReportReceiver
    /// @dev DEC-093: permissionless. Checks, in order:
    ///      1. the Core Bridge verifies the guardian quorum (`InvalidVaa`), DEC-086;
    ///      2. consistency level is finalized (`NotFinalized`), DEC-093;
    ///      3. the emitter pair is a Mandate Spoke Vault (`UnknownEmitter`), DEC-086;
    ///      4. the VAA sequence is strictly greater than the last accepted one (`SequenceNotIncreasing`), DEC-093;
    ///      5. the payload decodes with the current ReportCodec version (4: the order results travel opaque, WP-07 D3,
    ///         and are left to the Core Vault's hooks) and carries this fund's id and the emitter's
    ///         EVM chain id (`ReportMismatch`), DEC-070, DEC-086;
    ///      6. the report sequence is strictly greater than the last accepted one (`ReportSequenceNotIncreasing`),
    ///         DEC-093;
    ///      7. `block.timestamp - report.timestamp <= maxReportAge` (`ReportTooOld`), DEC-094, DEC-099;
    ///      8. `report.timestamp <= block.timestamp + maxReportAge` (`ReportFromFuture`): a timestamp ahead of the hub
    ///         clock counts as age 0, so without a bound it would extend the report's life by the skew (report-receiver
    ///         verifier finding). Assumption under DEC-099, no decision covers skew: tolerated up to one lifetime, so a
    ///         report is never fresh for more than twice `maxReportAge`.
    ///      Then stores the report and notifies the Core Vault (checks-effects-interactions). The first report of a
    ///      spoke accepts any sequence, since a Wormhole emitter's first sequence is 0.
    function deliver(bytes calldata vaa) external nonReentrant returns (uint256 spokeIndex, uint64 reportSequence) {
        (CoreBridgeVM memory vm, bool valid, string memory reason) = ICoreBridge(coreBridge).parseAndVerifyVM(vaa);
        if (!valid) revert InvalidVaa(reason);

        // DEC-093: finalized consistency only.
        if (vm.consistencyLevel != FINALIZED) revert NotFinalized(vm.consistencyLevel);

        // DEC-086: the emitter must be the fund's Spoke Vault on that chain.
        uint256 indexPlusOne = _spokeIndexPlusOne[_emitterKey(vm.emitterChainId, vm.emitterAddress)];
        if (indexPlusOne == 0) revert UnknownEmitter(vm.emitterChainId, vm.emitterAddress);
        spokeIndex = indexPlusOne - 1;

        SpokeState memory state = _state[spokeIndex];
        bool seen = state.acceptedAt != 0;

        // DEC-093: strictly increasing VAA sequence per emitter; rejects replays and out-of-order VAAs.
        if (seen && vm.sequence <= state.lastWormholeSequence) {
            revert SequenceNotIncreasing(state.lastWormholeSequence, vm.sequence);
        }

        ReportCodec.Report memory report = ReportCodec.decode(vm.payload);
        Spoke memory config = _spokes[spokeIndex];

        // DEC-070, DEC-086: the report belongs to this fund and to the chain of its emitter.
        if (report.fundId != fundId || report.spokeChainId != config.chainId) revert ReportMismatch();

        // DEC-093: the Spoke Vault's own report counter is strictly increasing too.
        reportSequence = report.sequence;
        if (seen && reportSequence <= state.lastReportSequence) {
            revert ReportSequenceNotIncreasing(state.lastReportSequence, reportSequence);
        }

        // DEC-094, DEC-099: age at delivery measured from the spoke block timestamp the report was built at.
        uint256 age = _age(report.timestamp);
        if (age > config.maxReportAge) revert ReportTooOld(age, config.maxReportAge);
        if (report.timestamp > block.timestamp + config.maxReportAge) {
            revert ReportFromFuture(report.timestamp, block.timestamp);
        }

        _state[spokeIndex] = SpokeState({
            lastWormholeSequence: vm.sequence,
            lastReportSequence: reportSequence,
            reportTimestamp: report.timestamp,
            acceptedAt: uint64(block.timestamp)
        });
        _payload[spokeIndex] = vm.payload;

        emit ReportAccepted(
            spokeIndex,
            vm.emitterChainId,
            vm.emitterAddress,
            vm.sequence,
            reportSequence,
            report.blockNumber,
            report.timestamp
        );

        ICoreVault(coreVault).onReportAccepted(spokeIndex);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IValueReportReceiver
    function hasReport(uint256 spokeIndex) external view returns (bool) {
        return _state[spokeIndex].acceptedAt != 0;
    }

    /// @inheritdoc IValueReportReceiver
    function latestReport(uint256 spokeIndex)
        external
        view
        returns (ReportCodec.Report memory report, uint64 wormholeSequence, uint64 acceptedAt)
    {
        SpokeState memory state = _state[spokeIndex];
        if (state.acceptedAt == 0) revert NoReport(spokeIndex);
        report = ReportCodec.decode(_payload[spokeIndex]);
        return (report, state.lastWormholeSequence, state.acceptedAt);
    }

    /// @inheritdoc IValueReportReceiver
    function lastWormholeSequence(uint256 spokeIndex) external view returns (uint64) {
        return _state[spokeIndex].lastWormholeSequence;
    }

    /// @notice Last accepted report sequence of a spoke (meaningful only when `hasReport`).
    function lastReportSequence(uint256 spokeIndex) external view returns (uint64) {
        return _state[spokeIndex].lastReportSequence;
    }

    /// @inheritdoc IValueReportReceiver
    function maxReportAge(uint256 spokeIndex) external view returns (uint32) {
        return _spoke(spokeIndex).maxReportAge;
    }

    /// @inheritdoc IValueReportReceiver
    /// @dev DEC-099 with the Q57 reading (OPEN): true when a report exists and `block.timestamp - report.timestamp
    ///      <= maxReportAge`, the same bound `deliver` enforces. False when no report was ever accepted. Reverts with
    ///      `UnknownSpoke` for an index outside the Mandate.
    function isReportFresh(uint256 spokeIndex) external view returns (bool) {
        uint32 maxAge = _spoke(spokeIndex).maxReportAge;
        SpokeState memory state = _state[spokeIndex];
        if (state.acceptedAt == 0) return false;
        return _age(state.reportTimestamp) <= maxAge;
    }

    /// @notice Number of Mandate spokes this receiver serves.
    function spokeCount() external view returns (uint256) {
        return _spokes.length;
    }

    /// @notice The Mandate spoke at `spokeIndex` as the receiver stores it.
    function spoke(uint256 spokeIndex) external view returns (Spoke memory) {
        return _spoke(spokeIndex);
    }

    /// @notice Mandate spoke index of an emitter pair. Reverts with `UnknownEmitter` if none.
    function spokeIndexOf(uint16 emitterChainId, bytes32 emitterAddress) external view returns (uint256) {
        uint256 indexPlusOne = _spokeIndexPlusOne[_emitterKey(emitterChainId, emitterAddress)];
        if (indexPlusOne == 0) revert UnknownEmitter(emitterChainId, emitterAddress);
        return indexPlusOne - 1;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------------------------

    function _spoke(uint256 spokeIndex) internal view returns (Spoke storage) {
        if (spokeIndex >= _spokes.length) revert UnknownSpoke(spokeIndex);
        return _spokes[spokeIndex];
    }

    /// @dev A report timestamp ahead of the hub clock (cross-chain clock skew) counts as age 0 rather than reverting;
    ///      `deliver` bounds the skew to one report lifetime.
    function _age(uint64 timestamp) internal view returns (uint256) {
        return block.timestamp > timestamp ? block.timestamp - timestamp : 0;
    }

    function _emitterKey(uint16 emitterChainId, bytes32 emitterAddress) internal pure returns (bytes32) {
        return keccak256(abi.encode(emitterChainId, emitterAddress));
    }
}
