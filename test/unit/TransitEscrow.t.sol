// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TransitEscrow} from "../../src/core/TransitEscrow.sol";
import {ITransitEscrow} from "../../src/interfaces/ITransitEscrow.sol";

contract EscrowTestToken is ERC20("Test", "TST") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TransitEscrowTest is Test {
    TransitEscrow internal implementation;
    EscrowTestToken internal token;
    address internal vault = makeAddr("vault");

    function setUp() public {
        implementation = new TransitEscrow();
        token = new EscrowTestToken();
    }

    function _clone() internal returns (ITransitEscrow escrow) {
        escrow = ITransitEscrow(Clones.clone(address(implementation)));
        escrow.initialize(vault, address(token));
    }

    function test_DEC066_cloneReleasesRefundOnlyToVaultCaller() public {
        ITransitEscrow escrow = _clone();
        token.mint(address(escrow), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ITransitEscrow.NotVault.selector, address(this)));
        escrow.release(address(this));
        vm.prank(vault);
        uint256 amount = escrow.release(vault);
        assertEq(amount, 1000e6);
        assertEq(token.balanceOf(vault), 1000e6);
        vm.prank(vault);
        assertEq(escrow.release(vault), 0);
    }

    function test_DEC066_cloneInitializesOnce() public {
        ITransitEscrow escrow = _clone();
        vm.expectRevert(ITransitEscrow.AlreadyInitialized.selector);
        escrow.initialize(address(1), address(2));
    }

    function test_DEC066_implementationCannotBeInitialized() public {
        vm.expectRevert(ITransitEscrow.AlreadyInitialized.selector);
        implementation.initialize(vault, address(token));
    }

    function test_DEC066_escrowIsKeylessNoEip1271NoReceive() public {
        ITransitEscrow escrow = _clone();
        (bool ok,) =
            address(escrow).call{value: 0}(abi.encodeWithSignature("isValidSignature(bytes32,bytes)", bytes32(0), ""));
        assertFalse(ok);
        vm.deal(address(this), 1 ether);
        (ok,) = address(escrow).call{value: 1}("");
        assertFalse(ok);
    }
}
