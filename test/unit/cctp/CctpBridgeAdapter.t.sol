pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CctpBridgeAdapter} from "../../../src/adapters/CctpBridgeAdapter.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {CctpRoute} from "../../../src/interfaces/ICctpCoreVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";

contract CctpBridgeAdapterTest is Test {
    CctpBridgeAdapter internal adapter;
    CctpRoute internal route;
    address internal constant USDC = address(0x1234);
    uint256 internal constant SOLANA = 777;

    function setUp() public {
        vm.chainId(42_161);
        route = CctpRoute(
            keccak256("fund"),
            SOLANA,
            bytes32(type(uint256).max),
            keccak256("receive-pda"),
            keccak256("messenger"),
            keccak256("usdc"),
            keccak256("authority")
        );
        adapter = new CctpBridgeAdapter(address(this), address(this), address(0x5555), USDC, route, 20_000);
    }

    function testFuzz_DEC191_roundFeeUpAndBookConservativeMinimum(uint64 amount, uint256 rate) public view {
        amount = uint64(bound(amount, 2, type(uint64).max));
        rate = bound(rate, 0, 20_000);
        uint256 expectedFee = (uint256(amount) * rate + 100_000_000 - 1) / 100_000_000;
        (uint256 net, uint256 rateWad) = adapter.quoteSend(USDC, SOLANA, amount, abi.encode(rate));
        assertEq(net, amount - expectedFee);
        assertEq(rateWad, rate * 1e10);
    }

    function test_DEC191_fractionalCircleBpsAreNotTruncated() public view {
        (uint256 net,) = adapter.quoteSend(USDC, SOLANA, 1000e6, abi.encode(uint256(14_000)));
        assertEq(net, 999_860_000);
    }

    function test_DEC199_hardCeilingRejectsHigherDeploymentAndQuote() public {
        vm.expectRevert(CctpBridgeAdapter.InvalidFee.selector);
        new CctpBridgeAdapter(address(this), address(this), address(0x5555), USDC, route, 50_001);
        CctpBridgeAdapter capped =
            new CctpBridgeAdapter(address(this), address(this), address(0x5555), USDC, route, 50_000);
        (uint256 net,) = capped.quoteSend(USDC, SOLANA, 1000e6, abi.encode(uint256(50_000)));
        assertEq(net, 999_500_000);
        vm.expectRevert(CctpBridgeAdapter.InvalidFee.selector);
        capped.quoteSend(USDC, SOLANA, 1000e6, abi.encode(uint256(50_001)));
    }

    function test_DEC191_rejectUnboundedEmptyAndZeroNetQuotes() public {
        vm.expectRevert(CctpBridgeAdapter.InvalidFee.selector);
        adapter.quoteSend(USDC, SOLANA, 1000e6, abi.encode(uint256(20_001)));
        vm.expectRevert(CctpBridgeAdapter.InvalidFee.selector);
        adapter.quoteSend(USDC, SOLANA, 1000e6, "");
        vm.expectRevert(CctpBridgeAdapter.InvalidFee.selector);
        adapter.quoteSend(USDC, SOLANA, 1, abi.encode(uint256(14_000)));
    }

    function test_DEC191_rejectUnsupportedTokenDomainAndU64Overflow() public {
        vm.expectRevert(CctpBridgeAdapter.InvalidRequest.selector);
        adapter.quoteSend(address(0x4321), SOLANA, 1000e6, abi.encode(uint256(14_000)));
        vm.expectRevert(CctpBridgeAdapter.InvalidRequest.selector);
        adapter.quoteSend(USDC, 5, 1000e6, abi.encode(uint256(14_000)));
        vm.expectRevert(CctpBridgeAdapter.InvalidRequest.selector);
        adapter.quoteSend(USDC, SOLANA, uint256(type(uint64).max) + 1, abi.encode(uint256(14_000)));
    }

    function test_DEC191_buildCannotRedirectDestinationOrForgeFund() public {
        IBridgeAdapter.SendRequest memory request = IBridgeAdapter.SendRequest(
            USDC,
            address(0),
            1000e6,
            SOLANA,
            route.mintRecipient,
            TransitMessage.encode(route.fundId, 42_161, bytes32(uint256(1)), TransferKind.Principal)
        );
        request.recipient = bytes32(uint256(1));
        vm.expectRevert(CctpBridgeAdapter.InvalidRequest.selector);
        adapter.buildSend(request, address(this), abi.encode(uint256(14_000)));
        request.recipient = route.mintRecipient;
        request.message =
            TransitMessage.encode(keccak256("wrong-fund"), 42_161, bytes32(uint256(1)), TransferKind.Principal);
        vm.expectRevert(CctpBridgeAdapter.InvalidRequest.selector);
        adapter.buildSend(request, address(this), abi.encode(uint256(14_000)));
    }

    function test_DEC191_onlyVaultBuildsAndNoCallerCanExpire() public {
        IBridgeAdapter.SendRequest memory request;
        vm.prank(address(0x9999));
        vm.expectRevert(abi.encodeWithSelector(IBridgeAdapter.NotVault.selector, address(0x9999)));
        adapter.buildSend(request, address(this), abi.encode(uint256(14_000)));
        vm.expectRevert(CctpBridgeAdapter.NoExpiry.selector);
        adapter.noteExpiry(bytes32(uint256(1)));
        assertEq(adapter.fillDeadlineSeconds(), 0);
    }
}
