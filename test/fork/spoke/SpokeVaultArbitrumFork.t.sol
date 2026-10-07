// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SpokeVaultForkBase} from "./SpokeVaultForkBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {ISpokeVaultUnwind} from "../../../src/interfaces/ISpokeVaultUnwind.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockCoreVault} from "../../mocks/spoke/MockCoreVault.sol";
import {MockSwapAdapter} from "../../mocks/swap/MockSwapAdapter.sol";
import {UniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";

/// @notice Hub role on a pinned Arbitrum One fork with native USDC: allocation from the Core Vault, positions, the
///         proportional automatic unwind back to Idle, income forwarding and the same-chain report reader.
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
            spokeVault: makeAddr("spokeVaultInMandate"),
            hubSwap: address(new MockSwapAdapter()),
            spokeSwap: makeAddr("spokeSwap")
        });
        TransitEscrow escrow = new TransitEscrow();
        address[] memory tokens = new address[](2);
        tokens[0] = ARB_USDC;
        tokens[1] = ARB_WETH;
        a.hubSwap = address(
            new UniswapV3SwapAdapter(
                vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1),
                guardian,
                ARB_USDC,
                tokens,
                0x1F98431c8aD98523631AE4a59f267346ea31F984,
                0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45,
                0x61fFE014bA17989E743c5F6cB21bF9697530B21e,
                address(0)
            )
        );
        vault = new SpokeVault(
            _mandate(a),
            FUND_ID,
            ARBITRUM,
            address(core),
            ARB_USDC,
            ARB_SPOKE_POOL,
            address(0),
            address(escrow),
            excessRecipient
        );
        hubUni.setVault(address(vault));
        hubAave.setVault(address(vault));
        deal(ARB_USDC, address(core), 10_000e6);
    }

    function test_DEC137_forkArbitrum_hubProportionalUnwindBackToIdle() public {
        core.allocate(vault, 1000e6);
        vm.startPrank(manager);
        (bytes32 uniKey,,) = vault.openPosition(address(hubUni), HUB_POOL, 0, 400e6, "");
        (bytes32 aaveKey,,) = vault.openPosition(address(hubAave), AAVE_USDC, 500e6, 0, "");
        vm.stopPrank();

        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.spokeChainId, ARBITRUM);
        assertEq(r.unallocated[0].amount, 100e6);
        assertEq(r.positions.length, 2);

        // DEC-137: the same fraction of every position (three quarters here), plus the Unallocated USDC (D-11).
        ISpokeVaultUnwind.UnwindRequest memory request;
        request.requestId = keccak256("request");
        request.fracNum = 3;
        request.fracDen = 4;
        assertEq(core.unwind(vault, request).proceeds, 100e6 + 300e6 + 375e6);
        assertEq(core.idleReturned(), 775e6);
        assertEq(USDC.balanceOf(address(core)), 9000e6 + 775e6);
        assertEq(vault.unallocatedBalance(ARB_USDC), 0);
        (,, uint256 uniUsdc,,, bool uniOpen) = hubUni.position(uniKey);
        (, uint256 aavePrincipal,,,, bool aaveOpen) = hubAave.position(aaveKey);
        assertTrue(uniOpen && aaveOpen);
        assertEq(uniUsdc, 100e6);
        assertEq(aavePrincipal, 125e6);
    }

    function test_DEC172_forkArbitrum_incomeCollectedForTheCoreVaultAndDonationSwept() public {
        core.allocate(vault, 1000e6);
        vm.prank(manager);
        (bytes32 key,,) = vault.openPosition(address(hubAave), AAVE_USDC, 500e6, 0, "");
        deal(ARB_USDC, address(hubAave), USDC.balanceOf(address(hubAave)) + 3e6);
        hubAave.earnIncome(key, 3e6, 0);
        assertEq(vault.cumulativeIncome(ARB_USDC), 3e6);
        core.collectIncome(vault, 0); // DEC-172: the Core Vault's collection, USDC to the Core Vault
        assertEq(core.incomeReceived(ARB_USDC), 3e6);
        assertEq(vault.collectedIncome(ARB_USDC), 0);
        assertEq(vault.cumulativeIncome(ARB_USDC), 3e6);

        deal(ARB_USDC, address(vault), USDC.balanceOf(address(vault)) + 42e6);
        assertEq(vault.sweepExcess(ARB_USDC), 42e6);
        assertEq(USDC.balanceOf(excessRecipient), 42e6);
        assertEq(vault.unallocatedBalance(ARB_USDC), 500e6);

        vm.expectRevert(ISpokeVault.NotOnSpokeChain.selector);
        vault.report();
    }

    function test_DEC172_forkArbitrum_hubWethIncomeSoldThroughLiveV3Adapter() public {
        core.allocate(vault, 1000e6);
        vm.prank(manager);
        (bytes32 key,,) = vault.openPosition(address(hubUni), HUB_POOL, 0, 500e6, "");
        deal(ARB_WETH, address(hubUni), 0.1e18);
        deal(ARB_USDC, address(hubUni), USDC.balanceOf(address(hubUni)) + 10e6);
        hubUni.earnIncome(key, 0.1e18, 10e6);
        uint256 before = USDC.balanceOf(address(core));
        (address[] memory tokens, uint256[] memory sold, uint256[] memory obtained) = core.collectIncome(vault, 0);
        assertEq(tokens[0], ARB_USDC);
        assertEq(sold[0], 10e6);
        assertEq(tokens[1], ARB_WETH);
        assertEq(sold[1], 0.1e18);
        assertGt(obtained[1], 0);
        assertEq(USDC.balanceOf(address(core)) - before, obtained[0] + obtained[1]);
        assertEq(vault.collectedIncome(ARB_WETH), 0);
        assertEq(vault.collectedIncome(ARB_USDC), 0);
        assertEq(vault.cumulativeIncome(ARB_WETH), 0.1e18);
        assertEq(vault.unallocatedBalance(ARB_USDC), 500e6);
    }
}
