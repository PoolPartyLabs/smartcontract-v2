// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockAcrossSpokePool} from "../../mocks/across/MockAcrossSpokePool.sol";
import {MockAcrossToken} from "../../mocks/across/MockAcrossToken.sol";
import {AcrossHarnessVault} from "../../mocks/across/AcrossHarnessVault.sol";

/// @notice (adapters review) The Across adapter encodes `fillDeadline = now + 21,600` as an immutable constant
///         (DEC-066) and checks the SpokePool's `fillDeadlineBuffer` only at construction. The live SpokePools are UUPS
///         proxies: if Across governance ever lowers the buffer, even by one second, every send the adapter builds
///         reverts `InvalidFillDeadline`, in both directions, and an immutable fund can never adopt another adapter
///         (DEC-058), so spoke value has no route home. Harness vault and SpokePool stand-in of the adapter's own suite.
/// @dev Run: forge test --match-path 'test/review/adapters/AcrossBufferReduction.t.sol' -vv
contract AcrossBufferReductionTest is Test {
    MockAcrossSpokePool internal pool;
    MockAcrossToken internal usdg;
    AcrossHarnessVault internal spokeVault;
    AcrossBridgeAdapter internal adapter;

    function setUp() public {
        vm.warp(1_790_000_000);
        pool = new MockAcrossSpokePool(1);
        usdg = new MockAcrossToken("Global Dollar", "USDG");
        spokeVault = new AcrossHarnessVault();
        adapter = new AcrossBridgeAdapter(address(spokeVault), makeAddr("guardian"), address(pool));
        spokeVault.pin(adapter);
        usdg.mint(address(spokeVault), 10_000e6);
    }

    function _sendHome() internal returns (IBridgeAdapter.SendRequest memory) {
        return IBridgeAdapter.SendRequest({
            inputToken: address(usdg),
            outputToken: makeAddr("hub USDC"),
            inputAmount: 1000e6,
            destinationChainId: 42_161,
            recipient: bytes32(uint256(uint160(makeAddr("core vault")))),
            message: TransitMessage.encode(keccak256("fund"), 4663, bytes32(uint256(1)), TransferKind.Principal)
        });
    }

    /// @dev Ported to fix/pp-sc-fix-independent-review (review M-05, security sweep S-23): FIXED. e5c778a: after a
    ///      one-second cut every send reverted `InvalidFillDeadline`, day after day. The adapter now encodes
    ///      `min(21,600, fillDeadlineBuffer())` at build time.
    function test_REVIEW_M05_aBufferReductionAfterCreationIsFollowed() public {
        (IBridgeAdapter.BridgeCall memory call,) = spokeVault.send(_sendHome()); // works at 21,600
        assertEq(call.fillDeadline, block.timestamp + 21_600);

        pool.setFillDeadlineBuffer(21_599); // one second less, after the fund exists
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 1 days);
            (call,) = spokeVault.send(_sendHome());
            assertEq(call.fillDeadline, block.timestamp + 21_599, "the window follows the lowered buffer");
        }

        // Re-attack: a much deeper cut is followed too; a raised buffer keeps the 6 h constant (DEC-066).
        pool.setFillDeadlineBuffer(600);
        (call,) = spokeVault.send(_sendHome());
        assertEq(call.fillDeadline, block.timestamp + 600);
        pool.setFillDeadlineBuffer(86_400);
        (call,) = spokeVault.send(_sendHome());
        assertEq(call.fillDeadline, block.timestamp + 21_600);
        assertEq(adapter.fillDeadlineSeconds(), 21_600);

        // A zero buffer is refused by name (no deposit could be accepted anyway).
        pool.setFillDeadlineBuffer(0);
        IBridgeAdapter.SendRequest memory req = _sendHome();
        vm.expectRevert(abi.encodeWithSelector(AcrossBridgeAdapter.FillDeadlineBufferTooShort.selector, uint32(0)));
        spokeVault.send(req);
    }
}
