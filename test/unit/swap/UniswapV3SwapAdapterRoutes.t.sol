// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {ISwapAdapter} from "../../../src/interfaces/ISwapAdapter.sol";
import {MockRouteSigner1271} from "../../mocks/swap/MockV3.sol";
import {SwapAdapterTestBase} from "./SwapAdapterTestBase.sol";

/// @notice Routes from the Pool Party API (DEC-129 default path, DEC-136, DEC-143; founder, 2026-10-02: "receive the
///         route from uniswap api that we'll send via our api's signed interaction"): only a route signed by the route
///         signer changes the route (D-01, D-02), within Mandate tokens (D-52), the four V3 tiers and factory pools.
contract UniswapV3SwapAdapterRoutesTest is SwapAdapterTestBase {
    /// @dev The API's encoder depends on this exact string.
    function test_D01_routeTypeHashIsTheDocumentedOne() public view {
        assertEq(
            adapter.ROUTE_TYPEHASH(),
            keccak256(
                "SwapRoute(address tokenIn,address tokenOut,bytes32 legsHash,uint256 quotedAmountIn,uint256 minAmountOut,uint256 deadline)"
            )
        );
    }

    // ------------------------------------------------------------------------------------------------------------
    // A signed route runs
    // ------------------------------------------------------------------------------------------------------------

    function test_DEC129_signedSplitRoutePaysTheVault() public {
        (bytes[] memory paths, uint16[] memory w) = _splitLegs();
        uint256 leg0 = AMOUNT * 6000 / 10_000;
        uint256 expected = _out(_out(leg0, 500, 0), 100, 0) + _out(AMOUNT - leg0, 500, 0);
        bytes memory route = _route(paths, w, address(weth), address(base), AMOUNT, expected, apiKey);

        _fund(address(weth), AMOUNT);
        vm.expectEmit(address(adapter));
        emit ISwapAdapter.Swapped(
            address(weth), address(base), AMOUNT, expected, AMOUNT, 0, keccak256(abi.encode(paths, w))
        );
        (uint256 out, uint256 spot) = adapter.swap(address(weth), address(base), AMOUNT, NO_MAX, route);
        assertEq(out, expected);
        assertEq(spot, AMOUNT, "sum of the legs' mid values");
        assertEq(base.balanceOf(address(this)), expected, "every leg paid the vault");
        assertEq(router.calls(), 2, "one exactInput per leg");
        assertEq(quoter.quotes(address(wethBase[1])), 0, "a signed route needs no tier comparison");
        _assertNothingKept(address(weth));
    }

    /// @dev Anyone may relay a signed route: the signature, not the caller, is the API's authority (D-01). Here the
    ///      signer is a contract (EIP-1271), e.g. a multisig holding the API key.
    function test_D01_eip1271RouteSignerIsAccepted() public {
        MockRouteSigner1271 signer = new MockRouteSigner1271(apiSigner);
        adapter = _deploy(address(signer), _mandate4());
        (bytes[] memory paths, uint16[] memory w) = _one(_path1(address(weth), 500, address(base)));
        (uint256 out,) = _swap(
            address(weth),
            address(base),
            AMOUNT,
            NO_MAX,
            _route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey)
        );
        assertEq(out, _out(AMOUNT, 500, 0));
    }

    /// @dev DEC-052: a fund without an API signer still swaps (empty route) and refuses every route.
    function test_DEC052_zeroRouteSignerRefusesRoutesButStillSwaps() public {
        adapter = _deploy(address(0), _mandate4());
        (bytes[] memory paths, uint16[] memory w) = _one(_path1(address(weth), 500, address(base)));
        bytes memory route = _route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey);
        _fund(address(weth), AMOUNT);
        vm.expectRevert(ISwapAdapter.InvalidRouteSignature.selector);
        adapter.swap(address(weth), address(base), AMOUNT, NO_MAX, route);
        (uint256 out,) = adapter.swap(address(weth), address(base), AMOUNT, NO_MAX, "");
        assertEq(out, _out(AMOUNT, 500, 0));
    }

    // ------------------------------------------------------------------------------------------------------------
    // DEC-143: only the API's signature changes the route
    // ------------------------------------------------------------------------------------------------------------

    function test_DEC143_routeSignedByAnotherKeyIsRefused() public {
        (, uint256 managerKey) = makeAddrAndKey("manager");
        (bytes[] memory paths, uint16[] memory w) = _splitLegs();
        _expectRefused(_route(paths, w, address(weth), address(base), AMOUNT, 0, managerKey), _sigError());
    }

    function test_DEC143_tamperedWeightsAreRefused() public {
        (bytes[] memory paths, uint16[] memory w) = _splitLegs();
        ISwapAdapter.ApiRoute memory r =
            abi.decode(_route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey), (ISwapAdapter.ApiRoute));
        (r.weightsBps[0], r.weightsBps[1]) = (1000, 9000);
        _expectRefused(abi.encode(r), _sigError());
    }

    function test_DEC143_tamperedPathMinimumOrQuotedAmountIsRefused() public {
        (bytes[] memory paths, uint16[] memory w) = _splitLegs();
        bytes memory signed = _route(paths, w, address(weth), address(base), AMOUNT, AMOUNT / 2, apiKey);

        ISwapAdapter.ApiRoute memory r = abi.decode(signed, (ISwapAdapter.ApiRoute));
        r.paths[1] = _path1(address(weth), 3000, address(base));
        _expectRefused(abi.encode(r), _sigError());

        r = abi.decode(signed, (ISwapAdapter.ApiRoute));
        r.minAmountOut = 0;
        _expectRefused(abi.encode(r), _sigError());

        r = abi.decode(signed, (ISwapAdapter.ApiRoute));
        r.quotedAmountIn = AMOUNT * 2;
        _expectRefused(abi.encode(r), _sigError());
    }

    /// @dev The EIP-712 domain binds a route to one adapter, so to one fund on one chain.
    function test_DEC143_routeSignedForAnotherAdapterIsRefused() public {
        UniswapV3SwapAdapter other = _deploy(apiSigner, _mandate4());
        (bytes[] memory paths, uint16[] memory w) = _one(_path1(address(weth), 500, address(base)));
        ISwapAdapter.ApiRoute memory r = ISwapAdapter.ApiRoute(paths, w, AMOUNT, 0, block.timestamp + 300, "");
        r.signature = _sign(address(other), r, address(weth), address(base), apiKey);
        _expectRefused(abi.encode(r), _sigError());
    }

    function test_D01_expiredRouteIsRefusedAndTheDeadlineItselfPasses() public {
        (bytes[] memory paths, uint16[] memory w) = _one(_path1(address(weth), 500, address(base)));
        bytes memory route = _route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey);
        uint256 deadline = block.timestamp + 300;
        vm.warp(deadline + 1);
        _expectRefused(route, abi.encodeWithSelector(ISwapAdapter.RouteExpired.selector, deadline));
        vm.warp(deadline);
        (uint256 out,) = adapter.swap(address(weth), address(base), AMOUNT, NO_MAX, route);
        assertEq(out, _out(AMOUNT, 500, 0));
    }

    // ------------------------------------------------------------------------------------------------------------
    // What a signed route may contain (D-52, DEC-153 tiers, factory pools, shape)
    // ------------------------------------------------------------------------------------------------------------

    /// @dev D-52 (DEC-136 item 2): every hop token is a Mandate token. With USDT outside the Mandate, the same
    ///      signed route through USDT is refused.
    function test_D52_aHopThroughATokenOutsideTheMandateIsRefused() public {
        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(base), address(weth), address(stock));
        adapter = _deploy(apiSigner, tokens);
        (bytes[] memory paths, uint16[] memory w) = _splitLegs();
        _expectRefused(
            _route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey),
            abi.encodeWithSelector(ISwapAdapter.TokenNotInMandate.selector, address(usdt))
        );
    }

    function test_DEC153_aNonStandardFeeIsRefusedEvenWhenSigned() public {
        (bytes[] memory paths, uint16[] memory w) = _one(_path1(address(weth), 2500, address(base)));
        _expectRefused(
            _route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey),
            abi.encodeWithSelector(ISwapAdapter.InvalidFee.selector, uint24(2500))
        );
    }

    function test_DEC153_aPoolTheFactoryDidNotDeployIsRefused() public {
        (bytes[] memory paths, uint16[] memory w) = _one(_path2(address(weth), 500, address(stock), 500, address(base)));
        _expectRefused(
            _route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey),
            abi.encodeWithSelector(ISwapAdapter.PoolNotFound.selector, address(weth), address(stock), uint24(500))
        );
    }

    function test_D20_atMostFourLegs() public {
        bytes[] memory paths = new bytes[](5);
        uint16[] memory w = new uint16[](5);
        for (uint256 i; i < 5; ++i) {
            (paths[i], w[i]) = (_path1(address(weth), 500, address(base)), 2000);
        }
        _expectRefused(_route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey), _legsError());

        bytes[] memory four = new bytes[](4);
        uint16[] memory w4 = new uint16[](4);
        for (uint256 i; i < 4; ++i) {
            (four[i], w4[i]) = (_path1(address(weth), 500, address(base)), 2500);
        }
        (uint256 out,) = adapter.swap(
            address(weth),
            address(base),
            AMOUNT,
            NO_MAX,
            _route(four, w4, address(weth), address(base), AMOUNT, 0, apiKey)
        );
        assertEq(out, 4 * _out(AMOUNT / 4, 500, 0));
        assertEq(router.calls(), 4);
    }

    /// @dev Three hops pass (WETH -> USDT -> WETH -> base); four are refused.
    function test_D20_atMostThreeHops() public {
        bytes memory three = abi.encodePacked(
            address(weth), uint24(500), address(usdt), uint24(500), address(weth), uint24(500), address(base)
        );
        bytes memory four = abi.encodePacked(
            address(weth),
            uint24(500),
            address(usdt),
            uint24(500),
            address(weth),
            uint24(500),
            address(usdt),
            uint24(100),
            address(base)
        );
        (bytes[] memory paths, uint16[] memory w) = _one(four);
        _expectRefused(
            _route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey),
            abi.encodeWithSelector(ISwapAdapter.InvalidPath.selector)
        );
        (paths, w) = _one(three);
        (uint256 out,) = adapter.swap(
            address(weth),
            address(base),
            AMOUNT,
            NO_MAX,
            _route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey)
        );
        assertEq(out, _out(_out(_out(AMOUNT, 500, 0), 500, 0), 500, 0));
    }

    function test_D20_aPathMustRunFromTokenInToTokenOut() public {
        bytes memory invalid = abi.encodeWithSelector(ISwapAdapter.InvalidPath.selector);
        (bytes[] memory paths, uint16[] memory w) = _one(_path1(address(stock), 500, address(base)));
        _expectRefused(_route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey), invalid);
        (paths, w) = _one(_path1(address(weth), 500, address(usdt)));
        _expectRefused(_route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey), invalid);
        (paths, w) = _one(abi.encodePacked(address(weth), uint24(500), address(base), uint8(0)));
        _expectRefused(_route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey), invalid);
        (paths, w) = _one(abi.encodePacked(address(weth)));
        _expectRefused(_route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey), invalid);
    }

    function test_D20_weightsMustBePositiveMatchAndSumToTheWhole() public {
        bytes memory path = _path1(address(weth), 500, address(base));
        bytes[] memory two = new bytes[](2);
        (two[0], two[1]) = (path, path);
        uint16[] memory w = new uint16[](2);

        (w[0], w[1]) = (6000, 3999);
        _expectRefused(_route(two, w, address(weth), address(base), AMOUNT, 0, apiKey), _legsError());
        (w[0], w[1]) = (10_000, 0);
        _expectRefused(_route(two, w, address(weth), address(base), AMOUNT, 0, apiKey), _legsError());
        uint16[] memory one = new uint16[](1);
        one[0] = 10_000;
        _expectRefused(_route(two, one, address(weth), address(base), AMOUNT, 0, apiKey), _legsError());
        _expectRefused(
            _route(new bytes[](0), new uint16[](0), address(weth), address(base), AMOUNT, 0, apiKey), _legsError()
        );
        (bytes[] memory paths, uint16[] memory w1) = _one(path);
        _expectRefused(_route(paths, w1, address(weth), address(base), 0, 0, apiKey), _legsError());
    }

    // ------------------------------------------------------------------------------------------------------------
    // DEC-142: the stricter minimum wins; DEC-136 item 4 / DEC-137: the route scales to the amount sold
    // ------------------------------------------------------------------------------------------------------------

    function test_DEC142_theStricterOfTheApiMinimumAndTheMaximumLossWins() public {
        (bytes[] memory paths, uint16[] memory w) = _one(_path1(address(weth), 500, address(base)));
        uint256 quoted = _out(AMOUNT, 500, 0);

        // The API minimum is above what the pool pays and the caller sent no maximum: refused.
        bytes memory tight = _route(paths, w, address(weth), address(base), AMOUNT, quoted + 1, apiKey);
        _expectRefused(tight, abi.encodeWithSelector(ISwapAdapter.InsufficientOutput.selector, quoted, quoted + 1));

        // The API minimum is zero and the caller's 1 bp is stricter: refused at the caller's bound.
        bytes memory loose = _route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey);
        vm.expectRevert(
            abi.encodeWithSelector(ISwapAdapter.InsufficientOutput.selector, quoted, AMOUNT * 9999 / 10_000)
        );
        adapter.swap(address(weth), address(base), AMOUNT, 1, loose);
    }

    function test_DEC142_bothBoundsSatisfiedPass() public {
        (bytes[] memory paths, uint16[] memory w) = _one(_path1(address(weth), 500, address(base)));
        uint256 quoted = _out(AMOUNT, 500, 0);
        (uint256 out,) = _swap(
            address(weth),
            address(base),
            AMOUNT,
            5,
            _route(paths, w, address(weth), address(base), AMOUNT, quoted, apiKey)
        );
        assertEq(out, quoted);
    }

    /// @dev A route signed for 10 sells 9.5: the legs split 9.5 and the API minimum scales to 9.5 / 10 of itself.
    function test_DEC137_routeScalesToTheAmountSold() public {
        (bytes[] memory paths, uint16[] memory w) = _splitLegs();
        uint256 sold = AMOUNT * 95 / 100;
        uint256 leg0 = sold * 6000 / 10_000;
        uint256 expected = _out(_out(leg0, 500, 0), 100, 0) + _out(sold - leg0, 500, 0);
        uint256 quotedFor10 = _out(_out(AMOUNT * 6000 / 10_000, 500, 0), 100, 0) + _out(AMOUNT * 4000 / 10_000, 500, 0);

        (uint256 out,) = _swap(
            address(weth),
            address(base),
            sold,
            NO_MAX,
            _route(paths, w, address(weth), address(base), AMOUNT, quotedFor10, apiKey)
        );
        assertEq(out, expected);

        // A minimum just above what 9.5 pays, once scaled, refuses it.
        uint256 minFor10 = (expected + 1) * AMOUNT / sold + 1;
        _fund(address(weth), sold);
        vm.expectRevert(
            abi.encodeWithSelector(ISwapAdapter.InsufficientOutput.selector, expected, minFor10 * sold / AMOUNT)
        );
        adapter.swap(
            address(weth),
            address(base),
            sold,
            NO_MAX,
            _route(paths, w, address(weth), address(base), AMOUNT, minFor10, apiKey)
        );
    }

    /// @dev An unwind can sell dust: a leg whose share rounds to zero is skipped (a V3 pool rejects a zero amount), and
    ///      the rest of the input runs through the other legs.
    function test_D20_aLegWhoseShareRoundsToZeroIsSkipped() public {
        (bytes[] memory paths, uint16[] memory w) = _splitLegs();
        (uint256 out,) = _swap(
            address(weth), address(base), 1, NO_MAX, _route(paths, w, address(weth), address(base), AMOUNT, 0, apiKey)
        );
        assertEq(router.calls(), 1, "only the leg with a non-zero share ran");
        assertEq(out, _out(1, 500, 0));
        _assertNothingKept(address(weth));
    }

    /// @dev Any split of any amount spends the whole input, and every pool's mid price is read before any leg trades:
    ///      both legs cross the same drifting pool and `spotOut` is still the pre-trade value.
    function testFuzz_D20_splitSpendsTheWholeInputAtPreTradeSpot(uint256 amountIn, uint16 w0) public {
        amountIn = bound(amountIn, 1, 1e30);
        w0 = uint16(bound(w0, 1, 9999));
        wethBase[1].setDriftBps(50);
        bytes memory path = _path1(address(weth), 500, address(base));
        bytes[] memory paths = new bytes[](2);
        (paths[0], paths[1]) = (path, path);
        uint16[] memory w = new uint16[](2);
        (w[0], w[1]) = (w0, 10_000 - w0);
        (, uint256 spot) = _swap(
            address(weth),
            address(base),
            amountIn,
            NO_MAX,
            _route(paths, w, address(weth), address(base), amountIn, 0, apiKey)
        );
        assertEq(spot, amountIn, "pre-trade mid value of both legs");
        _assertNothingKept(address(weth));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Funds and approves `AMOUNT` of WETH and expects the WETH -> base swap with `route` to revert with `err`.
    function _expectRefused(bytes memory route, bytes memory err) internal {
        _fund(address(weth), AMOUNT);
        vm.expectRevert(err);
        adapter.swap(address(weth), address(base), AMOUNT, NO_MAX, route);
    }

    function _sigError() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ISwapAdapter.InvalidRouteSignature.selector);
    }

    function _legsError() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ISwapAdapter.InvalidLegs.selector);
    }
}
