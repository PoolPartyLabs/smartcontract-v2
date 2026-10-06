pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICoreBridge, CoreBridgeVM} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {IValueReportReceiver} from "../interfaces/IValueReportReceiver.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {ReportCodecV6} from "../libraries/ReportCodecV6.sol";
import {SpokeConfig} from "../mandate/Mandate.sol";
import {SolanaSpokeRegistryV6} from "../mandate/SolanaMandateV6.sol";

/// @notice New-Fund receiver: source-specific finality, native v6 and unchanged EVM v5 (DEC-188, DEC-192).
contract ValueReportReceiverV6 is IValueReportReceiver, ReentrancyGuard {
    struct State {
        uint64 wormholeSequence;
        uint64 reportSequence;
        uint64 timestamp;
        uint64 acceptedAt;
    }

    address public immutable coreBridge;
    address public immutable coreVault;
    bytes32 public immutable fundId;
    uint16 public constant variationBandBps = 0;
    SolanaSpokeRegistryV6 public immutable nativeRegistry;
    SpokeConfig[] private _spokes;
    mapping(bytes32 emitter => uint256) private _indexPlusOne;
    mapping(uint256 index => State) private _states;
    mapping(uint256 index => bytes) private _reports;
    bytes private _nativeReport;

    error InvalidConfiguration();
    error UnknownSpoke(uint256 index);
    error InvalidNativeReport();

    constructor(
        address bridge,
        address vault,
        bytes32 id,
        SpokeConfig[] memory spokes,
        SolanaSpokeRegistryV6 registry
    ) {
        if (bridge == address(0) || vault == address(0) || id == 0 || address(registry).code.length == 0) {
            revert InvalidConfiguration();
        }
        coreBridge = bridge;
        coreVault = vault;
        fundId = id;
        nativeRegistry = registry;
        uint256 nativeCount;
        for (uint256 index; index < spokes.length; ++index) {
            SpokeConfig memory config = spokes[index];
            if (
                config.chainId == 0 || config.wormholeChainId == 0 || config.spokeVault == 0 || config.maxReportAge == 0
                    || config.maxReportAge != spokes[0].maxReportAge
            ) revert InvalidConfiguration();
            bytes32 key = keccak256(abi.encode(config.wormholeChainId, config.spokeVault));
            if (_indexPlusOne[key] != 0) revert InvalidConfiguration();
            if (config.wormholeChainId == 1) {
                ++nativeCount;
                if (config.chainId != registry.chainId() || config.spokeVault != registry.spoke()) {
                    revert InvalidConfiguration();
                }
            }
            _indexPlusOne[key] = index + 1;
            _spokes.push(config);
        }
        if (nativeCount != 1) revert InvalidConfiguration();
    }

    /// @dev DEC-192: emitter lookup precedes consistency validation; never accept a global 1-or-32 condition.
    function deliver(bytes calldata vaa) external nonReentrant returns (uint256 spokeIndex, uint64 reportSequence) {
        (CoreBridgeVM memory message, bool valid, string memory reason) = ICoreBridge(coreBridge).parseAndVerifyVM(vaa);
        if (!valid) revert InvalidVaa(reason);
        uint256 index = spokeIndexOf(message.emitterChainId, message.emitterAddress);
        uint8 required = requiredConsistencyLevel(index);
        if (message.consistencyLevel != required) revert NotFinalized(message.consistencyLevel);
        State memory previous = _states[index];
        if (previous.acceptedAt != 0 && message.sequence <= previous.wormholeSequence) {
            revert SequenceNotIncreasing(previous.wormholeSequence, message.sequence);
        }
        ReportCodec.Report memory report;
        if (message.emitterChainId == 1) {
            ReportCodecV6.Report memory native = ReportCodecV6.decode(message.payload);
            if (native.nativeMandateHash != nativeRegistry.nativeMandateHash()) revert InvalidNativeReport();
            nativeRegistry.validateMintStates(native.mintStates);
            report = _project(native);
        } else {
            report = ReportCodec.decode(message.payload);
        }
        SpokeConfig memory config = _spokes[index];
        if (report.fundId != fundId || report.spokeChainId != config.chainId) {
            revert ReportMismatch();
        }
        bytes32 expected = ICoreVault(coreVault).mandateHash();
        if (report.mandateHash != expected) revert ReportMismatch();
        if (previous.acceptedAt != 0 && report.sequence <= previous.reportSequence) {
            revert ReportSequenceNotIncreasing(previous.reportSequence, report.sequence);
        }
        uint256 age = _age(report.timestamp);
        if (age > config.maxReportAge) revert ReportTooOld(age, config.maxReportAge);
        uint256 nowTimestamp = block.timestamp;
        if (report.timestamp > nowTimestamp + config.maxReportAge) {
            revert ReportFromFuture(report.timestamp, block.timestamp);
        }
        _states[index] = State(message.sequence, report.sequence, report.timestamp, uint64(block.timestamp));
        _reports[index] = ReportCodec.encode(report);
        if (message.emitterChainId == 1) _nativeReport = message.payload;
        emit ReportAccepted(
            index,
            message.emitterChainId,
            message.emitterAddress,
            message.sequence,
            report.sequence,
            report.blockNumber,
            report.timestamp
        );
        ICoreVault(coreVault).onReportAccepted(index);
        return (index, report.sequence);
    }

    /// @notice Exact native bytes, including untruncated position accounts and mint state.
    function latestNativeReport() external view returns (bytes memory) {
        return _nativeReport;
    }

    function requiredConsistencyLevel(uint256 index) public view returns (uint8) {
        return _spoke(index).wormholeChainId == 1 ? 32 : 1;
    }

    function spokeIndexOf(uint16 chain, bytes32 emitter) public view returns (uint256) {
        uint256 plusOne = _indexPlusOne[keccak256(abi.encode(chain, emitter))];
        if (plusOne == 0) revert UnknownEmitter(chain, emitter);
        return plusOne - 1;
    }

    function hasReport(uint256 index) external view returns (bool) {
        _spoke(index);
        return _states[index].acceptedAt != 0;
    }

    /// @notice v5 accounting projection, not the native wire codec (DEC-188).
    function latestReport(uint256 index)
        external
        view
        returns (ReportCodec.Report memory report, uint64 wormholeSequence, uint64 acceptedAt)
    {
        _spoke(index);
        State memory state = _states[index];
        if (state.acceptedAt == 0) revert NoReport(index);
        return (ReportCodec.decode(_reports[index]), state.wormholeSequence, state.acceptedAt);
    }

    function lastWormholeSequence(uint256 index) external view returns (uint64) {
        _spoke(index);
        return _states[index].wormholeSequence;
    }

    function maxReportAge(uint256 index) external view returns (uint32) {
        return _spoke(index).maxReportAge;
    }

    function isReportFresh(uint256 index) external view returns (bool) {
        uint32 lifetime = _spoke(index).maxReportAge;
        State memory state = _states[index];
        return state.acceptedAt != 0 && _age(state.timestamp) <= lifetime;
    }

    function spokeCount() external view returns (uint256) {
        return _spokes.length;
    }

    function _spoke(uint256 index) private view returns (SpokeConfig storage) {
        if (index >= _spokes.length) revert UnknownSpoke(index);
        return _spokes[index];
    }

    function _age(uint64 timestamp) private view returns (uint256) {
        uint256 nowTimestamp = block.timestamp;
        return nowTimestamp > timestamp ? nowTimestamp - timestamp : 0;
    }

    function _project(ReportCodecV6.Report memory native) private view returns (ReportCodec.Report memory report) {
        report.fundId = native.fundId;
        report.mandateHash = native.mandateHash;
        report.sequence = native.sequence;
        report.spokeChainId = native.spokeChainId;
        report.blockNumber = native.slot;
        report.timestamp = native.timestamp;
        report.unallocated = _tokens(native.unallocated);
        report.cumulativeIncome = _tokens(native.cumulativeIncome);
        report.collectedIncome = _tokens(native.collectedIncome);
        report.cumulativeReceived = native.cumulativeReceived;
        report.cumulativeSentHome = native.cumulativeSentHome;
        report.arrivedTransits = native.arrivedTransits;
        report.inFlightToHub = native.inFlightToHub;
        (report.unwindResults, report.collectionResults) = ReportCodecV6.projectResults(native, nativeRegistry);
        report.positions = new ReportCodec.PositionReport[](native.positions.length);
        for (uint256 index; index < native.positions.length; ++index) {
            ReportCodecV6.Position memory position = native.positions[index];
            nativeRegistry.validatePosition(position);
            for (uint256 prior; prior < index; ++prior) {
                if (native.positions[prior].position == position.position) revert InvalidNativeReport();
            }
            ReportCodec.PositionReport memory projected;
            projected.poolKey = position.pool == 0 ? position.reserve : position.pool;
            projected.poolId = position.position;
            projected.tickLower = position.tickLower;
            projected.tickUpper = position.tickUpper;
            projected.liquidity = position.liquidity;
            projected.token0 = nativeRegistry.token(position.token0);
            projected.token1 = position.token1 == 0 ? address(0) : nativeRegistry.token(position.token1);
            projected.principal0 = position.principal0;
            projected.principal1 = position.principal1;
            projected.income0 = position.income0;
            projected.income1 = position.income1;
            report.positions[index] = projected;
        }
    }

    function _tokens(ReportCodecV6.TokenAmount[] memory amounts)
        private
        view
        returns (ReportCodec.TokenAmount[] memory projected)
    {
        projected = new ReportCodec.TokenAmount[](amounts.length);
        for (uint256 index; index < amounts.length; ++index) {
            for (uint256 prior; prior < index; ++prior) {
                if (amounts[prior].mint == amounts[index].mint) revert InvalidNativeReport();
            }
            projected[index] = ReportCodec.TokenAmount(nativeRegistry.token(amounts[index].mint), amounts[index].amount);
        }
    }
}
