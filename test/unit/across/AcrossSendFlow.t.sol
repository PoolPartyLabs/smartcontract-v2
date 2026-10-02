// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {ITransitEscrow} from "../../../src/interfaces/ITransitEscrow.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockAcrossSpokePool} from "../../mocks/across/MockAcrossSpokePool.sol";
import {MockAcrossToken} from "../../mocks/across/MockAcrossToken.sol";
import {MockAcrossMessageHandler} from "../../mocks/across/MockAcrossMessageHandler.sol";
import {AcrossHarnessVault} from "../../mocks/across/AcrossHarnessVault.sol";
import {AcrossFillSimulator} from "../../mocks/across/AcrossFillSimulator.sol";

/// @notice Offline end-to-end of one send as IBridgeAdapter prescribes, against a SpokePool stand-in, plus the fill
///         simulation helper. The same flow runs against the live SpokePools in test/fork/across.
contract AcrossSendFlowTest is Test {
    uint32 internal constant INITIAL_DEPOSIT_ID = 12;

    MockAcrossSpokePool internal pool;
    MockAcrossToken internal usdc;
    AcrossHarnessVault internal harness;
    AcrossBridgeAdapter internal adapter;

    address internal guardian = makeAddr("guardian");
    address internal spokeVault = makeAddr("spokeVault");
    address internal relayer = makeAddr("relayer");
    address internal usdgAddress = makeAddr("usdg");

    function setUp() public {
        vm.warp(1_790_000_000);
        pool = new MockAcrossSpokePool(INITIAL_DEPOSIT_ID);
        usdc = new MockAcrossToken("USD Coin", "USDC");
        harness = new AcrossHarnessVault();
        adapter = new AcrossBridgeAdapter(address(harness), guardian, address(pool), address(0));
        harness.pin(adapter);
        usdc.mint(address(harness), 10_000e6);
    }

    function _request() internal view returns (IBridgeAdapter.SendRequest memory) {
        return IBridgeAdapter.SendRequest({
            inputToken: address(usdc),
            outputToken: usdgAddress,
            inputAmount: 1000e6,
            destinationChainId: 4663,
            recipient: bytes32(uint256(uint160(spokeVault))),
            message: TransitMessage.encode(keccak256("fund"), 42_161, bytes32(uint256(1)), TransferKind.Principal)
        });
    }

    /// DEC-066, DEC-087: the vault pays, the escrow is the depositor of record, the debit is exact and the approval
    /// is reset.
    function test_DEC066_vaultPaysEscrowIsDepositorApprovalReset() public {
        IBridgeAdapter.SendRequest memory req = _request();
        uint256 poolBefore = usdc.balanceOf(address(pool));

        (IBridgeAdapter.BridgeCall memory call, address escrow) = harness.send(req);

        assertEq(usdc.balanceOf(address(harness)), 10_000e6 - req.inputAmount);
        assertEq(usdc.balanceOf(address(pool)), poolBefore + req.inputAmount);
        assertEq(usdc.allowance(address(harness), address(pool)), 0);
        assertEq(usdc.balanceOf(escrow), 0);
        assertEq(ITransitEscrow(escrow).vault(), address(harness));
        assertEq(uint256(call.transitRef), INITIAL_DEPOSIT_ID);
        assertEq(pool.numberOfDeposits(), INITIAL_DEPOSIT_ID + 1);

        assertEq(pool.lastDepositId(), uint256(call.transitRef), "deposit id = transitRef");
        assertEq(pool.lastDepositor(), escrow, "depositor = escrow");
        assertEq(pool.lastRecipient(), spokeVault, "recipient");
    }

    /// DEC-158, DEC-162: the vault passes no amount to arrive; the deposit carries the adapter's (1,000 at 0.08%
    /// plus 0.03), quoted at the block time, so the pool's quote-age check always passes.
    function test_DEC162_depositCarriesTheAdaptersAmountToArrive() public {
        (IBridgeAdapter.BridgeCall memory call,) = harness.send(_request());
        assertEq(call.amountToArrive, 1000e6 - 830_000);
        assertEq(pool.lastDepositId(), uint256(call.transitRef));
    }

    /// DEC-158: a vault that passes `bridgeData` to the Across adapter is refused and no value moves.
    function test_DEC158_bridgeDataRevertsAndMovesNothing() public {
        IBridgeAdapter.SendRequest memory req = _request();
        vm.expectRevert(AcrossBridgeAdapter.QuotesNotSupported.selector);
        harness.send(req, abi.encode(uint256(999e6)));
        assertEq(usdc.balanceOf(address(harness)), 10_000e6);
    }

    /// DEC-090: the fill simulator credits the recipient first, then calls it from the SpokePool.
    function test_DEC090_fillSimulatorCreditsThenCallsHandler() public {
        MockAcrossToken usdg = new MockAcrossToken("Global Dollar", "USDG");
        MockAcrossMessageHandler handler = new MockAcrossMessageHandler(address(pool));
        usdg.mint(address(handler), 5e6);
        bytes memory message = _request().message;

        AcrossFillSimulator.simulateFill(
            stdstore, address(pool), address(usdg), 999_400_000, address(handler), relayer, message
        );

        assertEq(usdg.balanceOf(address(handler)), 5e6 + 999_400_000);
        assertEq(handler.calls(), 1);
        assertEq(handler.lastTokenSent(), address(usdg));
        assertEq(handler.lastAmount(), 999_400_000);
        assertEq(handler.lastRelayer(), relayer);
        assertEq(handler.lastMessage(), message);
        assertEq(handler.balanceAtCallback(), 5e6 + 999_400_000);
    }

    /// DEC-090: the live SpokePool skips the callback on an empty message; the simulator does the same.
    function test_DEC090_fillSimulatorSkipsCallbackOnEmptyMessage() public {
        MockAcrossToken usdg = new MockAcrossToken("Global Dollar", "USDG");
        MockAcrossMessageHandler handler = new MockAcrossMessageHandler(address(pool));
        AcrossFillSimulator.simulateFill(stdstore, address(pool), address(usdg), 1e6, address(handler), relayer, "");
        assertEq(usdg.balanceOf(address(handler)), 1e6);
        assertEq(handler.calls(), 0);
    }

    /// DEC-080: the handler accepts the callback only from the SpokePool.
    function test_DEC080_handlerRejectsCallerOtherThanSpokePool() public {
        MockAcrossMessageHandler handler = new MockAcrossMessageHandler(address(pool));
        vm.expectRevert(abi.encodeWithSelector(MockAcrossMessageHandler.NotSpokePool.selector, address(this)));
        handler.handleV3AcrossMessage(address(usdc), 1, relayer, hex"01");
    }
}
