pragma solidity 0.8.28;

import {ReportCodec} from "./ReportCodec.sol";

/// @notice Lossless Solana report ABI for new Funds only (DEC-188, DEC-192).
/// @dev The v5 accounting projection is never the wire format. See docs/SOLANA-REPORT-V6.md.
library ReportCodecV6 {
    uint256 internal constant VERSION = 6;

    struct TokenAmount {
        bytes32 mint;
        uint256 amount;
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
