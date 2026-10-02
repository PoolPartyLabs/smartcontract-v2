// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockAcrossSpokePool} from "../../mocks/across/MockAcrossSpokePool.sol";
import {MockAcrossToken} from "../../mocks/across/MockAcrossToken.sol";
import {MaliciousAcrossSpokePool} from "../../mocks/across/MaliciousAcrossSpokePool.sol";
import {AcrossHarnessVault} from "../../mocks/across/AcrossHarnessVault.sol";

/// @notice Adversarial verification of AcrossBridgeAdapter: ABI layout under extreme inputs, a pool that tries to
///         mutate state through `buildSend`, a target without code, timestamp overflow and build/execute ordering.
contract AcrossBridgeAdapterAdversarialTest is Test {
    uint32 internal constant INITIAL_DEPOSIT_ID = 4_700_821;
    uint256 internal constant HEAD_WORDS = 12;

    MockAcrossSpokePool internal pool;
    AcrossBridgeAdapter internal adapter;
    MockAcrossToken internal usdc;

    address internal vault = makeAddr("vault");
    address internal guardian = makeAddr("guardian");
    address internal escrow = makeAddr("escrow");
    address internal spokeVault = makeAddr("spokeVault");
    address internal usdg = makeAddr("usdg");

    function setUp() public {
        vm.warp(1_790_000_000);
        pool = new MockAcrossSpokePool(INITIAL_DEPOSIT_ID);
        adapter = new AcrossBridgeAdapter(vault, guardian, address(pool), address(0));
        usdc = new MockAcrossToken("USD Coin", "USDC");
    }

    function _request() internal view returns (IBridgeAdapter.SendRequest memory req) {
        req = IBridgeAdapter.SendRequest({
            inputToken: address(usdc),
            outputToken: usdg,
            inputAmount: 1000e6,
            destinationChainId: 4663,
            recipient: bytes32(uint256(uint160(spokeVault))),
            message: TransitMessage.encode(keccak256("fund"), 42_161, bytes32(uint256(7)), TransferKind.Principal)
        });
    }

    function _build(AcrossBridgeAdapter target, address caller, IBridgeAdapter.SendRequest memory req)
        internal
        returns (IBridgeAdapter.BridgeCall memory)
    {
        vm.prank(caller);
        return target.buildSend(req, escrow, "");
    }

    function _word(bytes memory data, uint256 index) internal pure returns (uint256 w) {
        assembly ("memory-safe") {
            w := mload(add(add(data, 32), add(4, mul(index, 32))))
        }
    }

    /// DEC-087: for any message length the calldata is the canonical ABI encoding the live pool decodes: selector,
    /// twelve head words, the message offset fixed at 12 * 32, then length and padded bytes. Nothing else.
    function testFuzz_DEC087_calldataLayoutIsCanonicalForAnyMessageLength(bytes memory message) public {
        vm.assume(message.length <= 4096);
        IBridgeAdapter.SendRequest memory req = _request();
        req.message = message;

        bytes memory data = _build(adapter, vault, req).data;

        uint256 padded = ((message.length + 31) / 32) * 32;
        assertEq(data.length, 4 + HEAD_WORDS * 32 + 32 + padded, "calldata length");
        assertEq(_word(data, 11), HEAD_WORDS * 32, "message offset");
        assertEq(_word(data, 12), message.length, "message length");
        // Address words carry no high bits the pool could misread.
        assertEq(_word(data, 0), uint256(uint160(escrow)), "depositor word");
        assertEq(_word(data, 1), uint256(uint160(spokeVault)), "recipient word");
        assertEq(_word(data, 7), 0, "exclusiveRelayer word");
        assertEq(_word(data, 9), uint256(block.timestamp) + 21_600, "fillDeadline word");
    }

    /// DEC-085, DEC-162: at the largest amount the fee rule neither overflows nor rounds the amount sent: the encoded
    /// input is the amount, and the output is the amount less `ceil(amount * 0.08%) + 0.03`.
    function test_DEC162_extremeAmountsPriceWithoutOverflow() public {
        IBridgeAdapter.SendRequest memory req = _request();
        req.inputAmount = type(uint256).max;
        IBridgeAdapter.BridgeCall memory call = _build(adapter, vault, req);
        uint256 fee = type(uint256).max / 1250 + 1 + 30_000; // ceil(max * 8e14 / 1e18) = ceil(max / 1250)
        assertEq(_word(call.data, 4), type(uint256).max, "inputAmount");
        assertEq(_word(call.data, 5), type(uint256).max - fee, "outputAmount");
        assertEq(call.amountToArrive, type(uint256).max - fee);
    }

    /// DEC-090: the adapter reads the SpokePool only through `view` calls; a SpokePool whose counter getter writes
    /// state cannot use the adapter as a mutation vector: the STATICCALL frame reverts the build and the pool's storage
    /// stays untouched.
    function test_DEC090_buildSendCannotBeUsedToMutateTheSpokePool() public {
        MaliciousAcrossSpokePool malicious = new MaliciousAcrossSpokePool();
        AcrossBridgeAdapter viaMalicious = new AcrossBridgeAdapter(vault, guardian, address(malicious), address(0));
        IBridgeAdapter.SendRequest memory req = _request();
        vm.prank(vault);
        vm.expectRevert();
        viaMalicious.buildSend(req, escrow, "");
        assertEq(malicious.reads(), 0, "no state written through a view");
    }

    /// DEC-058: a SpokePool address without code cannot be pinned: the constructor's buffer read reverts, so an
    /// adapter never exists with an empty target the vault would approve.
    function test_DEC058_constructorRejectsTargetWithoutCode() public {
        vm.expectRevert();
        new AcrossBridgeAdapter(vault, guardian, makeAddr("eoa-target"), address(0));
    }

    /// DEC-066: at the uint32 time horizon the deadline arithmetic reverts (checked) rather than wrapping to a
    /// deadline in the past; the boundary just below builds normally.
    function test_DEC066_fillDeadlineArithmeticRevertsInsteadOfWrapping() public {
        vm.warp(uint256(type(uint32).max) - 21_600);
        IBridgeAdapter.BridgeCall memory call = _build(adapter, vault, _request());
        assertEq(call.fillDeadline, type(uint32).max);

        vm.warp(uint256(type(uint32).max) - 21_599);
        IBridgeAdapter.SendRequest memory req = _request();
        vm.prank(vault);
        vm.expectRevert(); // Panic 0x11
        adapter.buildSend(req, escrow, "");
    }

    /// DEC-090: a build whose call is executed later than the next deposit carries a stale `transitRef`; a vault
    /// that builds and executes in one transaction (the harness) always gets the id the pool assigns.
    function test_DEC090_strangerDepositBetweenBuildAndExecuteShiftsTheId() public {
        AcrossHarnessVault harness = new AcrossHarnessVault();
        AcrossBridgeAdapter viaHarness = new AcrossBridgeAdapter(address(harness), guardian, address(pool), address(0));
        harness.pin(viaHarness);
        usdc.mint(address(harness), 2000e6);
        IBridgeAdapter.SendRequest memory req = _request();

        uint256 snapshot = vm.snapshotState();
        IBridgeAdapter.BridgeCall memory stale = _build(viaHarness, address(harness), req);
        assertEq(uint256(stale.transitRef), INITIAL_DEPOSIT_ID);
        vm.revertToState(snapshot);

        // A stranger's deposit lands first.
        pool.setNumberOfDeposits(INITIAL_DEPOSIT_ID + 1);

        (IBridgeAdapter.BridgeCall memory fresh,) = harness.send(req);
        assertEq(uint256(fresh.transitRef), INITIAL_DEPOSIT_ID + 1, "fresh build tracks the counter");
        assertEq(pool.lastDepositId(), uint256(fresh.transitRef), "harness id = assigned id");
        assertNotEq(stale.transitRef, fresh.transitRef, "stale build would mislabel the transit");
    }

    /// DEC-087: `InvalidParty` is the adapter's only check of the parties; the output token is passed through without
    /// validation (the vault owns that check). The input token must answer `decimals()`, which the fixed part of the
    /// fee reads (DEC-162), so a token without code is refused.
    function test_DEC087_outputTokenPassesThroughAndInputTokenMustHaveDecimals() public {
        IBridgeAdapter.SendRequest memory req = _request();
        req.outputToken = address(0);
        IBridgeAdapter.BridgeCall memory call = _build(adapter, vault, req);
        assertEq(_word(call.data, 3), 0, "outputToken passed as given");
        assertEq(bytes4(call.data), IAcrossSpokePool.depositV3.selector);

        req.inputToken = address(0);
        vm.prank(vault);
        vm.expectRevert();
        adapter.buildSend(req, escrow, "");
    }
}
