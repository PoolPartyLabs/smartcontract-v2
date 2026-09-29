// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShareToken} from "../../src/core/ShareToken.sol";

contract ShareTokenTest is Test {
    ShareToken internal token;
    address internal coreVault = makeAddr("coreVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant ONE_SHARE = 1e18;

    function setUp() public {
        token = new ShareToken("Pool Party Fund 1", "PP-1", coreVault);
    }

    function test_DEC091_erc20With18Decimals() public view {
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "Pool Party Fund 1");
        assertEq(token.symbol(), "PP-1");
        assertEq(token.coreVault(), coreVault);
    }

    function test_DEC054_zeroCoreVaultReverts() public {
        vm.expectRevert(ShareToken.ZeroCoreVault.selector);
        new ShareToken("n", "s", address(0));
    }

    function test_DEC011_onlyCoreVaultMints() public {
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotCoreVault.selector, alice));
        vm.prank(alice);
        token.mint(alice, ONE_SHARE);
    }

    function test_DEC011_onlyCoreVaultBurns() public {
        vm.prank(coreVault);
        token.mint(alice, ONE_SHARE);
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotCoreVault.selector, alice));
        vm.prank(alice);
        token.burn(alice, ONE_SHARE);
    }

    function test_DEC091_mintRevertsUnlessWholeShares() public {
        vm.startPrank(coreVault);
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWholeShares.selector, ONE_SHARE + 1));
        token.mint(alice, ONE_SHARE + 1);
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWholeShares.selector, 1));
        token.mint(alice, 1);
        token.mint(alice, 3 * ONE_SHARE);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 3 * ONE_SHARE);
    }

    function test_DEC091_burnRevertsUnlessWholeShares() public {
        vm.startPrank(coreVault);
        token.mint(alice, 3 * ONE_SHARE);
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWholeShares.selector, ONE_SHARE / 2));
        token.burn(alice, ONE_SHARE / 2);
        vm.stopPrank();
    }

    function test_DEC077_coreVaultBurnsFromAnyHolderWithoutAllowance() public {
        vm.startPrank(coreVault);
        token.mint(alice, 5 * ONE_SHARE);
        token.burn(alice, 2 * ONE_SHARE);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 3 * ONE_SHARE);
        assertEq(token.totalSupply(), 3 * ONE_SHARE);
    }

    function test_DEC004_transferReverts() public {
        vm.prank(coreVault);
        token.mint(alice, ONE_SHARE);
        vm.expectRevert(ShareToken.ShareTransfersDisabled.selector);
        vm.prank(alice);
        token.transfer(bob, ONE_SHARE);
    }

    function test_DEC004_transferFromReverts() public {
        vm.prank(coreVault);
        token.mint(alice, ONE_SHARE);
        vm.expectRevert(ShareToken.ShareTransfersDisabled.selector);
        vm.prank(coreVault);
        token.transferFrom(alice, bob, ONE_SHARE);
    }

    function test_DEC004_approveRevertsAndAllowanceIsZero() public {
        vm.expectRevert(ShareToken.ShareTransfersDisabled.selector);
        vm.prank(alice);
        token.approve(bob, ONE_SHARE);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.allowance(alice, coreVault), 0);
    }

    /// Q58: no ERC20Permit; a permit call finds no function.
    function test_DEC004_noPermitFunction() public {
        (bool ok,) = address(token)
            .call(
                abi.encodeWithSignature(
                    "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
                    alice,
                    bob,
                    ONE_SHARE,
                    block.timestamp,
                    uint8(27),
                    bytes32(0),
                    bytes32(0)
                )
            );
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        assertFalse(ok);
    }

    /// DEC-004: Transfer events only from address(0) (mint) or to address(0) (burn).
    function test_DEC004_transferEventsOnlyOnMintAndBurn() public {
        vm.recordLogs();
        vm.startPrank(coreVault);
        token.mint(alice, 2 * ONE_SHARE);
        token.burn(alice, ONE_SHARE);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 transfers;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IERC20.Transfer.selector) continue;
            ++transfers;
            address from = address(uint160(uint256(logs[i].topics[1])));
            address to = address(uint160(uint256(logs[i].topics[2])));
            assertTrue(from == address(0) || to == address(0));
        }
        assertEq(transfers, 2);
    }

    function testFuzz_DEC091_mintSucceedsIffWholeShares(uint256 amount) public {
        amount = bound(amount, 0, 1e40);
        vm.prank(coreVault);
        if (amount % ONE_SHARE != 0) {
            vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWholeShares.selector, amount));
            token.mint(alice, amount);
        } else {
            token.mint(alice, amount);
            assertEq(token.balanceOf(alice), amount);
        }
    }
}

/// @dev Drives mints and burns with whole amounts (must succeed: `fail_on_revert` catches any revert) and with
///      fractional amounts (must revert with `NotWholeShares`), plus transfers (must revert). Each path is its own
///      selector, so no run depends on a fuzzed parity to exercise supply changes.
contract ShareTokenHandler is Test {
    ShareToken internal immutable token;
    address internal immutable coreVault;
    address[3] internal holders = [address(0xA11CE), address(0xB0B), address(0xCA7)];

    constructor(ShareToken token_, address coreVault_) {
        token = token_;
        coreVault = coreVault_;
    }

    function mintWhole(uint256 holderSeed, uint256 wholeShares) external {
        wholeShares = bound(wholeShares, 1, 1e12);
        vm.prank(coreVault);
        token.mint(holders[holderSeed % 3], wholeShares * 1e18);
    }

    function mintFractional(uint256 holderSeed, uint256 amount) external {
        amount = bound(amount, 1, 1e30);
        if (amount % 1e18 == 0) amount += 1;
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWholeShares.selector, amount));
        vm.prank(coreVault);
        token.mint(holders[holderSeed % 3], amount);
    }

    function burnWhole(uint256 holderSeed, uint256 wholeShares) external {
        address holder = holders[holderSeed % 3];
        uint256 max = token.balanceOf(holder) / 1e18;
        if (max == 0) return;
        wholeShares = bound(wholeShares, 1, max);
        vm.prank(coreVault);
        token.burn(holder, wholeShares * 1e18);
    }

    function burnFractional(uint256 holderSeed, uint256 amount) external {
        address holder = holders[holderSeed % 3];
        amount = bound(amount, 1, 1e18 - 1);
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWholeShares.selector, amount));
        vm.prank(coreVault);
        token.burn(holder, amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        vm.expectRevert(ShareToken.ShareTransfersDisabled.selector);
        vm.prank(holders[fromSeed % 3]);
        token.transfer(holders[toSeed % 3], amount);
    }
}

contract ShareTokenInvariantTest is StdInvariant, Test {
    ShareToken internal token;
    ShareTokenHandler internal handler;

    function setUp() public {
        address coreVault = makeAddr("coreVault");
        token = new ShareToken("Pool Party Fund 1", "PP-1", coreVault);
        handler = new ShareTokenHandler(token, coreVault);
        targetContract(address(handler));
    }

    /// DEC-091: totalSupply is always a multiple of 1e18.
    function invariant_DEC091_totalSupplyIsWholeShares() public view {
        assertEq(token.totalSupply() % 1e18, 0);
        assertEq(token.balanceOf(address(0xA11CE)) % 1e18, 0);
        assertEq(token.balanceOf(address(0xB0B)) % 1e18, 0);
        assertEq(token.balanceOf(address(0xCA7)) % 1e18, 0);
    }

    /// DEC-004: no allowance can ever exist.
    function invariant_DEC004_allowanceAlwaysZero() public view {
        assertEq(token.allowance(address(0xA11CE), address(0xB0B)), 0);
    }
}
