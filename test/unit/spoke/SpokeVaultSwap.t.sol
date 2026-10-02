// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {UniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {ISpokeVaultIncome} from "../../../src/interfaces/ISpokeVaultIncome.sol";
import {ISwapAdapter} from "../../../src/interfaces/ISwapAdapter.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {MockSpokeToken} from "../../mocks/spoke/MockSpokeToken.sol";
import {MockSwapAdapter} from "../../mocks/swap/MockSwapAdapter.sol";
import {MockV3Factory, MockV3Pool, MockQuoterV2, MockSwapRouter02} from "../../mocks/swap/MockV3.sol";
import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";

/// @notice A swap adapter that calls back into the vault while it swaps.
contract ReenteringSwapAdapter {
    function swap(address tokenIn, address, uint256, uint16, bytes calldata)
        external
        returns (uint256, uint256, uint256)
    {
        ISpokeVault(msg.sender).sweepExcess(tokenIn);
        return (0, 0, 0);
    }
}

/// @notice The manager's swap verb and the collected income swap through a Mandate swap adapter (WP-07 C1/C2; founder,
///         2026-10-02: "swaps are not done in the fund pools"; DEC-136, DEC-142, DEC-143, DEC-153).
/// @dev Custody and ledger checks run against the swap adapter stand-in, which can misbehave; the route, maximum-loss
///      and guard rules run against the real `UniswapV3SwapAdapter` over the V3 stand-ins, pinned in a spoke vault's
///      Mandate.
contract SpokeVaultSwapTest is SpokeVaultTestBase {
    bytes32 internal constant ARRIVAL = keccak256("arrival");
    uint160 internal constant PRICE_ONE = uint160(1 << 96);
    uint128 internal constant LIQUIDITY = 1e30;

    /// @dev Set by `_deployWithV3Adapter`: the spoke vault's swap adapter is the real one instead of the stand-in.
    address internal v3SwapAdapter;
    MockV3Factory internal v3;
    MockSwapRouter02 internal router;
    MockQuoterV2 internal quoter;
    MockSpokeToken internal hop;
    address internal apiSigner;
    uint256 internal apiKey;

    function setUp() public {
        _setUpMocks();
        _deploySpoke();
        _disableOperatingCash();
        _arrive(1000e6, ARRIVAL, TransferKind.Principal);
    }

    function _mandate() internal view override returns (Mandate memory m) {
        m = super._mandate();
        if (v3SwapAdapter == address(0)) return m;
        for (uint256 i; i < m.swapAdapters.length; ++i) {
            if (m.swapAdapters[i].chainId == SPOKE) m.swapAdapters[i].adapter = v3SwapAdapter;
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Which adapter, which tokens (DEC-136; Q17-4)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC136_swapCreditsTheOutputAndCarriesTheLimit() public {
        vm.expectEmit(address(vault));
        emit ISpokeVault.Swapped(address(spokeSwap), address(usdg), address(weth), 400e6, 0.2e18, 0.2e18, 100, 0.198e18);
        vm.prank(manager);
        uint256 out = vault.swap(address(spokeSwap), address(usdg), address(weth), 400e6, 100, hex"c0ffee");
        assertEq(out, 0.2e18);
        assertEq(vault.unallocatedBalance(address(usdg)), 600e6);
        assertEq(vault.unallocatedBalance(address(weth)), 0.2e18);
        assertEq(spokeSwap.lastMaxLossBps(), 100, "the maximum loss reaches the adapter");
        assertEq(spokeSwap.lastRoute(), hex"c0ffee", "the route reaches the adapter untouched");
        assertEq(usdg.balanceOf(address(vault)), _ledgerTotal(address(usdg)));
        assertEq(weth.balanceOf(address(vault)), _ledgerTotal(address(weth)));
    }

    /// @dev Founder chat 1: never in a fund pool. A position adapter is not a swap adapter, and another chain's swap
    ///      adapter is not this chain's.
    function test_DEC136_onlyAMandateSwapAdapterOfThisChain() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.AdapterNotInMandate.selector, address(spokeUni)));
        vault.swap(address(spokeUni), address(usdg), address(weth), 1e6, 0, "");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.AdapterNotInMandate.selector, address(hubSwap)));
        vault.swap(address(hubSwap), address(usdg), address(weth), 1e6, 0, "");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.AdapterNotInMandate.selector, stranger));
        vault.swapCollectedIncome(stranger, address(weth), 1, 0, "");
        vm.stopPrank();
    }

    /// @dev Q17-4: the swap adapter's code is pinned at creation.
    function test_Q17_4_aSwapAdapterWhoseCodeChangedIsRefused() public {
        bytes32 pinned = vault.adapterCodehash(address(spokeSwap));
        assertEq(pinned, address(spokeSwap).codehash);
        vm.etch(address(spokeSwap), address(new ReenteringSwapAdapter()).code);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISpokeVault.AdapterCodehashMismatch.selector, address(spokeSwap), pinned, address(spokeSwap).codehash
            )
        );
        vault.swap(address(spokeSwap), address(usdg), address(weth), 1e6, 0, "");
    }

    /// @dev DEC-136 item 2: only this chain's Mandate tokens, in and out (hub USDC is not one on the spoke).
    function test_DEC136_onlyMandateTokensOfThisChain() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.TokenNotInMandate.selector, address(usdc)));
        vault.swap(address(spokeSwap), address(usdg), address(usdc), 1e6, 0, "");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.TokenNotInMandate.selector, address(usdc)));
        vault.swap(address(spokeSwap), address(usdc), address(usdg), 1e6, 0, "");
        vm.expectRevert(ISpokeVault.ZeroAmount.selector);
        vault.swap(address(spokeSwap), address(usdg), address(weth), 0, 0, "");
        vm.expectRevert(
            abi.encodeWithSelector(ISpokeVault.InsufficientUnallocatedBalance.selector, address(usdg), 1000e6, 1001e6)
        );
        vault.swap(address(spokeSwap), address(usdg), address(weth), 1001e6, 0, "");
        vm.stopPrank();
    }

    function test_DEC002_onlyTheManagerSwaps() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        vault.swap(address(spokeSwap), address(usdg), address(weth), 1e6, 0, "");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        vault.swapCollectedIncome(address(spokeSwap), address(weth), 1, 0, "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Custody (DEC-079, DEC-080)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The vault approves exactly the input and leaves no allowance behind.
    function test_DEC080_exactApprovalResetToZero() public {
        vm.prank(manager);
        vault.swap(address(spokeSwap), address(usdg), address(weth), 400e6, 0, "");
        assertEq(IERC20(address(usdg)).allowance(address(vault), address(spokeSwap)), 0);
        assertEq(usdg.balanceOf(address(spokeSwap)), 400e6, "the adapter took exactly the input");
    }

    /// @dev An adapter that takes less than the input it was approved for is refused, and nothing changes.
    function test_DEC080_anAdapterThatTakesLessThanTheInputIsRefused() public {
        spokeSwap.setPullBps(9999);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.SwapDebitMismatch.selector, 400e6, 399.96e6));
        vault.swap(address(spokeSwap), address(usdg), address(weth), 400e6, 0, "");
        assertEq(vault.unallocatedBalance(address(usdg)), 1000e6);
    }

    /// @dev An adapter that reports more output than reached the vault is refused: the ledger never runs ahead of the
    ///      balance (DEC-080 fitness function).
    function test_DEC080_anOutputThatDidNotArriveIsRefused() public {
        spokeSwap.setReportedExtra(1);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.SwapOutputNotReceived.selector, 0.2e18 + 1, 0.2e18));
        vault.swap(address(spokeSwap), address(usdg), address(weth), 400e6, 0, "");
    }

    /// @dev More than the adapter reports reaching the vault is excess for the garbage collector, never ledger value.
    function test_DEC101_outputAboveWhatTheAdapterReportsIsExcess() public {
        weth.mint(address(vault), 1e15);
        vm.prank(manager);
        vault.swap(address(spokeSwap), address(usdg), address(weth), 400e6, 0, "");
        assertEq(vault.unallocatedBalance(address(weth)), 0.2e18, "credited from what the adapter returned");
        assertEq(vault.sweepExcess(address(weth)), 1e15);
    }

    /// @dev Every value-moving entry is `nonReentrant`: an adapter cannot call back into the vault mid-swap.
    function test_DEC080_aSwapAdapterCannotReenterTheVault() public {
        vm.etch(address(spokeSwap), address(new ReenteringSwapAdapter()).code);
        // A fresh vault pins the reentering code.
        _deploySpoke();
        _disableOperatingCash();
        _arrive(1000e6, ARRIVAL, TransferKind.Principal);
        vm.prank(manager);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vault.swap(address(spokeSwap), address(usdg), address(weth), 1e6, 0, "");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Collected income (DEC-092, CV-OQ-2)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC092_incomeSwapStaysInTheCollectedIncomeBucket() public {
        _arriveWethIncome(0.01e18);
        uint256 usdgBefore = vault.unallocatedBalance(address(usdg));
        vm.expectEmit(address(vault));
        emit ISpokeVaultIncome.IncomeSwapped(
            address(spokeSwap), address(weth), address(usdg), 0.01e18, 20e6, 20e6, 0, 0
        );
        vm.prank(manager);
        uint256 out = vault.swapCollectedIncome(address(spokeSwap), address(weth), 0.01e18, 0, "");
        assertEq(out, 20e6);
        assertEq(vault.collectedIncome(address(weth)), 0);
        assertEq(vault.collectedIncome(address(usdg)), 20e6);
        assertEq(vault.unallocatedBalance(address(usdg)), usdgBefore, "Unallocated Balance untouched");
        assertEq(vault.unallocatedBalance(address(weth)), 0);
        assertEq(IERC20(address(weth)).allowance(address(vault), address(spokeSwap)), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The real Uniswap V3 swap adapter: route, maximum loss, guard (DEC-142, DEC-143, DEC-153, DEC-056)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev DEC-153: without a route the adapter swaps in the best direct tier; the event carries its mid value.
    function test_DEC153_emptyRouteSwapsInTheBestDirectTier() public {
        _deployWithV3Adapter();
        uint256 expected = 400e6 * (1e6 - 500) / 1e6;
        vm.expectEmit(address(vault));
        emit ISpokeVault.Swapped(v3SwapAdapter, address(usdg), address(weth), 400e6, expected, 400e6, 0, 0);
        vm.prank(manager);
        uint256 out = vault.swap(v3SwapAdapter, address(usdg), address(weth), 400e6, 0, "");
        assertEq(out, expected, "the 0.05% tier, not the 0.3% one");
        assertEq(vault.unallocatedBalance(address(weth)), expected);
        assertEq(weth.balanceOf(address(vault)), expected);
        assertEq(usdg.balanceOf(v3SwapAdapter), 0, "the adapter keeps nothing");
    }

    /// @dev DEC-142: the manager's maximum loss against the pool mid binds; without one the swap runs at any price.
    function test_DEC142_theMaximumLossBindsAgainstThePoolMid() public {
        _deployWithV3Adapter();
        MockV3Pool(v3.getPool(address(weth), address(usdg), 500)).setImpactBps(100);
        MockV3Pool(v3.getPool(address(weth), address(usdg), 3000)).setImpactBps(100);
        uint256 best = 400e6 * (1e6 - 500) / 1e6 * 9900 / 10_000;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.InsufficientOutput.selector, best, 400e6 * 9950 / 10_000));
        vault.swap(v3SwapAdapter, address(usdg), address(weth), 400e6, 50, "");

        vm.expectEmit(address(vault));
        emit ISpokeVault.Swapped(v3SwapAdapter, address(usdg), address(weth), 400e6, best, 400e6, 200, 392e6);
        vm.prank(manager);
        assertEq(vault.swap(v3SwapAdapter, address(usdg), address(weth), 400e6, 200, ""), best);
    }

    /// @dev Founder chat 1, DEC-129, DEC-173: a route the Pool Party API signed runs, through a hop token the Mandate
    ///      does not list; the stricter of the API minimum and the maximum loss applies (DEC-142).
    function test_DEC173_aSignedApiRouteRunsThroughAHopOutsideTheMandate() public {
        _deployWithV3Adapter();
        assertFalse(vault.isMandateToken(address(hop)));
        bytes[] memory paths = new bytes[](1);
        paths[0] = abi.encodePacked(address(usdg), uint24(500), address(hop), uint24(100), address(weth));
        uint256 expected = 400e6 * (1e6 - 500) / 1e6 * (1e6 - 100) / 1e6;
        bytes memory route = _route(paths, address(usdg), address(weth), 400e6, expected, apiKey);

        vm.expectEmit(address(vault));
        emit ISpokeVault.Swapped(v3SwapAdapter, address(usdg), address(weth), 400e6, expected, 400e6, 100, expected);
        vm.prank(manager);
        assertEq(vault.swap(v3SwapAdapter, address(usdg), address(weth), 400e6, 100, route), expected);
        assertEq(hop.balanceOf(address(vault)), 0, "the hop token never reaches the vault");
        assertEq(vault.unallocatedBalance(address(weth)), expected);
    }

    /// @dev DEC-143: a route the API did not sign is the caller choosing the route, and is refused.
    function test_DEC143_aRouteTheApiDidNotSignIsRefused() public {
        _deployWithV3Adapter();
        bytes[] memory paths = new bytes[](1);
        paths[0] = abi.encodePacked(address(usdg), uint24(3000), address(weth));
        (, uint256 managerKey) = makeAddrAndKey("manager");
        bytes memory route = _route(paths, address(usdg), address(weth), 400e6, 0, managerKey);
        vm.prank(manager);
        vm.expectRevert(ISwapAdapter.InvalidRouteSignature.selector);
        vault.swap(v3SwapAdapter, address(usdg), address(weth), 400e6, 0, route);
    }

    /// @dev DEC-056, DEC-058: while the swap adapter is paused or deprecated a swap out of the base token (an entry) is
    ///      refused; a swap into it (an exit: the manager's sale or the income conversion) always runs.
    function test_DEC056_pauseAndDeprecationBlockEntriesNeverExits() public {
        _deployWithV3Adapter();
        vm.prank(manager);
        uint256 weth0 = vault.swap(v3SwapAdapter, address(usdg), address(weth), 400e6, 0, "");
        _arriveWethIncome(0.01e18);

        vm.prank(guardian);
        IAdapterGuard(v3SwapAdapter).setPaused(true);
        vm.startPrank(manager);
        vm.expectRevert(IAdapterGuard.AdapterPaused.selector);
        vault.swap(v3SwapAdapter, address(usdg), address(weth), 1e6, 0, "");
        vault.swap(v3SwapAdapter, address(weth), address(usdg), weth0 / 2, 0, "");
        vm.stopPrank();

        vm.prank(guardian);
        IAdapterGuard(v3SwapAdapter).deprecate();
        vm.startPrank(manager);
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        vault.swap(v3SwapAdapter, address(usdg), address(weth), 1e6, 0, "");
        vault.swap(v3SwapAdapter, address(weth), address(usdg), weth0 - weth0 / 2, 0, "");
        vault.swapCollectedIncome(v3SwapAdapter, address(weth), 0.01e18, 0, "");
        vm.stopPrank();
        assertEq(vault.unallocatedBalance(address(weth)), 0, "nothing stranded");
        assertEq(vault.collectedIncome(address(weth)), 0, "no income stranded");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev WETH income reaches the collected income bucket through a position's collection: 2 USDG are swapped into
    ///      WETH and supplied, and the position earns `amount` of WETH.
    function _arriveWethIncome(uint256 amount) internal {
        uint256 wethBefore = vault.unallocatedBalance(address(weth));
        vm.startPrank(manager);
        vault.swap(vault.swapAdapters()[0], address(usdg), address(weth), 2e6, 0, "");
        uint256 bought = vault.unallocatedBalance(address(weth)) - wethBefore;
        (bytes32 key,,) = vault.openPosition(address(spokeUni), SPOKE_POOL, bought, 0, "");
        vm.stopPrank();
        _earnIncome(spokeUni, key, amount, 0);
        vm.prank(manager);
        vault.collectIncome(address(spokeUni), key);
        assertEq(vault.collectedIncome(address(weth)), amount);
    }

    /// @dev A spoke vault whose Mandate swap adapter is the real `UniswapV3SwapAdapter` over the V3 stand-ins: WETH /
    ///      USDG pools at price 1 in the 0.05% and 0.3% tiers, and a hop token with USDG / HOP 0.05% and HOP / WETH
    ///      0.01% pools for API routes. The adapter is deployed first, for the vault's predicted address.
    function _deployWithV3Adapter() internal {
        vm.chainId(SPOKE);
        (apiSigner, apiKey) = makeAddrAndKey("pool-party-api");
        hop = new MockSpokeToken("Hop", "HOP", 18);
        v3 = new MockV3Factory();
        router = new MockSwapRouter02(v3);
        quoter = new MockQuoterV2(v3);
        v3.createPool(address(weth), address(usdg), 500, PRICE_ONE, LIQUIDITY);
        v3.createPool(address(weth), address(usdg), 3000, PRICE_ONE, LIQUIDITY);
        v3.createPool(address(usdg), address(hop), 500, PRICE_ONE, LIQUIDITY);
        v3.createPool(address(hop), address(weth), 100, PRICE_ONE, LIQUIDITY);

        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdg), address(weth));
        address vaultAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        v3SwapAdapter = address(
            new UniswapV3SwapAdapter(
                vaultAt, guardian, address(usdg), tokens, address(v3), address(router), address(quoter), apiSigner
            )
        );
        SpokeVault v = _deploySpoke();
        assertEq(address(v), vaultAt, "the adapter's vault");
        _disableOperatingCash();
        _arrive(1000e6, ARRIVAL, TransferKind.Principal);
    }

    /// @dev The Pool Party API's side: EIP-712 over one route for the real adapter, valid for 5 minutes.
    function _route(
        bytes[] memory paths,
        address tokenIn,
        address tokenOut,
        uint256 quotedAmountIn,
        uint256 minAmountOut,
        uint256 key
    ) internal view returns (bytes memory) {
        uint16[] memory weights = new uint16[](paths.length);
        weights[0] = 10_000;
        ISwapAdapter.ApiRoute memory r =
            ISwapAdapter.ApiRoute(paths, weights, quotedAmountIn, minAmountOut, block.timestamp + 300, "");
        bytes32 structHash = keccak256(
            abi.encode(
                UniswapV3SwapAdapter(v3SwapAdapter).ROUTE_TYPEHASH(),
                tokenIn,
                tokenOut,
                keccak256(abi.encode(r.paths, r.weightsBps)),
                r.quotedAmountIn,
                r.minAmountOut,
                r.deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Pool Party Swap Adapter"),
                keccak256("1"),
                block.chainid,
                v3SwapAdapter
            )
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        r.signature = abi.encodePacked(rr, ss, v);
        return abi.encode(r);
    }
}
