// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransitMessage} from "../../src/libraries/TransitMessage.sol";
import {TransferKind} from "../../src/interfaces/FundTypes.sol";

contract TransitMessageHarness {
    function encode(bytes32 fundId, uint256 originChainId, bytes32 transitId, TransferKind kind)
        external
        pure
        returns (bytes memory)
    {
        return TransitMessage.encode(fundId, originChainId, transitId, kind);
    }

    function decode(bytes memory message) external pure returns (bytes32, uint256, bytes32, TransferKind) {
        return TransitMessage.decode(message);
    }
}

contract TransitMessageTest is Test {
    TransitMessageHarness internal h;

    function setUp() public {
        h = new TransitMessageHarness();
    }

    /// DEC-087, DEC-090: the vault-fixed message round-trips.
    function testFuzz_DEC090_roundTrip(bytes32 fundId, uint256 originChainId, bytes32 transitId, bool income)
        public
        view
    {
        TransferKind kind = income ? TransferKind.Income : TransferKind.Principal;
        (bytes32 f, uint256 c, bytes32 t, TransferKind k) = h.decode(h.encode(fundId, originChainId, transitId, kind));
        assertEq(f, fundId);
        assertEq(c, originChainId);
        assertEq(t, transitId);
        assertEq(uint8(k), uint8(kind));
    }

    function test_DEC090_unknownVersionReverts() public {
        bytes memory message = abi.encode(uint256(9), bytes32(0), uint256(0), bytes32(0), TransferKind.Principal);
        vm.expectRevert(abi.encodeWithSelector(TransitMessage.UnsupportedTransitMessageVersion.selector, 9));
        h.decode(message);
    }

    function test_DEC090_invalidKindReverts() public {
        bytes memory message = abi.encode(uint256(1), bytes32(0), uint256(0), bytes32(0), uint256(2));
        vm.expectRevert();
        h.decode(message);
    }
}
