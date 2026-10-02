// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {ISwapAdapter} from "../../../src/interfaces/ISwapAdapter.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {MockV3Factory, MockV3Pool, MockQuoterV2, MockSwapRouter02} from "../../mocks/swap/MockV3.sol";

/// @notice Fixture of the swap adapter unit tests. The test contract plays the Spoke Vault: it holds the tokens,
///         approves the adapter for exactly the input and receives every output.
/// @dev Every pool starts at price 1 (`sqrtPriceX96 = 2^96`), so a mid value equals the input and an output is the
///      input less the pool fee and the pool's configured price impact. The WETH/base pair has the four tiers:
///      0.01% with 60 bps of impact, 0.05% without impact (the best), 0.3% and 1%.
abstract contract SwapAdapterTestBase is Test {
    uint160 internal constant PRICE_ONE = uint160(1 << 96);
    uint128 internal constant LIQUIDITY = 1e24;
    uint16 internal constant NO_MAX = 0;
    uint256 internal constant AMOUNT = 10e18;
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    MockToken internal base;
    MockToken internal weth;
    MockToken internal stock;
    MockToken internal usdt;
    MockToken internal outsider;

    MockV3Factory internal factory;
    MockQuoterV2 internal quoter;
    MockSwapRouter02 internal router;
    MockV3Pool[4] internal wethBase;
    MockV3Pool internal wethUsdt500;
    MockV3Pool internal usdtBase100;
    MockV3Pool internal stockBase500;

    UniswapV3SwapAdapter internal adapter;
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");
    address internal apiSigner;
    uint256 internal apiKey;

    function setUp() public virtual {
        base = new MockToken("BASE", 18);
        weth = new MockToken("WETH", 18);
        stock = new MockToken("STOCK", 18);
        usdt = new MockToken("USDT", 18);
        outsider = new MockToken("OUT", 18);
        factory = new MockV3Factory();
        quoter = new MockQuoterV2(factory);
        router = new MockSwapRouter02(factory);
        (apiSigner, apiKey) = makeAddrAndKey("pool-party-api");

        uint24[4] memory tiers = [uint24(100), 500, 3000, 10_000];
        for (uint256 i; i < 4; ++i) {
            wethBase[i] = factory.createPool(address(weth), address(base), tiers[i], PRICE_ONE, LIQUIDITY);
        }
        wethBase[0].setImpactBps(60);
        wethUsdt500 = factory.createPool(address(weth), address(usdt), 500, PRICE_ONE, LIQUIDITY);
        usdtBase100 = factory.createPool(address(usdt), address(base), 100, PRICE_ONE, LIQUIDITY);
        stockBase500 = factory.createPool(address(stock), address(base), 500, PRICE_ONE, LIQUIDITY);

        adapter = _deploy(apiSigner, _mandate4());
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _deploy(address signer, address[] memory tokens) internal returns (UniswapV3SwapAdapter) {
        return new UniswapV3SwapAdapter(
            address(this), guardian, address(base), tokens, address(factory), address(router), address(quoter), signer
        );
    }

    function _mandate4() internal view returns (address[] memory t) {
        t = new address[](4);
        (t[0], t[1], t[2], t[3]) = (address(base), address(weth), address(stock), address(usdt));
    }

    /// @dev The vault side of a swap: holds `amountIn`, approves exactly that, calls the adapter.
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint16 maxLossBps, bytes memory route)
        internal
        returns (uint256 amountOut, uint256 spotOut)
    {
        _fund(tokenIn, amountIn);
        (amountOut, spotOut) = adapter.swap(tokenIn, tokenOut, amountIn, maxLossBps, route);
    }

    function _fund(address token, uint256 amount) internal {
        MockToken(token).mint(address(this), amount);
        IERC20(token).approve(address(adapter), amount);
    }

    /// @dev Output of the shared pricing model at price 1: input less fee (hundredths of a bip) less impact (bps).
    function _out(uint256 amountIn, uint24 fee, uint256 impactBps) internal pure returns (uint256) {
        return amountIn * (1e6 - fee) / 1e6 * (10_000 - impactBps) / 10_000;
    }

    /// @dev The adapter keeps nothing: no input token, no router allowance, the vault's approval fully consumed.
    function _assertNothingKept(address tokenIn) internal view {
        assertEq(IERC20(tokenIn).balanceOf(address(adapter)), 0, "adapter keeps no input");
        assertEq(IERC20(tokenIn).allowance(address(adapter), address(router)), 0, "router approval cleared");
        assertEq(IERC20(tokenIn).allowance(address(this), address(adapter)), 0, "vault approval consumed exactly");
    }

    function _path1(address a, uint24 fee, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, fee, b);
    }

    function _path2(address a, uint24 f1, address b, uint24 f2, address c) internal pure returns (bytes memory) {
        return abi.encodePacked(a, f1, b, f2, c);
    }

    /// @dev The Pool Party API's side, written independently of the adapter: EIP-712 over `r` (its `signature` is
    ///      ignored), domain bound to `verifyingContract` (one adapter: one fund on one chain).
    function _sign(
        address verifyingContract,
        ISwapAdapter.ApiRoute memory r,
        address tokenIn,
        address tokenOut,
        uint256 key
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "SwapRoute(address tokenIn,address tokenOut,bytes32 legsHash,uint256 quotedAmountIn,uint256 minAmountOut,uint256 deadline)"
                ),
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
                DOMAIN_TYPEHASH, keccak256("Pool Party Swap Adapter"), keccak256("1"), block.chainid, verifyingContract
            )
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(rr, ss, v);
    }

    /// @dev A route for `adapter`, signed by `key`, for `quotedAmountIn` with `minAmountOut`, valid for 5 minutes.
    function _route(
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
        r.signature = _sign(address(adapter), r, tokenIn, tokenOut, key);
        return abi.encode(r);
    }

    /// @dev 60% WETH -0.05%- USDT -0.01%- base and 40% WETH -0.05%- base (the shape of the research fixture).
    function _splitLegs() internal view returns (bytes[] memory paths, uint16[] memory weights) {
        paths = new bytes[](2);
        paths[0] = _path2(address(weth), 500, address(usdt), 100, address(base));
        paths[1] = _path1(address(weth), 500, address(base));
        weights = new uint16[](2);
        (weights[0], weights[1]) = (6000, 4000);
    }

    function _one(bytes memory path) internal pure returns (bytes[] memory paths, uint16[] memory weights) {
        paths = new bytes[](1);
        paths[0] = path;
        weights = new uint16[](1);
        weights[0] = 10_000;
    }
}
