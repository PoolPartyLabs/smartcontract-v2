// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {AdapterGuard} from "../../../src/adapters/AdapterGuard.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {BridgeFeeRule} from "../../../src/libraries/BridgeFeeRule.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockAcrossSpokePool} from "../../mocks/across/MockAcrossSpokePool.sol";
import {MockAcrossToken} from "../../mocks/across/MockAcrossToken.sol";

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

/// @dev An input token with any number of decimals, for the fixed part of the fee.
contract DecimalsToken {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

/// @notice AcrossBridgeAdapter: the vault fixes the route, the recipient, the tokens, the amount sent and the message;
///         the adapter fixes the amount to arrive with its fee rule and every other Across term (DEC-158, DEC-162).
contract AcrossBridgeAdapterTest is Test {
    uint32 internal constant INITIAL_DEPOSIT_ID = 4_700_821;
    uint256 internal constant SPOKE_CHAIN = 4663;
    uint256 internal constant AMOUNT = 1000e6;
    /// @dev 0.08% of 1,000 plus 0.03 (DEC-162 "MVP minimum", doc 12 §6).
    uint256 internal constant INITIAL_FEE = 800_000 + 30_000;

    MockAcrossSpokePool internal pool;
    AcrossBridgeAdapter internal adapter;
    MockAcrossToken internal usdc;

    address internal vault = makeAddr("vault");
    address internal guardian = makeAddr("guardian");
    address internal escrow = makeAddr("escrow");
    address internal spokeVault = makeAddr("spokeVault");
    address internal usdg = makeAddr("usdg");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_790_000_000);
        pool = new MockAcrossSpokePool(INITIAL_DEPOSIT_ID);
        adapter = new AcrossBridgeAdapter(vault, guardian, address(pool), address(0));
        usdc = new MockAcrossToken("USD Coin", "USDC");
    }

    // ------------------------------------------------------------------ helpers

    function _request() internal view returns (IBridgeAdapter.SendRequest memory req) {
        req = IBridgeAdapter.SendRequest({
            inputToken: address(usdc),
            outputToken: usdg,
            inputAmount: AMOUNT,
            destinationChainId: SPOKE_CHAIN,
            recipient: bytes32(uint256(uint160(spokeVault))),
            message: TransitMessage.encode(keccak256("fund"), 42_161, bytes32(uint256(7)), TransferKind.Principal)
        });
    }

    function _build(IBridgeAdapter.SendRequest memory req, address depositor)
        internal
        returns (IBridgeAdapter.BridgeCall memory)
    {
        vm.prank(vault);
        return adapter.buildSend(req, depositor, "");
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

    /// @dev Builds `req` and asserts every field: the vault's as received, the rest as the adapter fixes them.
    function _assertEncodes(IBridgeAdapter.SendRequest memory req, address depositor)
        internal
        returns (IBridgeAdapter.BridgeCall memory call)
    {
        uint256 depositId = pool.numberOfDeposits();
        (uint256 quoted,) = adapter.quoteSend(req.inputToken, req.destinationChainId, req.inputAmount, "");
        call = _build(req, depositor);
        (bytes4 selector, DepositArgs memory a) = this.decodeDeposit(call.data);
        uint32 expectedDeadline = uint32(block.timestamp) + 21_600;

        assertEq(selector, IAcrossSpokePool.depositV3.selector, "selector");
        assertEq(a.depositor, depositor, "depositor");
        assertEq(a.recipient, address(uint160(uint256(req.recipient))), "recipient");
        assertEq(a.inputToken, req.inputToken, "inputToken");
        assertEq(a.outputToken, req.outputToken, "outputToken");
        assertEq(a.inputAmount, req.inputAmount, "inputAmount");
        assertEq(a.outputAmount, call.amountToArrive, "outputAmount is the adapter's amount to arrive");
        assertEq(call.amountToArrive, quoted, "amount to arrive as quoted");
        assertEq(a.destinationChainId, req.destinationChainId, "destinationChainId");
        assertEq(a.exclusiveRelayer, address(0), "no exclusive relayer (S-9, DEC-158)");
        assertEq(a.quoteTimestamp, block.timestamp, "quote time is the block time");
        assertEq(a.fillDeadline, expectedDeadline, "fillDeadline in data");
        assertEq(a.exclusivityDeadline, 0, "no exclusivity (S-9, DEC-158)");
        assertEq(a.message, req.message, "message");

        assertEq(call.target, address(pool), "target");
        assertEq(call.transitRef, bytes32(depositId), "transitRef");
        assertEq(call.fillDeadline, expectedDeadline, "fillDeadline");

        // Whole-calldata equality: nothing beyond the twelve fields is encoded.
        assertEq(call.data, _expectedCalldata(req, depositor, call.amountToArrive, expectedDeadline), "calldata");
    }

    function _expectedCalldata(
        IBridgeAdapter.SendRequest memory req,
        address depositor,
        uint256 amountToArrive,
        uint32 deadline
    ) internal view returns (bytes memory) {
        return abi.encodeCall(
            IAcrossSpokePool.depositV3,
            (
                depositor,
                address(uint160(uint256(req.recipient))),
                req.inputToken,
                req.outputToken,
                req.inputAmount,
                amountToArrive,
                req.destinationChainId,
                address(0),
                uint32(block.timestamp),
                deadline,
                0,
                req.message
            )
        );
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

    /// DEC-162 (constants OPEN, doc 12 §6, D-08): 0.08% initial, 0.03% floor, 1% cap, +50% step, 0.03 fixed.
    function test_DEC162_ruleConstants() public view {
        assertEq(adapter.INITIAL_RATE(), 8e14, "0.08%");
        assertEq(adapter.FLOOR_RATE(), 3e14, "0.03%");
        assertEq(adapter.CAP_RATE(), 1e16, "1%");
        assertEq(adapter.BAND(), 5e17, "+50%");
        assertEq(adapter.FIXED_FEE_CENTS(), 3, "0.03 units");
        assertEq(adapter.fixedFee(address(usdc)), 30_000, "0.03 USDC");
    }

    function test_DEC087_constructorRejectsZeroAddresses() public {
        vm.expectRevert(AcrossBridgeAdapter.ZeroVault.selector);
        new AcrossBridgeAdapter(address(0), guardian, address(pool), address(0));
        vm.expectRevert(AcrossBridgeAdapter.ZeroSpokePool.selector);
        new AcrossBridgeAdapter(vault, guardian, address(0), address(0));
        vm.expectRevert(AdapterGuard.ZeroGuardian.selector);
        new AcrossBridgeAdapter(vault, address(0), address(pool), address(0));
    }

    /// @dev WP-07 B2, reading D-01: the API key the factory wires is stored as the quoter for WP-11's signed quotes;
    ///      zero (no API) is accepted, since every send works without it (DEC-052).
    function test_D01_constructorStoresTheQuoter() public {
        assertEq(adapter.quoter(), address(0), "no API");
        address apiKey = makeAddr("pool-party-api");
        assertEq(new AcrossBridgeAdapter(vault, guardian, address(pool), apiKey).quoter(), apiKey);
    }

    function test_DEC066_constructorRejectsShortFillDeadlineBuffer() public {
        pool.setFillDeadlineBuffer(21_599);
        vm.expectRevert(abi.encodeWithSelector(AcrossBridgeAdapter.FillDeadlineBufferTooShort.selector, 21_599));
        new AcrossBridgeAdapter(vault, guardian, address(pool), address(0));
        pool.setFillDeadlineBuffer(21_600);
        new AcrossBridgeAdapter(vault, guardian, address(pool), address(0));
    }

    // ------------------------------------------------------------------ buildSend: the adapter fixes the terms

    /// DEC-158, DEC-162: the vault's fields are encoded as received; the amount to arrive, the relayer, the
    /// exclusivity, the quote time and the deadline are the adapter's.
    function test_DEC162_buildSendFixesEveryAcrossTerm() public {
        IBridgeAdapter.BridgeCall memory call = _assertEncodes(_request(), escrow);
        assertEq(call.amountToArrive, AMOUNT - INITIAL_FEE, "1,000 at 0.08% plus 0.03");
    }

    function test_DEC087_buildSendEncodesEmptyMessage() public {
        IBridgeAdapter.SendRequest memory req = _request();
        req.message = "";
        _assertEncodes(req, escrow);
    }

    /// DEC-087, DEC-162: for any vault-fixed request the adapter substitutes nothing the vault fixed and prices the
    /// send by the rule: the fee is `ceil(amount * 0.08%) + 0.03`.
    function testFuzz_DEC162_buildSendNeverSubstitutesFieldsAndPricesByTheRule(
        uint256 amount,
        uint256 destination,
        bytes32 recipient,
        address outputToken,
        address depositor,
        bytes memory message,
        uint32 timestamp
    ) public {
        amount = bound(amount, 40_000, 1e30);
        recipient = bytes32(uint256(bound(uint256(recipient), 1, type(uint160).max)));
        vm.assume(depositor != address(0) && message.length <= 2048);
        vm.warp(bound(timestamp, 60, type(uint32).max - 21_600));
        IBridgeAdapter.SendRequest memory req = IBridgeAdapter.SendRequest({
            inputToken: address(usdc),
            outputToken: outputToken,
            inputAmount: amount,
            destinationChainId: destination,
            recipient: recipient,
            message: message
        });
        IBridgeAdapter.BridgeCall memory call = _assertEncodes(req, depositor);
        assertEq(amount - call.amountToArrive, (amount * 8e14 + 1e18 - 1) / 1e18 + 30_000, "fee");
    }

    /// DEC-066: the fill deadline is always the build time plus 6 h, in the call and in the struct.
    function testFuzz_DEC066_fillDeadlineIsBuildTimePlusSixHours(uint32 timestamp) public {
        timestamp = uint32(bound(timestamp, 60, type(uint32).max - 21_600));
        vm.warp(timestamp);
        IBridgeAdapter.BridgeCall memory call = _build(_request(), escrow);
        (, DepositArgs memory a) = this.decodeDeposit(call.data);
        assertEq(call.fillDeadline, timestamp + 21_600);
        assertEq(a.fillDeadline, call.fillDeadline);
    }

    /// DEC-090: the transit reference is the deposit id the next deposit gets.
    function test_DEC090_transitRefIsNextDepositId() public {
        assertEq(_build(_request(), escrow).transitRef, bytes32(uint256(INITIAL_DEPOSIT_ID)));
        pool.setNumberOfDeposits(type(uint32).max);
        assertEq(_build(_request(), escrow).transitRef, bytes32(uint256(type(uint32).max)));
    }

    /// DEC-056, DEC-058: the adapter does not gate sends itself (the send home must stay open); the Core Vault reads
    /// the flags on a hub-to-spoke send.
    function test_DEC056_buildSendIgnoresPauseAndDeprecation() public {
        vm.startPrank(guardian);
        adapter.setPaused(true);
        adapter.deprecate();
        vm.stopPrank();
        _assertEncodes(_request(), escrow);
    }

    // ------------------------------------------------------------------ the fixed part follows the token

    /// DEC-162: the fixed part is 0.03 units of the input token: 30,000 for 6 decimals, 3e16 for 18, nothing below 2.
    function test_DEC162_fixedFeeIsThreeHundredthsOfOneUnit() public {
        assertEq(adapter.fixedFee(address(new DecimalsToken(18))), 3e16);
        assertEq(adapter.fixedFee(address(new DecimalsToken(6))), 30_000);
        assertEq(adapter.fixedFee(address(new DecimalsToken(2))), 3);
        assertEq(adapter.fixedFee(address(new DecimalsToken(1))), 0);
        assertEq(adapter.fixedFee(address(new DecimalsToken(0))), 0);
    }

    // ------------------------------------------------------------------ who may call, and with what

    /// DEC-162: only the vault records sends and expiries; anyone else would move the fund's fee history.
    function test_DEC162_onlyTheVaultBuildsOrNotesAnExpiry() public {
        IBridgeAdapter.SendRequest memory req = _request();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IBridgeAdapter.NotVault.selector, stranger));
        adapter.buildSend(req, escrow, "");

        bytes32 ref = _build(req, escrow).transitRef;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IBridgeAdapter.NotVault.selector, stranger));
        adapter.noteExpiry(ref);
    }

    /// DEC-158: no caller passes a bridge parameter; a non-empty `bridgeData` (a quote) is refused until signed quotes
    /// exist (R-162-B), on the build and on the quote.
    function test_DEC158_bridgeDataIsRefused() public {
        IBridgeAdapter.SendRequest memory req = _request();
        bytes memory quote = abi.encode(AMOUNT - 1);
        vm.prank(vault);
        vm.expectRevert(AcrossBridgeAdapter.QuotesNotSupported.selector);
        adapter.buildSend(req, escrow, quote);
        vm.expectRevert(AcrossBridgeAdapter.QuotesNotSupported.selector);
        adapter.quoteSend(address(usdc), SPOKE_CHAIN, AMOUNT, quote);
    }

    /// DEC-162: `quoteSend` is what the next build delivers, and quoting records nothing.
    function test_DEC162_quoteSendMatchesTheNextBuildAndRecordsNothing() public {
        (uint256 arrives, uint256 rate) = adapter.quoteSend(address(usdc), SPOKE_CHAIN, AMOUNT, "");
        assertEq(rate, 8e14);
        assertEq(arrives, AMOUNT - INITIAL_FEE);
        (,, uint64 sends,) = adapter.feeWindow(SPOKE_CHAIN);
        assertEq(sends, 0, "a quote records nothing");
        assertEq(_build(_request(), escrow).amountToArrive, arrives);
        (,, sends,) = adapter.feeWindow(SPOKE_CHAIN);
        assertEq(sends, 1, "a build records the send");
    }

    /// DEC-162, doc 12 §7: a send whose fee would reach the amount is refused (dust waits in the vault): 0.03 sent
    /// would pay 0.000024 + 0.03.
    function test_DEC162_sendNotAboveTheFeeIsRefused() public {
        IBridgeAdapter.SendRequest memory req = _request();
        req.inputAmount = 30_000;
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(BridgeFeeRule.FeeNotBelowAmount.selector, 30_024, 30_000));
        adapter.buildSend(req, escrow, "");
        req.inputAmount = 0;
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(BridgeFeeRule.FeeNotBelowAmount.selector, 30_000, 0));
        adapter.buildSend(req, escrow, "");
        req.inputAmount = 30_025;
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(BridgeFeeRule.FeeNotBelowAmount.selector, 30_025, 30_025));
        adapter.buildSend(req, escrow, "");
        req.inputAmount = 30_026;
        assertEq(_build(req, escrow).amountToArrive, 1, "the smallest send that delivers");
    }

    function test_DEC066_buildSendRejectsZeroDepositor() public {
        IBridgeAdapter.SendRequest memory req = _request();
        vm.prank(vault);
        vm.expectRevert(IBridgeAdapter.InvalidParty.selector);
        adapter.buildSend(req, address(0), "");
    }

    function test_DEC087_buildSendRejectsZeroRecipient() public {
        IBridgeAdapter.SendRequest memory req = _request();
        req.recipient = bytes32(0);
        vm.prank(vault);
        vm.expectRevert(IBridgeAdapter.InvalidParty.selector);
        adapter.buildSend(req, escrow, "");
    }

    /// DEC-087: a universal address with bits above 160 is not truncated into a different recipient.
    function testFuzz_DEC087_buildSendRejectsNonEvmRecipient(uint256 word) public {
        word = bound(word, uint256(type(uint160).max) + 1, type(uint256).max);
        IBridgeAdapter.SendRequest memory req = _request();
        req.recipient = bytes32(word);
        vm.prank(vault);
        vm.expectRevert(IBridgeAdapter.InvalidParty.selector);
        adapter.buildSend(req, escrow, "");
    }

    // ------------------------------------------------------------------ expiries and routes

    /// DEC-162: an expiry the vault notes steps the route's next send one band up and is noted once only.
    function test_DEC162_noteExpiryStepsTheNextSendAndIsNotedOnce() public {
        IBridgeAdapter.BridgeCall memory first = _build(_request(), escrow);
        vm.expectEmit(true, true, false, true, address(adapter));
        emit AcrossBridgeAdapter.ExpiryNoted(SPOKE_CHAIN, first.transitRef, 8e14);
        vm.prank(vault);
        adapter.noteExpiry(first.transitRef);

        (uint256 next, uint256 ref, uint256 expired) = adapter.feeState(SPOKE_CHAIN);
        assertEq(expired, 8e14, "expired rate pending");
        assertEq(next, 12e14, "0.08% stepped up 50%");
        assertEq(ref, 8e14, "the expired entry counts at the initial rate");

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(AcrossBridgeAdapter.UnknownSend.selector, first.transitRef));
        adapter.noteExpiry(first.transitRef);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(AcrossBridgeAdapter.UnknownSend.selector, bytes32(uint256(7))));
        adapter.noteExpiry(bytes32(uint256(7)));
    }

    /// DEC-162: each send is priced and announced with its route, rate and fee.
    function test_DEC162_sendPricedEvent() public {
        IBridgeAdapter.SendRequest memory req = _request();
        vm.expectEmit(true, true, false, true, address(adapter));
        emit AcrossBridgeAdapter.SendPriced(SPOKE_CHAIN, bytes32(uint256(INITIAL_DEPOSIT_ID)), 8e14, INITIAL_FEE);
        _build(req, escrow);
    }

    /// DEC-162: the history is per destination chain (one hub adapter may serve several spokes): an expiry on one
    /// route never moves another route's fee.
    function test_DEC162_routesKeepSeparateHistories() public {
        IBridgeAdapter.SendRequest memory toA = _request();
        IBridgeAdapter.SendRequest memory toB = _request();
        toB.destinationChainId = 8453;
        IBridgeAdapter.BridgeCall memory a = _build(toA, escrow);
        pool.setNumberOfDeposits(INITIAL_DEPOSIT_ID + 1);
        _build(toB, escrow);
        vm.prank(vault);
        adapter.noteExpiry(a.transitRef);

        (uint256 nextA,,) = adapter.feeState(SPOKE_CHAIN);
        (uint256 nextB,,) = adapter.feeState(8453);
        assertEq(nextA, 12e14, "route A steps up");
        assertEq(nextB, 8e14, "route B unchanged");
    }

    /// @dev Security review S-23: a SpokePool buffer lowered after deployment shortens the window instead of making
    ///      every send (the send home included) revert; a zero buffer is refused.
    function test_SEC_S23_fillDeadlineFollowsALoweredSpokePoolBuffer() public {
        pool.setFillDeadlineBuffer(3 hours);
        IBridgeAdapter.BridgeCall memory call = _build(_request(), escrow);
        assertEq(call.fillDeadline, block.timestamp + 3 hours, "S-23: the lower buffer");

        pool.setFillDeadlineBuffer(12 hours);
        call = _build(_request(), escrow);
        assertEq(call.fillDeadline, block.timestamp + 6 hours, "never above the DEC-066 constant");

        pool.setFillDeadlineBuffer(0);
        IBridgeAdapter.SendRequest memory req = _request();
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(AcrossBridgeAdapter.FillDeadlineBufferTooShort.selector, 0));
        adapter.buildSend(req, escrow, "");
    }
}
