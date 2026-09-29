// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SpokeVaultForkBase} from "./SpokeVaultForkBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockCoreVault} from "../../mocks/spoke/MockCoreVault.sol";

/// @notice Hub role on a pinned Arbitrum One fork with native USDC: allocation from the Core Vault, positions, the
///         automatic unwind in Mandate order back to Idle, income forwarding and the same-chain report reader.
contract SpokeVaultArbitrumForkTest is SpokeVaultForkBase {
    MockPositionAdapter internal hubUni;
    MockPositionAdapter internal hubAave;
    MockCoreVault internal core;
    SpokeVault internal vault;
    IERC20 internal constant USDC = IERC20(ARB_USDC);

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        assertEq(block.chainid, ARBITRUM);

        hubUni = new MockPositionAdapter(guardian, false);
        hubUni.addPool(HUB_POOL, ARB_WETH, ARB_USDC);
        hubAave = new MockPositionAdapter(guardian, true);
        hubAave.addPool(AAVE_USDC, ARB_USDC, address(0));
        core = new MockCoreVault(ARB_USDC);
        ForkAdapters memory a = ForkAdapters({
            hubUni: address(hubUni),
            hubAave: address(hubAave),
            spokeUni: makeAddr("spokeUni"),
            hubBridge: makeAddr("hubBridge"),
            spokeBridge: makeAddr("spokeBridge"),
            spokeVault: makeAddr("spokeVaultInMandate")
        });
        vault = new SpokeVault(
            _mandate(a),
            FUND_ID,
            ARBITRUM,
            address(core),
            ARB_USDC,
            ARB_SPOKE_POOL,
            address(0),
            address(new TransitEscrow()),
            excessRecipient
        );
        hubUni.setVault(address(vault));
        hubAave.setVault(address(vault));
        deal(ARB_USDC, address(core), 10_000e6);
    }

    function test_DEC069_forkArbitrum_hubUnwindInMandateOrderBackToIdle() public {
        core.allocate(vault, 1000e6);
        vm.startPrank(manager);
        (bytes32 uniKey,,) = vault.openPosition(address(hubUni), HUB_POOL, 0, 400e6, "");
        (bytes32 aaveKey,,) = vault.openPosition(address(hubAave), AAVE_USDC, 500e6, 0, "");
        vm.stopPrank();

        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.spokeChainId, ARBITRUM);
        assertEq(r.unallocated[0].amount, 100e6);
        assertEq(r.positions.length, 2);

        // Final verification (DEC-069): the vault sizes each step itself, no hint needed for USDC principal.
        assertEq(core.unwind(vault, 800e6, ""), 800e6);
        assertEq(core.idleReturned(), 800e6);
        assertEq(USDC.balanceOf(address(core)), 9000e6 + 800e6);
        assertEq(vault.unallocatedBalance(ARB_USDC), 0);
        (,,,,, bool uniOpen) = hubUni.position(uniKey);
        (, uint256 aavePrincipal,,,, bool aaveOpen) = hubAave.position(aaveKey);
        assertFalse(uniOpen);
        assertTrue(aaveOpen);
        assertEq(aavePrincipal, 200e6);
    }

    function test_DEC092_forkArbitrum_incomeForwardedAndDonationSwept() public {
        core.allocate(vault, 1000e6);
        vm.prank(manager);
        (bytes32 key,,) = vault.openPosition(address(hubAave), AAVE_USDC, 500e6, 0, "");
        deal(ARB_USDC, address(hubAave), USDC.balanceOf(address(hubAave)) + 3e6);
        hubAave.earnIncome(key, 3e6, 0);
        assertEq(vault.cumulativeIncome(ARB_USDC), 3e6);
        vm.prank(manager);
        vault.collectIncome(address(hubAave), key);
        assertEq(vault.forwardIncomeToCoreVault(ARB_USDC), 3e6);
        assertEq(core.incomeReceived(ARB_USDC), 3e6);
        assertEq(vault.cumulativeIncome(ARB_USDC), 3e6);

        deal(ARB_USDC, address(vault), USDC.balanceOf(address(vault)) + 42e6);
        assertEq(vault.sweepExcess(ARB_USDC), 42e6);
        assertEq(USDC.balanceOf(excessRecipient), 42e6);
        assertEq(vault.unallocatedBalance(ARB_USDC), 500e6);

        vm.expectRevert(ISpokeVault.NotOnSpokeChain.selector);
        vault.report();
    }
}
