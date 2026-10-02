// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {ISwapAdapter} from "../../../src/interfaces/ISwapAdapter.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {UniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {EndToEndScenario} from "../e2e/EndToEnd.t.sol";

/// @notice The manager's swap verb on the live forks, through the swap adapter the FundFactory deployed for each chain
///         (WP-07 C1; founder, 2026-10-02: "swaps are not done in the fund pools, we need a swap adapter"; DEC-136):
///         WETH -> USDC on Arbitrum One and WETH -> USDG on Robinhood Chain, without the API (the adapter's best direct
///         Uniswap V3 tier, DEC-153) and with a route the Pool Party API signed (founder chat 1, DEC-129, DEC-173).
/// @dev The fund is the end-to-end scenario's (real FundFactory on both chains, phases 1-2), whose API signer is the
///      protocol deployment's `registryOwner`. On Robinhood the spoke's USDG arrives as the fork suites simulate an
///      Across fill. Every assertion holds at any recent block: amounts are read from QuoterV2 and the price source
///      in the same block, never hard-coded.
/// @dev Run: . <rpc env>; forge test --match-path test/fork/spoke/SwapAdapterVault.fork.t.sol -vv
contract SwapAdapterVaultFork is EndToEndScenario {
    address internal constant ARB_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    uint256 internal constant HUB_USDC = 4000e6;
    uint256 internal constant SPOKE_USDG = 4000e6;
    uint16 internal constant MAX_LOSS_BPS = 100;
    bytes32 internal constant EIP712_DOMAIN =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice What a vault `Swapped` event carried.
    struct Swap {
        uint256 amountIn;
        uint256 amountOut;
        uint256 spotOut;
        uint16 maxLossBps;
        uint256 minOut;
        uint256 gas;
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Arbitrum One: WETH -> USDC
    // -----------------------------------------------------------------------------------------------------------------

    function test_arbitrum_managerSwapsWethToUsdcThroughTheFactoryAdapter() public {
        uint256 weth = _hubFundHoldingWeth();
        uint256 usdcBefore = hubSpoke.unallocatedBalance(ARB_USDC);
        (uint24 fee, uint256 quoted) =
            UniswapV3SwapAdapter(hubSwapAdapter).bestDirectFee(ARB_WETH, ARB_USDC, weth, MAX_LOSS_BPS);

        Swap memory s = _swap(hubSpoke, hubSwapAdapter, ARB_WETH, ARB_USDC, weth, MAX_LOSS_BPS, "");
        console2.log("Arbitrum, no API: WETH in / USDC out", s.amountIn, s.amountOut);
        console2.log("  tier", uint256(fee), "vault.swap gas", s.gas);

        assertEq(s.amountOut, quoted, "DEC-153: the best direct tier's quote");
        _assertSale(hubSpoke, hubSwapAdapter, ARB_WETH, ARB_USDC, s, weth, usdcBefore);
        assertEq(s.minOut, s.spotOut * (10_000 - MAX_LOSS_BPS) / 10_000, "DEC-142: the maximum loss against the mid");
        _assertNearOracle(s.amountOut, weth);
    }

    /// @dev A CLASSIC-quote-shaped split the API signed: 60% through USDT, which the Mandate does not list (DEC-173), and
    ///      40% direct. The vault pays exactly the route's quote in this block.
    function test_arbitrum_managerSwapsWethToUsdcWithASignedApiRoute() public {
        uint256 weth = _hubFundHoldingWeth();
        uint256 usdcBefore = hubSpoke.unallocatedBalance(ARB_USDC);
        assertFalse(hubSpoke.isMandateToken(ARB_USDT), "USDT is not a Mandate token");
        bytes[] memory paths = new bytes[](2);
        paths[0] = abi.encodePacked(ARB_WETH, uint24(500), ARB_USDT, uint24(100), ARB_USDC);
        paths[1] = abi.encodePacked(ARB_WETH, uint24(500), ARB_USDC);
        uint16[] memory weights = new uint16[](2);
        (weights[0], weights[1]) = (6000, 4000);
        uint256 quoted = _quote(ARB_V3_QUOTER_V2, paths, weights, weth);
        bytes memory route = _signedRoute(hubSwapAdapter, paths, weights, ARB_WETH, ARB_USDC, weth, quoted * 995 / 1000);

        Swap memory s = _swap(hubSpoke, hubSwapAdapter, ARB_WETH, ARB_USDC, weth, MAX_LOSS_BPS, route);
        console2.log("Arbitrum, signed API route (60% via USDT): WETH in / USDC out", s.amountIn, s.amountOut);
        console2.log("  vault.swap gas", s.gas, "route bytes", route.length);

        assertEq(s.amountOut, quoted, "the route's quote, to the unit");
        _assertSale(hubSpoke, hubSwapAdapter, ARB_WETH, ARB_USDC, s, weth, usdcBefore);
        assertEq(
            s.minOut,
            Math.max(quoted * 995 / 1000, s.spotOut * (10_000 - MAX_LOSS_BPS) / 10_000),
            "DEC-142: the stricter of the API minimum and the maximum loss"
        );
        assertEq(IERC20(ARB_USDT).balanceOf(address(hubSpoke)), 0, "the hop token never reaches the vault");
        _assertNearOracle(s.amountOut, weth);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Robinhood Chain: WETH -> USDG
    // -----------------------------------------------------------------------------------------------------------------

    function test_robinhood_managerSwapsWethToUsdgThroughTheFactoryAdapter() public {
        uint256 weth = _spokeHoldingWeth();
        uint256 usdgBefore = spokeVault.unallocatedBalance(RH_USDG);
        (uint24 fee, uint256 quoted) =
            UniswapV3SwapAdapter(spokeSwapAdapter).bestDirectFee(RH_WETH, RH_USDG, weth, MAX_LOSS_BPS);

        Swap memory s = _swap(spokeVault, spokeSwapAdapter, RH_WETH, RH_USDG, weth, MAX_LOSS_BPS, "");
        console2.log("Robinhood, no API: WETH in / USDG out", s.amountIn, s.amountOut);
        console2.log("  tier", uint256(fee), "vault.swap gas", s.gas);

        assertEq(s.amountOut, quoted, "DEC-153: the best direct tier's quote");
        _assertSale(spokeVault, spokeSwapAdapter, RH_WETH, RH_USDG, s, weth, usdgBefore);
        assertEq(s.minOut, s.spotOut * (10_000 - MAX_LOSS_BPS) / 10_000, "DEC-142: the maximum loss against the mid");
        _assertNearOracle(s.amountOut, weth);
    }

    /// @dev A one-leg route the API signed in the tier QuoterV2 ranks best now; the vault pays exactly its quote.
    function test_robinhood_managerSwapsWethToUsdgWithASignedApiRoute() public {
        uint256 weth = _spokeHoldingWeth();
        uint256 usdgBefore = spokeVault.unallocatedBalance(RH_USDG);
        (uint24 fee,) = UniswapV3SwapAdapter(spokeSwapAdapter).bestDirectFee(RH_WETH, RH_USDG, weth, 0);
        bytes[] memory paths = new bytes[](1);
        paths[0] = abi.encodePacked(RH_WETH, fee, RH_USDG);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        uint256 quoted = _quote(RH_V3_QUOTER_V2, paths, weights, weth);
        bytes memory route = _signedRoute(spokeSwapAdapter, paths, weights, RH_WETH, RH_USDG, weth, quoted * 995 / 1000);

        Swap memory s = _swap(spokeVault, spokeSwapAdapter, RH_WETH, RH_USDG, weth, MAX_LOSS_BPS, route);
        console2.log("Robinhood, signed API route: WETH in / USDG out", s.amountIn, s.amountOut);
        console2.log("  tier", uint256(fee), "vault.swap gas", s.gas);

        assertEq(s.amountOut, quoted, "the route's quote, to the unit");
        _assertSale(spokeVault, spokeSwapAdapter, RH_WETH, RH_USDG, s, weth, usdgBefore);
        _assertNearOracle(s.amountOut, weth);
    }

    /// @dev DEC-143: on the live fork too, a route the API did not sign is refused.
    function test_robinhood_aRouteTheApiDidNotSignIsRefused() public {
        uint256 weth = _spokeHoldingWeth();
        bytes[] memory paths = new bytes[](1);
        paths[0] = abi.encodePacked(RH_WETH, uint24(500), RH_USDG);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        (, uint256 managerKey) = makeAddrAndKey("manager");
        bytes memory route = _route(spokeSwapAdapter, paths, weights, RH_WETH, RH_USDG, weth, 0, managerKey);
        vm.prank(manager);
        vm.expectRevert(ISwapAdapter.InvalidRouteSignature.selector);
        spokeVault.swap(spokeSwapAdapter, RH_WETH, RH_USDG, weth, MAX_LOSS_BPS, route);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Set-up
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev The scenario's fund on both chains (phases 1-2); the manager allocates 4,000 USDC to the hub Spoke Vault
    ///      and buys WETH with half of it through the factory's swap adapter. Returns the WETH held.
    function _hubFundHoldingWeth() internal returns (uint256 weth) {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _assertFactoryAdapter(hubSpoke, hubSwapAdapter, ARB_USDC);
        vm.prank(manager);
        core.allocateToHubSpokeVault(HUB_USDC);
        weth = _swap(hubSpoke, hubSwapAdapter, ARB_USDC, ARB_WETH, HUB_USDC / 2, MAX_LOSS_BPS, "").amountOut;
        assertEq(hubSpoke.unallocatedBalance(ARB_WETH), weth);
    }

    /// @dev The scenario's spoke receives 4,000 USDG (an Across fill as the fork suites simulate it) and the manager buys
    ///      WETH with half of it through the factory's swap adapter. Returns the WETH held.
    function _spokeHoldingWeth() internal returns (uint256 weth) {
        _createForks();
        _phase1CreateFund();
        _onRobinhood();
        _assertFactoryAdapter(spokeVault, spokeSwapAdapter, RH_USDG);
        address vault = address(spokeVault);
        deal(RH_USDG, vault, IERC20(RH_USDG).balanceOf(vault) + SPOKE_USDG);
        vm.prank(RH_ACROSS_SPOKE_POOL);
        spokeVault.handleV3AcrossMessage(
            RH_USDG,
            SPOKE_USDG,
            relayer,
            TransitMessage.encode(fundId, ARBITRUM, keccak256("swap test arrival"), TransferKind.Principal)
        );
        weth = _swap(spokeVault, spokeSwapAdapter, RH_USDG, RH_WETH, SPOKE_USDG / 2, MAX_LOSS_BPS, "").amountOut;
        assertEq(spokeVault.unallocatedBalance(RH_WETH), weth);
    }

    /// @dev DEC-136: the vault pins the swap adapter the factory deployed for its chain, built for this vault, with
    ///      the API signer as route signer (D-01) and the chain's base token.
    function _assertFactoryAdapter(ISpokeVault vault, address adapter, address baseToken) internal view {
        address[] memory pinned = SpokeVault(address(vault)).swapAdapters();
        assertEq(pinned.length, 1);
        assertEq(pinned[0], adapter, "the Mandate's swap adapter of this chain");
        assertEq(vault.adapterCodehash(adapter), adapter.codehash, "Q17-4: codehash pinned");
        UniswapV3SwapAdapter a = UniswapV3SwapAdapter(adapter);
        assertEq(a.vault(), address(vault));
        assertEq(a.baseToken(), baseToken);
        assertEq(a.routeSigner(), registryOwner, "the API signer of the protocol deployment");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev The manager's swap, and what its `Swapped` event carried.
    function _swap(
        ISpokeVault vault,
        address adapter,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint16 maxLossBps,
        bytes memory route
    ) internal returns (Swap memory s) {
        vm.recordLogs();
        uint256 g = gasleft();
        vm.prank(manager);
        uint256 out = vault.swap(adapter, tokenIn, tokenOut, amountIn, maxLossBps, route);
        s.gas = g - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != ISpokeVault.Swapped.selector) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), adapter, "event: adapter");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), tokenIn, "event: tokenIn");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), tokenOut, "event: tokenOut");
            (s.amountIn, s.amountOut, s.spotOut, s.maxLossBps, s.minOut) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint16, uint256));
            seen = true;
        }
        assertTrue(seen, "the vault emitted Swapped");
        assertEq(s.amountOut, out);
        assertEq(s.amountIn, amountIn);
        assertEq(s.maxLossBps, maxLossBps);
        assertGe(s.amountOut, s.minOut, "the output met the limit it was held to");
    }

    /// @dev DEC-079, DEC-080: the sale debited exactly the input, credited exactly the output, kept the ledger equal to
    ///      the balances and left nothing with the adapter.
    function _assertSale(
        ISpokeVault vault,
        address adapter,
        address tokenIn,
        address tokenOut,
        Swap memory s,
        uint256 inBefore,
        uint256 outBefore
    ) internal view {
        assertEq(vault.unallocatedBalance(tokenIn), inBefore - s.amountIn, "input debited exactly");
        assertEq(vault.unallocatedBalance(tokenOut), outBefore + s.amountOut, "output credited");
        assertEq(IERC20(tokenIn).balanceOf(address(vault)), _ledger(vault, tokenIn), "ledger = balance (in)");
        assertEq(IERC20(tokenOut).balanceOf(address(vault)), _ledger(vault, tokenOut), "ledger = balance (out)");
        assertEq(IERC20(tokenIn).allowance(address(vault), adapter), 0, "no approval left");
        assertEq(IERC20(tokenIn).balanceOf(adapter), 0, "the adapter keeps nothing");
    }

    function _ledger(ISpokeVault vault, address token) internal view returns (uint256 total) {
        total = vault.unallocatedBalance(token) + vault.collectedIncome(token);
        if (token == vault.baseToken()) total += vault.operatingCash();
    }

    /// @dev The sale is within 2% of the hub price source (Chainlink ETH / USD; USDG at 1:1, ruling 2026-09-29).
    function _assertNearOracle(uint256 dollarsOut, uint256 weth) internal {
        uint256 here = vm.activeFork();
        _onArbitrum();
        uint256 fair = _usdcValue(ARB_WETH, weth);
        vm.selectFork(here);
        assertApproxEqRel(dollarsOut, fair, 0.02e18, "within 2% of the price source");
    }

    /// @dev QuoterV2's output for the route's legs, split as the adapter splits them (the last leg takes the rest).
    function _quote(address quoter, bytes[] memory paths, uint16[] memory weights, uint256 amountIn)
        internal
        returns (uint256 total)
    {
        uint256 left = amountIn;
        for (uint256 i; i < paths.length; ++i) {
            uint256 amount = i + 1 == paths.length ? left : Math.mulDiv(amountIn, weights[i], 10_000);
            left -= amount;
            (uint256 out,,,) = IQuoterV2(quoter).quoteExactInput(paths[i], amount);
            total += out;
        }
    }

    /// @dev A route signed by the protocol deployment's API signer (`registryOwner`).
    function _signedRoute(
        address adapter,
        bytes[] memory paths,
        uint16[] memory weights,
        address tokenIn,
        address tokenOut,
        uint256 quotedAmountIn,
        uint256 minAmountOut
    ) internal returns (bytes memory) {
        (address signer, uint256 key) = makeAddrAndKey("registryOwner");
        assertEq(signer, registryOwner);
        return _route(adapter, paths, weights, tokenIn, tokenOut, quotedAmountIn, minAmountOut, key);
    }

    /// @dev The Pool Party API's side: EIP-712 over the route, bound to `adapter` (one fund on one chain), valid for
    ///      5 minutes.
    function _route(
        address adapter,
        bytes[] memory paths,
        uint16[] memory weights,
        address tokenIn,
        address tokenOut,
        uint256 quotedAmountIn,
        uint256 minAmountOut,
        uint256 key
    ) internal view returns (bytes memory) {
        ISwapAdapter.ApiRoute memory r =
            ISwapAdapter.ApiRoute(paths, weights, quotedAmountIn, minAmountOut, block.timestamp + 300, "");
        bytes32 structHash = keccak256(
            abi.encode(
                UniswapV3SwapAdapter(adapter).ROUTE_TYPEHASH(),
                tokenIn,
                tokenOut,
                keccak256(abi.encode(paths, weights)),
                quotedAmountIn,
                minAmountOut,
                r.deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(EIP712_DOMAIN, keccak256("Pool Party Swap Adapter"), keccak256("1"), block.chainid, adapter)
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        r.signature = abi.encodePacked(rr, ss, v);
        return abi.encode(r);
    }
}
