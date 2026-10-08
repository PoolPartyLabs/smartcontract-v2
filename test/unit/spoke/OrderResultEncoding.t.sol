// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";

contract OrderResultEncodingTest is Test {
    function test_REGRESSION_encoderAndDecoderShareActualAbiStride() public pure {
        SpokeUnwindTypes.OrderResult memory result;
        assertEq(abi.encode(result).length, SpokeUnwindTypes.ENCODED_RESULT_SIZE);
        for (uint256 count; count <= SpokeUnwindTypes.REPORTED_RESULTS; ++count) {
            SpokeUnwindTypes.OrderResult[] memory results = new SpokeUnwindTypes.OrderResult[](count);
            for (uint256 index; index < count; ++index) {
                results[index].requestId = keccak256(abi.encode(index));
                results[index].attempt = uint32(index + 1);
                results[index].refunded = index % 2 == 0;
                results[index].closureExcessCost = type(uint256).max;
            }
            bytes memory encoded = SpokeUnwindTypes.encodeResults(results);
            assertEq(encoded.length, 64 + count * SpokeUnwindTypes.ENCODED_RESULT_SIZE);
            assertTrue(SpokeUnwindTypes.validResults(encoded));
            assertEq(abi.encode(abi.decode(encoded, (SpokeUnwindTypes.OrderResult[]))), encoded);
        }
    }

    function test_REGRESSION_rejectsMalformedLaterResultWords() public pure {
        SpokeUnwindTypes.OrderResult[] memory results = new SpokeUnwindTypes.OrderResult[](2);
        bytes memory encoded = SpokeUnwindTypes.encodeResults(results);
        uint256 entry = 96 + SpokeUnwindTypes.ENCODED_RESULT_SIZE;
        assembly ("memory-safe") { mstore(add(add(encoded, entry), 64), 0x100000000) }
        assertFalse(SpokeUnwindTypes.validResults(encoded));
        assembly ("memory-safe") {
            mstore(add(add(encoded, entry), 64), 1)
            mstore(add(add(encoded, entry), 352), 2)
        }
        assertFalse(SpokeUnwindTypes.validResults(encoded));
    }
}
