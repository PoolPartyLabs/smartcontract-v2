// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {AdapterGuard} from "../../../src/adapters/AdapterGuard.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockAcrossSpokePool} from "../../mocks/across/MockAcrossSpokePool.sol";

/// @dev The twelve `depositV3` arguments, decoded from built calldata.
struct DepositArgs {
    address depositor;
    address recipient;
    address inputToken;
    address outputToken;
    uint256 inputAmount;
    uint256 outputAmount;
    uint256 destinationChainId;
    address exclusiveRelayer;
    uint32 quoteTimestamp;
    uint32 fillDeadline;
    uint32 exclusivityDeadline;
    bytes message;
}

contract AcrossBridgeAdapterTest is Test {
    uint32 internal constant INITIAL_DEPOSIT_ID = 4_700_821;

    MockAcrossSpokePool internal pool;
    AcrossBridgeAdapter internal adapter;

    address internal vault = makeAddr("vault");
    address internal guardian = makeAddr("guardian");
    address internal escrow = makeAddr("escrow");
    address internal spokeVault = makeAddr("spokeVault");
    address internal usdc = makeAddr("usdc");
    address internal usdg = makeAddr("usdg");
    address internal relayer = makeAddr("relayer");

    function setUp() public {
        vm.warp(1_790_000_000);
        pool = new MockAcrossSpokePool(INITIAL_DEPOSIT_ID);
        adapter = new AcrossBridgeAdapter(vault, guardian, address(pool));
    }

    // ------------------------------------------------------------------ helpers

    function _request() internal view returns (IBridgeAdapter.SendRequest memory req) {
        req = IBridgeAdapter.SendRequest({
            inputToken: usdc,
            outputToken: usdg,
            inputAmount: 1000e6,
            outputAmount: 999_400_000,
            destinationChainId: 4663,
            recipient: bytes32(uint256(uint160(spokeVault))),
            quoteTimestamp: uint32(block.timestamp - 60),
            exclusivityDeadline: 0,
            exclusiveRelayer: address(0),
            message: TransitMessage.encode(keccak256("fund"), 42_161, bytes32(uint256(7)), TransferKind.Principal)
        });
    }

    /// @dev External so the test can slice calldata.
    function decodeDeposit(bytes calldata data) external pure returns (bytes4 selector, DepositArgs memory a) {
        selector = bytes4(data[:4]);
        (a.depositor, a.recipient, a.inputToken, a.outputToken, a.inputAmount, a.outputAmount) =
            abi.decode(data[4:], (address, address, address, address, uint256, uint256));
        (a.destinationChainId, a.exclusiveRelayer, a.quoteTimestamp, a.fillDeadline, a.exclusivityDeadline) =
            abi.decode(data[4 + 6 * 32:], (uint256, address, uint32, uint32, uint32));
        uint256 messageOffset = abi.decode(data[4 + 11 * 32:4 + 12 * 32], (uint256));
        a.message = abi.decode(abi.encodePacked(uint256(32), data[4 + messageOffset:]), (bytes));
    }

    function _expectedCalldata(IBridgeAdapter.SendRequest memory req, address depositor, uint32 deadline)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            IAcrossSpokePool.depositV3,
            (
                depositor,
                address(uint160(uint256(req.recipient))),
                req.inputToken,
                req.outputToken,
                req.inputAmount,
                req.outputAmount,
                req.destinationChainId,
                req.exclusiveRelayer,
                req.quoteTimestamp,
                deadline,
                req.exclusivityDeadline,
                req.message
            )
        );
    }

    function _assertEncodes(IBridgeAdapter.SendRequest memory req, address depositor) internal view {
        IBridgeAdapter.BridgeCall memory call = adapter.buildSend(req, depositor);
        (bytes4 selector, DepositArgs memory a) = this.decodeDeposit(call.data);
        uint32 expectedDeadline = uint32(block.timestamp) + 21_600;

        assertEq(selector, IAcrossSpokePool.depositV3.selector, "selector");
        assertEq(a.depositor, depositor, "depositor");
        assertEq(a.recipient, address(uint160(uint256(req.recipient))), "recipient");
        assertEq(a.inputToken, req.inputToken, "inputToken");
        assertEq(a.outputToken, req.outputToken, "outputToken");
        assertEq(a.inputAmount, req.inputAmount, "inputAmount");
        assertEq(a.outputAmount, req.outputAmount, "outputAmount");
        assertEq(a.destinationChainId, req.destinationChainId, "destinationChainId");
        assertEq(a.exclusiveRelayer, req.exclusiveRelayer, "exclusiveRelayer");
        assertEq(a.quoteTimestamp, req.quoteTimestamp, "quoteTimestamp");
        assertEq(a.fillDeadline, expectedDeadline, "fillDeadline in data");
        assertEq(a.exclusivityDeadline, req.exclusivityDeadline, "exclusivityDeadline");
        assertEq(a.message, req.message, "message");

        assertEq(call.target, address(pool), "target");
        assertEq(call.transitRef, bytes32(uint256(pool.numberOfDeposits())), "transitRef");
        assertEq(call.amountToArrive, req.outputAmount, "amountToArrive");
        assertEq(call.fillDeadline, expectedDeadline, "fillDeadline");

        // Whole-calldata equality: nothing beyond the twelve fields is encoded.
        assertEq(call.data, _expectedCalldata(req, depositor, expectedDeadline), "calldata");
    }

    // ------------------------------------------------------------------ construction and constants

    function test_DEC087_constructorStoresVaultGuardianAndTarget() public view {
        assertEq(adapter.vault(), vault);
        assertEq(adapter.guardian(), guardian);
        assertEq(adapter.target(), address(pool));
        assertEq(adapter.spokePool(), address(pool));
        assertFalse(adapter.paused());
        assertFalse(adapter.deprecated());
    }

    function test_DEC087_protocolIdIsAcrossV3() public view {
        assertEq(adapter.protocolId(), keccak256("ACROSS_V3"));
        assertEq(adapter.PROTOCOL_ID(), keccak256("ACROSS_V3"));
    }

    function test_DEC066_fillDeadlineSecondsIsSixHours() public view {
        assertEq(adapter.fillDeadlineSeconds(), 21_600);
        assertEq(adapter.FILL_DEADLINE_SECONDS(), 6 hours);
    }

    function test_DEC087_constructorRejectsZeroAddresses() public {
        vm.expectRevert(AcrossBridgeAdapter.ZeroVault.selector);
        new AcrossBridgeAdapter(address(0), guardian, address(pool));
        vm.expectRevert(AcrossBridgeAdapter.ZeroSpokePool.selector);
        new AcrossBridgeAdapter(vault, guardian, address(0));
        vm.expectRevert(AdapterGuard.ZeroGuardian.selector);
        new AcrossBridgeAdapter(vault, address(0), address(pool));
    }

    function test_DEC066_constructorRejectsShortFillDeadlineBuffer() public {
        pool.setFillDeadlineBuffer(21_599);
        vm.expectRevert(abi.encodeWithSelector(AcrossBridgeAdapter.FillDeadlineBufferTooShort.selector, 21_599));
        new AcrossBridgeAdapter(vault, guardian, address(pool));
        pool.setFillDeadlineBuffer(21_600);
        new AcrossBridgeAdapter(vault, guardian, address(pool));
    }

    // ------------------------------------------------------------------ buildSend encoding

    function test_DEC087_buildSendEncodesEveryFieldAsReceived() public view {
        _assertEncodes(_request(), escrow);
    }

    function test_DEC087_buildSendEncodesExclusivityAsReceived() public view {
        IBridgeAdapter.SendRequest memory req = _request();
        req.exclusiveRelayer = relayer;
        req.exclusivityDeadline = uint32(block.timestamp + 30);
        _assertEncodes(req, escrow);
        req.exclusivityDeadline = 30; // offset form, the SpokePool adds the deposit time
        _assertEncodes(req, escrow);
    }

    function test_DEC087_buildSendEncodesEmptyMessage() public view {
        IBridgeAdapter.SendRequest memory req = _request();
        req.message = "";
        _assertEncodes(req, escrow);
    }

    /// DEC-087: no substitution for any combination of fields the vault fixes.
    function testFuzz_DEC087_buildSendNeverSubstitutesFields(
        IBridgeAdapter.SendRequest memory req,
        address depositor,
        uint32 timestamp
    ) public {
        req.inputAmount = bound(req.inputAmount, 1, type(uint256).max);
        req.outputAmount = bound(req.outputAmount, 1, req.inputAmount);
        req.recipient = bytes32(uint256(bound(uint256(req.recipient), 1, type(uint160).max)));
        vm.assume(depositor != address(0));
        vm.warp(bound(timestamp, 60, type(uint32).max - 21_600));
        _assertEncodes(req, depositor);
    }

    /// DEC-066: the fill deadline is always the build time plus 6 h, in the call and in the struct.
    function testFuzz_DEC066_fillDeadlineIsBuildTimePlusSixHours(uint32 timestamp) public {
        timestamp = uint32(bound(timestamp, 60, type(uint32).max - 21_600));
        vm.warp(timestamp);
        IBridgeAdapter.BridgeCall memory call = adapter.buildSend(_request(), escrow);
        (, DepositArgs memory a) = this.decodeDeposit(call.data);
        assertEq(call.fillDeadline, timestamp + 21_600);
        assertEq(a.fillDeadline, call.fillDeadline);
    }

    /// DEC-085: In-flight Value counts at the quote's output amount.
    function test_DEC085_amountToArriveIsOutputAmount() public view {
        IBridgeAdapter.SendRequest memory req = _request();
        assertEq(adapter.buildSend(req, escrow).amountToArrive, 999_400_000);
    }

    /// DEC-090: the transit reference is the deposit id the next deposit gets.
    function test_DEC090_transitRefIsNextDepositId() public {
        assertEq(adapter.buildSend(_request(), escrow).transitRef, bytes32(uint256(INITIAL_DEPOSIT_ID)));
        pool.setNumberOfDeposits(type(uint32).max);
        assertEq(adapter.buildSend(_request(), escrow).transitRef, bytes32(uint256(type(uint32).max)));
    }

    /// DEC-056, DEC-058: the adapter does not gate sends itself (the send home must stay open); the Core Vault reads
    /// the flags on a hub-to-spoke send.
    function test_DEC056_buildSendIgnoresPauseAndDeprecation() public {
        vm.startPrank(guardian);
        adapter.setPaused(true);
        _assertEncodes(_request(), escrow);
        adapter.deprecate();
        vm.stopPrank();
        _assertEncodes(_request(), escrow);
    }

    // ------------------------------------------------------------------ buildSend validation

    function test_DEC087_buildSendRejectsZeroInput() public {
        IBridgeAdapter.SendRequest memory req = _request();
        req.inputAmount = 0;
        vm.expectRevert(abi.encodeWithSelector(IBridgeAdapter.InvalidAmounts.selector, 0, req.outputAmount));
        adapter.buildSend(req, escrow);
    }

    /// DEC-087 (a bridge is an Adapter whose interface the vault relies on): the InvalidAmounts rule comes from the
    /// IBridgeAdapter NatSpec ("zero input or output amount, or output above input"), not from DEC-085.
    function test_DEC087_buildSendRejectsZeroOutput() public {
        IBridgeAdapter.SendRequest memory req = _request();
        req.outputAmount = 0;
        vm.expectRevert(abi.encodeWithSelector(IBridgeAdapter.InvalidAmounts.selector, req.inputAmount, 0));
        adapter.buildSend(req, escrow);
    }

    function test_DEC087_buildSendRejectsOutputAboveInput() public {
        IBridgeAdapter.SendRequest memory req = _request();
        req.outputAmount = req.inputAmount + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IBridgeAdapter.InvalidAmounts.selector, req.inputAmount, req.inputAmount + 1)
        );
        adapter.buildSend(req, escrow);
    }

    function test_DEC087_buildSendAcceptsOutputEqualToInput() public view {
        IBridgeAdapter.SendRequest memory req = _request();
        req.outputAmount = req.inputAmount;
        _assertEncodes(req, escrow);
    }

    function test_DEC066_buildSendRejectsZeroDepositor() public {
        vm.expectRevert(IBridgeAdapter.InvalidParty.selector);
        adapter.buildSend(_request(), address(0));
    }

    function test_DEC087_buildSendRejectsZeroRecipient() public {
        IBridgeAdapter.SendRequest memory req = _request();
        req.recipient = bytes32(0);
        vm.expectRevert(IBridgeAdapter.InvalidParty.selector);
        adapter.buildSend(req, escrow);
    }

    /// DEC-087: a universal address with bits above 160 is not truncated into a different recipient.
    function testFuzz_DEC087_buildSendRejectsNonEvmRecipient(uint256 word) public {
        word = bound(word, uint256(type(uint160).max) + 1, type(uint256).max);
        IBridgeAdapter.SendRequest memory req = _request();
        req.recipient = bytes32(word);
        vm.expectRevert(IBridgeAdapter.InvalidParty.selector);
        adapter.buildSend(req, escrow);
    }

    /// @dev Security review S-23: a SpokePool buffer lowered after deployment shortens the window instead of making
    ///      every send (the send home included) revert; a zero buffer is refused.
    function test_SEC_S23_fillDeadlineFollowsALoweredSpokePoolBuffer() public {
        pool.setFillDeadlineBuffer(3 hours);
        IBridgeAdapter.BridgeCall memory call = adapter.buildSend(_request(), makeAddr("escrow"));
        assertEq(call.fillDeadline, block.timestamp + 3 hours, "S-23: the lower buffer");

        pool.setFillDeadlineBuffer(12 hours);
        call = adapter.buildSend(_request(), makeAddr("escrow"));
        assertEq(call.fillDeadline, block.timestamp + 6 hours, "never above the DEC-066 constant");

        pool.setFillDeadlineBuffer(0);
        vm.expectRevert(abi.encodeWithSelector(AcrossBridgeAdapter.FillDeadlineBufferTooShort.selector, 0));
        adapter.buildSend(_request(), makeAddr("escrow"));
    }
}
