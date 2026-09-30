// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";

/// @dev External surface so a revert can be observed as a failed call.
contract CodecSymbolicHarness {
    function decodeReport(bytes memory payload) external pure returns (ReportCodec.Report memory) {
        return ReportCodec.decode(payload);
    }

    function decodeMessage(bytes memory message) external pure returns (bytes32, uint256, bytes32, TransferKind) {
        return TransitMessage.decode(message);
    }
}

/// @title Symbolic properties of ReportCodec and TransitMessage (Halmos `check_` functions)
/// @notice Run with `halmos --match-contract CodecSymbolicTest`. `decode(encode(x)) == x` for every input also proves
///         that two distinct inputs never share an encoding (a collision would decode to two different values).
contract CodecSymbolicTest is Test {
    CodecSymbolicHarness internal h;

    function setUp() public {
        h = new CodecSymbolicHarness();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // TransitMessage (DEC-087, DEC-090, DEC-092)
    // ---------------------------------------------------------------------------------------------------------------

    /// decode(encode(x)) == x for every fund id, origin chain, transit id and kind.
    function check_DEC090_transitMessageRoundTrip(bytes32 fundId, uint256 originChainId, bytes32 transitId, bool income)
        public
        pure
    {
        TransferKind kind = income ? TransferKind.Income : TransferKind.Principal;
        (bytes32 f, uint256 c, bytes32 t, TransferKind k) =
            TransitMessage.decode(TransitMessage.encode(fundId, originChainId, transitId, kind));
        assert(f == fundId);
        assert(c == originChainId);
        assert(t == transitId);
        assert(k == kind);
    }

    /// Two messages that differ in any field never share an encoding.
    function check_DEC090_transitMessageNeverCollides(
        bytes32 fundA,
        uint256 chainA,
        bytes32 transitA,
        bool incomeA,
        bytes32 fundB,
        uint256 chainB,
        bytes32 transitB,
        bool incomeB
    ) public pure {
        vm.assume(fundA != fundB || chainA != chainB || transitA != transitB || incomeA != incomeB);
        bytes memory a =
            TransitMessage.encode(fundA, chainA, transitA, incomeA ? TransferKind.Income : TransferKind.Principal);
        bytes memory b =
            TransitMessage.encode(fundB, chainB, transitB, incomeB ? TransferKind.Income : TransferKind.Principal);
        assert(a.length == b.length);
        bool differs;
        for (uint256 i; i < a.length; i += 32) {
            bytes32 wordA;
            bytes32 wordB;
            assembly ("memory-safe") {
                wordA := mload(add(add(a, 0x20), i))
                wordB := mload(add(add(b, 0x20), i))
            }
            if (wordA != wordB) differs = true;
        }
        assert(differs);
    }

    /// A message with any version other than the current one is rejected.
    function check_DEC090_transitMessageRejectsOtherVersions(
        uint256 version,
        bytes32 fundId,
        uint256 originChainId,
        bytes32 transitId
    ) public view {
        vm.assume(version != TransitMessage.VERSION);
        bytes memory message = abi.encode(version, fundId, originChainId, transitId, TransferKind.Principal);
        (bool ok,) = address(h).staticcall(abi.encodeCall(h.decodeMessage, (message)));
        assert(!ok);
    }

    /// A message whose kind word is not a TransferKind is rejected, never read as Principal or Income.
    function check_DEC092_transitMessageRejectsUnknownKind(uint256 kindWord, bytes32 fundId, bytes32 transitId)
        public
        view
    {
        vm.assume(kindWord > uint256(type(TransferKind).max));
        bytes memory message = abi.encode(TransitMessage.VERSION, fundId, uint256(42_161), transitId, kindWord);
        (bool ok,) = address(h).staticcall(abi.encodeCall(h.decodeMessage, (message)));
        assert(!ok);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ReportCodec (DEC-070, DEC-086, DEC-093)
    // ---------------------------------------------------------------------------------------------------------------

    /// decode(encode(x)) == x for a report with every scalar symbolic and one symbolic entry in each list.
    function check_DEC093_reportRoundTrip(
        ReportCodec.TokenAmount memory tokenAmount,
        ReportCodec.PositionReport memory position,
        ReportCodec.TransitAmount memory arrived,
        bytes32 hubBoundId,
        uint256 hubBoundAmount,
        bool hubBoundIncome,
        uint256[8] memory scalars
    ) public pure {
        ReportCodec.Report memory r = _report(
            tokenAmount, position, arrived, hubBoundId, hubBoundAmount, hubBoundIncome, scalars
        );
        ReportCodec.Report memory d = ReportCodec.decode(ReportCodec.encode(r));

        assert(d.fundId == r.fundId);
        assert(d.sequence == r.sequence);
        assert(d.spokeChainId == r.spokeChainId);
        assert(d.blockNumber == r.blockNumber);
        assert(d.timestamp == r.timestamp);
        assert(d.operatingCash == r.operatingCash);
        assert(d.cumulativeReceived == r.cumulativeReceived);
        assert(d.cumulativeSentHome == r.cumulativeSentHome);

        assert(d.unallocated.length == 1 && d.cumulativeIncome.length == 1 && d.collectedIncome.length == 1);
        assert(d.unallocated[0].token == tokenAmount.token && d.unallocated[0].amount == tokenAmount.amount);
        assert(d.cumulativeIncome[0].token == tokenAmount.token);
        assert(d.cumulativeIncome[0].amount == scalars[6]);
        assert(d.collectedIncome[0].token == tokenAmount.token);
        assert(d.collectedIncome[0].amount == scalars[7]);

        assert(d.positions.length == 1);
        _assertSamePosition(d.positions[0], position);

        assert(d.arrivedTransits.length == 1);
        assert(d.arrivedTransits[0].transitId == arrived.transitId && d.arrivedTransits[0].amount == arrived.amount);

        assert(d.inFlightToHub.length == 1);
        assert(d.inFlightToHub[0].transitId == hubBoundId && d.inFlightToHub[0].amount == hubBoundAmount);
        assert(d.inFlightToHub[0].kind == (hubBoundIncome ? TransferKind.Income : TransferKind.Principal));
    }

    /// An empty report round-trips too (every list empty).
    function check_DEC093_emptyReportRoundTrip(bytes32 fundId, uint64 sequence, uint256 spokeChainId, uint64 timestamp)
        public
        pure
    {
        ReportCodec.Report memory r;
        r.fundId = fundId;
        r.sequence = sequence;
        r.spokeChainId = spokeChainId;
        r.timestamp = timestamp;
        ReportCodec.Report memory d = ReportCodec.decode(ReportCodec.encode(r));
        assert(d.fundId == fundId && d.sequence == sequence && d.spokeChainId == spokeChainId);
        assert(d.timestamp == timestamp && d.blockNumber == 0);
        assert(d.unallocated.length == 0 && d.positions.length == 0 && d.cumulativeIncome.length == 0);
        assert(d.collectedIncome.length == 0 && d.arrivedTransits.length == 0 && d.inFlightToHub.length == 0);
    }

    /// The version word is what `versionOf` reads and a payload with any other version is never decoded.
    function check_Q57_reportRejectsOtherVersions(uint256 version, bytes32 fundId, uint64 sequence) public view {
        vm.assume(version != ReportCodec.VERSION);
        ReportCodec.Report memory r;
        r.fundId = fundId;
        r.sequence = sequence;
        bytes memory payload = abi.encode(version, r);
        assert(ReportCodec.versionOf(payload) == version);
        (bool ok,) = address(h).staticcall(abi.encodeCall(h.decodeReport, (payload)));
        assert(!ok);
    }

    /// A payload shorter than one word is rejected before any read.
    function check_Q57_reportRejectsShortPayload(bytes31 short) public view {
        bytes memory payload = abi.encodePacked(short);
        (bool ok,) = address(h).staticcall(abi.encodeCall(h.decodeReport, (payload)));
        assert(!ok);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _report(
        ReportCodec.TokenAmount memory tokenAmount,
        ReportCodec.PositionReport memory position,
        ReportCodec.TransitAmount memory arrived,
        bytes32 hubBoundId,
        uint256 hubBoundAmount,
        bool hubBoundIncome,
        uint256[8] memory scalars
    ) internal pure returns (ReportCodec.Report memory r) {
        r.fundId = bytes32(scalars[0]);
        r.sequence = uint64(scalars[1]);
        r.spokeChainId = scalars[2];
        r.blockNumber = uint64(scalars[3]);
        r.timestamp = uint64(scalars[4]);
        r.operatingCash = scalars[5];
        r.cumulativeReceived = scalars[6];
        r.cumulativeSentHome = scalars[7];
        r.unallocated = new ReportCodec.TokenAmount[](1);
        r.unallocated[0] = tokenAmount;
        r.cumulativeIncome = new ReportCodec.TokenAmount[](1);
        r.cumulativeIncome[0] = ReportCodec.TokenAmount(tokenAmount.token, scalars[6]);
        r.collectedIncome = new ReportCodec.TokenAmount[](1);
        r.collectedIncome[0] = ReportCodec.TokenAmount(tokenAmount.token, scalars[7]);
        r.positions = new ReportCodec.PositionReport[](1);
        r.positions[0] = position;
        r.arrivedTransits = new ReportCodec.TransitAmount[](1);
        r.arrivedTransits[0] = arrived;
        r.inFlightToHub = new ReportCodec.HubBoundAmount[](1);
        r.inFlightToHub[0] = ReportCodec.HubBoundAmount(
            hubBoundId, hubBoundAmount, hubBoundIncome ? TransferKind.Income : TransferKind.Principal
        );
    }

    function _assertSamePosition(ReportCodec.PositionReport memory a, ReportCodec.PositionReport memory b)
        internal
        pure
    {
        assert(a.adapter == b.adapter && a.poolKey == b.poolKey && a.poolId == b.poolId);
        assert(a.tickLower == b.tickLower && a.tickUpper == b.tickUpper && a.liquidity == b.liquidity);
        assert(a.token0 == b.token0 && a.token1 == b.token1);
        assert(a.principal0 == b.principal0 && a.principal1 == b.principal1);
        assert(a.income0 == b.income0 && a.income1 == b.income1);
    }
}
