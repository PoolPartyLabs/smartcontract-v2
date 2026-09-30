// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransferKind} from "../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../src/libraries/ReportCodec.sol";

contract ReportCodecHarness {
    function encode(ReportCodec.Report memory r) external pure returns (bytes memory) {
        return ReportCodec.encode(r);
    }

    function decode(bytes memory payload) external pure returns (ReportCodec.Report memory) {
        return ReportCodec.decode(payload);
    }

    function versionOf(bytes memory payload) external pure returns (uint256) {
        return ReportCodec.versionOf(payload);
    }
}

contract ReportCodecTest is Test {
    ReportCodecHarness internal h;

    function setUp() public {
        h = new ReportCodecHarness();
    }

    function _sample() internal pure returns (ReportCodec.Report memory r) {
        r.fundId = keccak256("fund-1");
        r.mandateHash = keccak256("mandate-1");
        r.sequence = 7;
        r.spokeChainId = 4663;
        r.blockNumber = 123_456_789;
        r.timestamp = 1_790_690_640;
        r.unallocated = new ReportCodec.TokenAmount[](2);
        r.unallocated[0] = ReportCodec.TokenAmount(address(0x5fc5), 1_234_567);
        r.unallocated[1] = ReportCodec.TokenAmount(address(0x0bd7), 3e17);
        r.positions = new ReportCodec.PositionReport[](1);
        r.positions[0] = ReportCodec.PositionReport({
            adapter: address(0xADA),
            poolKey: keccak256("pool"),
            poolId: keccak256("poolId"),
            tickLower: -887_220,
            tickUpper: 887_220,
            liquidity: type(uint128).max,
            token0: address(0x0bd7),
            token1: address(0x5fc5),
            principal0: 1e18,
            principal1: 2500e6,
            income0: 1e15,
            income1: 3e6
        });
        r.cumulativeIncome = new ReportCodec.TokenAmount[](1);
        r.cumulativeIncome[0] = ReportCodec.TokenAmount(address(0x5fc5), 42e6);
        r.collectedIncome = new ReportCodec.TokenAmount[](1);
        r.collectedIncome[0] = ReportCodec.TokenAmount(address(0x5fc5), 7e6);
        r.operatingCash = 10e6;
        r.cumulativeReceived = 10_000e6;
        r.cumulativeSentHome = 1000e6;
        r.arrivedTransits = new ReportCodec.TransitAmount[](1);
        r.arrivedTransits[0] = ReportCodec.TransitAmount(keccak256("t1"), 9994e6);
        r.inFlightToHub = new ReportCodec.HubBoundAmount[](1);
        r.inFlightToHub[0] = ReportCodec.HubBoundAmount(keccak256("t2"), 999e6, TransferKind.Income);
    }

    function _assertSame(ReportCodec.Report memory a, ReportCodec.Report memory b) internal pure {
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)));
    }

    function test_DEC093_roundTripOfSampleReport() public view {
        ReportCodec.Report memory r = _sample();
        bytes memory payload = h.encode(r);
        assertEq(h.versionOf(payload), ReportCodec.VERSION);
        ReportCodec.Report memory d = h.decode(payload);
        _assertSame(r, d);
        assertEq(d.mandateHash, keccak256("mandate-1"), "S-6: the Spoke Vault's Mandate hash travels");
        assertEq(d.positions[0].tickLower, -887_220);
        assertEq(d.inFlightToHub[0].amount, 999e6);
        assertEq(uint8(d.inFlightToHub[0].kind), uint8(TransferKind.Income), "CV-OQ-1: the kind travels");
    }

    function test_DEC093_roundTripOfEmptyReport() public view {
        ReportCodec.Report memory r;
        _assertSame(r, h.decode(h.encode(r)));
    }

    /// Q57: the payload is versioned; an unknown version is rejected before decoding.
    function test_Q57_unknownVersionReverts() public {
        bytes memory payload = abi.encode(uint256(1), _sample());
        vm.expectRevert(abi.encodeWithSelector(ReportCodec.UnsupportedReportVersion.selector, 1));
        h.decode(payload);
        payload = abi.encode(uint256(2), _sample());
        vm.expectRevert(abi.encodeWithSelector(ReportCodec.UnsupportedReportVersion.selector, 2));
        h.decode(payload);
        payload = abi.encode(uint256(4), _sample());
        vm.expectRevert(abi.encodeWithSelector(ReportCodec.UnsupportedReportVersion.selector, 4));
        h.decode(payload);
        payload = abi.encode(uint256(0), _sample());
        vm.expectRevert(abi.encodeWithSelector(ReportCodec.UnsupportedReportVersion.selector, 0));
        h.decode(payload);
    }

    function test_Q57_shortPayloadReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ReportCodec.ReportPayloadTooShort.selector, 31));
        h.decode(new bytes(31));
    }

    function test_Q57_malformedBodyReverts() public {
        // Correct version word, truncated body.
        bytes memory payload = abi.encodePacked(ReportCodec.VERSION, uint256(64));
        vm.expectRevert();
        h.decode(payload);
    }

    /// DEC-093: any report round-trips through encode/decode.
    function testFuzz_DEC093_roundTrip(
        uint256 seed,
        uint8 nUnallocated,
        uint8 nPositions,
        uint8 nIncome,
        uint8 nArrived,
        uint8 nInFlight
    ) public view {
        ReportCodec.Report memory r;
        r.fundId = keccak256(abi.encode(seed, "fund"));
        r.sequence = uint64(seed);
        r.spokeChainId = seed >> 64;
        r.blockNumber = uint64(seed >> 8);
        r.timestamp = uint64(seed >> 16);
        r.cumulativeReceived = uint256(keccak256(abi.encode(seed, "received")));
        r.cumulativeSentHome = uint256(keccak256(abi.encode(seed, "sent")));
        r.unallocated = _tokenAmounts(seed, nUnallocated % 8, "unallocated");
        r.cumulativeIncome = _tokenAmounts(seed, nIncome % 8, "income");
        r.collectedIncome = _tokenAmounts(seed, nIncome % 5, "collected");
        r.operatingCash = seed >> 32;
        r.arrivedTransits = _transitAmounts(seed, nArrived % 8, "arrived");
        r.inFlightToHub = _hubBoundAmounts(seed, nInFlight % 8, "inflight");
        r.positions = new ReportCodec.PositionReport[](nPositions % 6);
        for (uint256 i; i < r.positions.length; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, "position", i)));
            r.positions[i] = ReportCodec.PositionReport({
                adapter: address(uint160(x)),
                poolKey: bytes32(x),
                poolId: keccak256(abi.encode(x)),
                tickLower: int24(int256(x % 1_774_544) - 887_272),
                tickUpper: int24(int256((x >> 32) % 1_774_544) - 887_272),
                liquidity: uint128(x >> 64),
                token0: address(uint160(x >> 8)),
                token1: address(uint160(x >> 16)),
                principal0: x >> 1,
                principal1: x >> 2,
                income0: x >> 3,
                income1: x >> 4
            });
        }
        _assertSame(r, h.decode(h.encode(r)));
    }

    function _tokenAmounts(uint256 seed, uint256 n, string memory tag)
        internal
        pure
        returns (ReportCodec.TokenAmount[] memory out)
    {
        out = new ReportCodec.TokenAmount[](n);
        for (uint256 i; i < n; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, tag, i)));
            out[i] = ReportCodec.TokenAmount(address(uint160(x)), x);
        }
    }

    function _transitAmounts(uint256 seed, uint256 n, string memory tag)
        internal
        pure
        returns (ReportCodec.TransitAmount[] memory out)
    {
        out = new ReportCodec.TransitAmount[](n);
        for (uint256 i; i < n; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, tag, i)));
            out[i] = ReportCodec.TransitAmount(bytes32(x), x >> 3);
        }
    }

    function _hubBoundAmounts(uint256 seed, uint256 n, string memory tag)
        internal
        pure
        returns (ReportCodec.HubBoundAmount[] memory out)
    {
        out = new ReportCodec.HubBoundAmount[](n);
        for (uint256 i; i < n; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, tag, i)));
            out[i] = ReportCodec.HubBoundAmount(bytes32(x), x >> 3, TransferKind(x % 2));
        }
    }
}
