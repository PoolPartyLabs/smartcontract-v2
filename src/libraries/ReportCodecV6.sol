pragma solidity 0.8.28;

import {ReportCodec} from "./ReportCodec.sol";
import {SpokeUnwindTypes} from "../spoke/SpokeUnwindTypes.sol";
import {SpokeIncomeTypes} from "../spoke/SpokeIncomeTypes.sol";
import {SolanaSpokeRegistryV6} from "../mandate/SolanaMandateV6.sol";

/// @notice Lossless Solana report ABI for new Funds only (DEC-188, DEC-192).
/// @dev The v5 accounting projection is never the wire format. See docs/SOLANA-REPORT-V6.md.
library ReportCodecV6 {
    uint256 internal constant VERSION = 6;

    struct TokenAmount {
        bytes32 mint;
        uint256 amount;
    }

    struct CollectionResult {
        uint64 resultId;
        uint64 round;
        bytes32 transitId;
        uint256 amountSent;
        bytes32[] mints;
        uint256[] sold;
        uint256[] obtained;
        uint256 amountToArrive;
    }

    struct Position {
        bytes32 program;
        bytes32 pool;
        bytes32 reserve;
        bytes32 position;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bytes32 token0;
        bytes32 token1;
        uint256 principal0;
        uint256 principal1;
        uint256 income0;
        uint256 income1;
    }

    /// @dev DEC-194: the closed-demo path refuses changed multipliers or issuer state.
    struct MintState {
        bytes32 mint;
        uint64 multiplierBits;
        uint64 newMultiplierBits;
        int64 effectiveAt;
        bool paused;
        bool frozen;
        bytes32 transferHook;
    }

    struct Report {
        bytes32 fundId;
        bytes32 mandateHash;
        bytes32 nativeMandateHash;
        uint64 sequence;
        uint256 spokeChainId;
        uint64 slot;
        uint64 timestamp;
        TokenAmount[] unallocated;
        Position[] positions;
        TokenAmount[] cumulativeIncome;
        TokenAmount[] collectedIncome;
        uint256 cumulativeReceived;
        uint256 cumulativeSentHome;
        ReportCodec.TransitAmount[] arrivedTransits;
        ReportCodec.HubBoundAmount[] inFlightToHub;
        bytes unwindResults;
        bytes collectionResults;
        MintState[] mintStates;
    }

    error NonCanonicalReport();

    /// @notice DEC-120, DEC-122, DEC-191: identical Hub result semantics without truncating native mints.
    function projectResults(Report memory native, SolanaSpokeRegistryV6 registry)
        internal
        view
        returns (bytes memory unwind, bytes memory collection)
    {
        unwind = native.unwindResults;
        if (unwind.length != 0) {
            if (!SpokeUnwindTypes.validResults(unwind)) revert NonCanonicalReport();
            SpokeUnwindTypes.OrderResult[] memory results = abi.decode(unwind, (SpokeUnwindTypes.OrderResult[]));
            for (uint256 index; index < results.length; ++index) {
                if (results[index].refunded) revert NonCanonicalReport();
            }
        }
        if (native.collectionResults.length == 0) return (unwind, collection);
        CollectionResult[] memory results = abi.decode(native.collectionResults, (CollectionResult[]));
        if (
            results.length > SpokeIncomeTypes.REPORTED_RESULTS
                || keccak256(native.collectionResults) != keccak256(abi.encode(results))
        ) revert NonCanonicalReport();
        SpokeIncomeTypes.CollectionResult[] memory projected = new SpokeIncomeTypes.CollectionResult[](results.length);
        for (uint256 index; index < results.length; ++index) {
            CollectionResult memory result = results[index];
            if (result.mints.length != result.sold.length || result.mints.length != result.obtained.length) {
                revert NonCanonicalReport();
            }
            address[] memory tokens = new address[](result.mints.length);
            for (uint256 token; token < tokens.length; ++token) {
                tokens[token] = registry.token(result.mints[token]);
                for (uint256 prior; prior < token; ++prior) {
                    if (tokens[token] == tokens[prior]) revert NonCanonicalReport();
                }
            }
            projected[index] = SpokeIncomeTypes.CollectionResult(
                result.resultId,
                result.round,
                result.transitId,
                result.amountSent,
                tokens,
                result.sold,
                result.obtained,
                result.amountToArrive
            );
        }
        collection = abi.encode(projected);
    }

    function encode(Report memory report) internal pure returns (bytes memory) {
        return abi.encode(VERSION, report);
    }

    function decode(bytes memory payload) internal pure returns (Report memory report) {
        uint256 version = ReportCodec.versionOf(payload);
        if (version != VERSION) revert ReportCodec.UnsupportedReportVersion(version);
        (, report) = abi.decode(payload, (uint256, Report));
        if (keccak256(payload) != keccak256(encode(report))) revert NonCanonicalReport();
    }
}
