// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";

/// @notice SwapRouter02's V3 entry points (Uniswap swap-router-contracts v1.1.0,
///         `contracts/interfaces/IV3SwapRouter.sol`). Unlike the first SwapRouter, the params carry no deadline.
interface ISwapRouter02Full {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

/// @notice Shared chain configuration of the swap fork tests (DEC-129, DEC-136, DEC-142, DEC-143, DEC-153), ported
///         from the swap adapter research (branch `test/pp-sc-test-swap-adapter-research`).
/// @dev Addresses come from the Uniswap docs (v3 Arbitrum and Robinhood Chain deployments, Trading API supported
///      chains) and the spec's research doc 07; `V3DeploymentsForkTest` checks every one on the fork.
///      Fork block: `ARBITRUM_FORK_BLOCK` / `ROBINHOOD_FORK_BLOCK` (export fresh pins, latest - 300, before a run: the
///      RPCs are not archive nodes and Robinhood serves about 5,000 blocks), else the latest block. No assertion here
///      depends on a block: pools are fixed addresses, and amounts are compared with QuoterV2 in the same state.
abstract contract SwapForkBase is Test {
    uint24[4] internal FEE_TIERS = [uint24(100), 500, 3000, 10_000];

    struct V3Chain {
        string name;
        uint256 chainId;
        IUniswapV3Factory factory;
        ISwapRouter02Full router;
        IQuoterV2 quoter;
        address universalRouter212;
        address weth;
        address base;
    }

    /// @notice One split of a Trading API CLASSIC route as a packed V3 path and the input it carries.
    struct Leg {
        bytes path;
        uint256 amountIn;
    }

    // ---- Arbitrum One (Hub Chain) ----
    address internal constant ARB_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant ARB_SWAP_ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant ARB_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address internal constant ARB_UNIVERSAL_ROUTER_2_1_2 = 0x2d01411773c8C24805306E89A41F7855C3c4Fe65;
    address internal constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address internal constant ARB_POOL_USDC_WETH_100 = 0x6f38e884725a116C9C7fBF208e79FE8828a2595F;
    address internal constant ARB_POOL_USDC_WETH_500 = 0xC6962004f452bE9203591991D15f6b388e09E8D0;
    address internal constant ARB_POOL_USDC_WETH_3000 = 0xc473e2aEE3441BF9240Be85eb122aBB059A3B57c;
    address internal constant ARB_POOL_USDC_WETH_10000 = 0x42FC852A750BA93D5bf772ecdc857e87a86403a9;
    address internal constant ARB_POOL_WETH_USDT_500 = 0x641C00A822e8b671738d32a431a4Fb6074E5c79d;
    address internal constant ARB_POOL_USDC_USDT_100 = 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6;

    // ---- Robinhood Chain (Spoke Chain) ----
    address internal constant RH_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant RH_SWAP_ROUTER02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant RH_QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;
    address internal constant RH_UNIVERSAL_ROUTER_2_1_2 = 0x204FAca1764B154221e35c0d20aBb3c525710498;
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant RH_NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant RH_POOL_WETH_USDG_100 = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address internal constant RH_POOL_WETH_USDG_500 = 0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a;
    address internal constant RH_POOL_WETH_USDG_3000 = 0xa9188730Fe85Be88ad499D7d52B099e800fB0334;
    address internal constant RH_POOL_WETH_USDG_10000 = 0x5f009E071F07e92B6C624e83F52F17bBDa34680D;
    address internal constant RH_POOL_NVDA_USDG_500 = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address internal constant RH_POOL_NVDA_WETH_500 = 0x62AB521f71431f78ac374CdbadC6cda3c8916b6C;
    address internal constant RH_POOL_SPY_USDG_500 = 0xa7Bb1AC63BBaB0C44316E6c8C455213441689167;

    function _arbitrum() internal returns (V3Chain memory c) {
        _fork("ARBITRUM_RPC_URL", "ARBITRUM_FORK_BLOCK");
        c = V3Chain({
            name: "Arbitrum One",
            chainId: 42_161,
            factory: IUniswapV3Factory(ARB_V3_FACTORY),
            router: ISwapRouter02Full(ARB_SWAP_ROUTER02),
            quoter: IQuoterV2(ARB_QUOTER_V2),
            universalRouter212: ARB_UNIVERSAL_ROUTER_2_1_2,
            weth: ARB_WETH,
            base: ARB_USDC
        });
        assertEq(block.chainid, c.chainId, "Arbitrum chain id");
    }

    function _robinhood() internal returns (V3Chain memory c) {
        _fork("ROBINHOOD_RPC_URL", "ROBINHOOD_FORK_BLOCK");
        c = V3Chain({
            name: "Robinhood Chain",
            chainId: 4663,
            factory: IUniswapV3Factory(RH_V3_FACTORY),
            router: ISwapRouter02Full(RH_SWAP_ROUTER02),
            quoter: IQuoterV2(RH_QUOTER_V2),
            universalRouter212: RH_UNIVERSAL_ROUTER_2_1_2,
            weth: RH_WETH,
            base: RH_USDG
        });
        assertEq(block.chainid, c.chainId, "Robinhood chain id");
    }

    /// @dev Forks `rpcEnv` at `blockEnv` when set, else at the latest block. The block is logged from the environment:
    ///      on an Arbitrum fork `block.number` is the L1 block number, not the L2 one.
    function _fork(string memory rpcEnv, string memory blockEnv) internal {
        uint256 blockNumber = vm.envOr(blockEnv, uint256(0));
        if (blockNumber == 0) vm.createSelectFork(vm.envString(rpcEnv));
        else vm.createSelectFork(vm.envString(rpcEnv), blockNumber);
        console2.log("fork block (0 = latest)", blockNumber, "timestamp", block.timestamp);
    }

    /// @dev The token of `pool` that is not `known`.
    function _otherToken(address pool, address known) internal view returns (address) {
        address t0 = IUniswapV3Pool(pool).token0();
        return t0 == known ? IUniswapV3Pool(pool).token1() : t0;
    }

    /// @dev Packed V3 path, the format of SwapRouter02.exactInput, QuoterV2.quoteExactInput and the Universal
    ///      Router's V3_SWAP_EXACT_IN `path`: token (20 bytes) | fee (3 bytes) | token | fee | token ...
    function _path1(address a, uint24 fee, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, fee, b);
    }

    function _path2(address a, uint24 f1, address b, uint24 f2, address c) internal pure returns (bytes memory) {
        return abi.encodePacked(a, f1, b, f2, c);
    }

    // ------------------------------------------------------------------------------------------------------------
    // The Pool Party API's encoder: Trading API CLASSIC quote -> contract parameter (founder chat 1, 2026-10-02)
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Written in Solidity for the tests; the API runs the same in TypeScript. Every split of `quote.route` (a
    ///      quote requested with `protocols: ["V3"]`) becomes one leg. It checks what the contract relies on: only
    ///      `v3-pool` hops, hops chained token to token, and each hop's `address` equal to the factory pool of
    ///      (tokenIn, tokenOut, fee), the pool SwapRouter02 derives from the path (CREATE2 from the factory).
    function _legsFromClassicQuote(V3Chain memory c, string memory json)
        internal
        view
        returns (Leg[] memory legs, address tokenIn, address tokenOut, uint256 amountIn)
    {
        assertEq(vm.parseJsonString(json, ".routing"), "CLASSIC", "CLASSIC routing");
        assertEq(vm.parseJsonUint(json, ".quote.chainId"), c.chainId, "chain");
        tokenIn = vm.parseJsonAddress(json, ".quote.input.token");
        tokenOut = vm.parseJsonAddress(json, ".quote.output.token");
        amountIn = vm.parseUint(vm.parseJsonString(json, ".quote.input.amount"));

        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".quote.route[", vm.toString(n), "]"))) ++n;
        legs = new Leg[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            legs[i] = _leg(c, json, string.concat(".quote.route[", vm.toString(i), "]"), tokenIn, tokenOut);
            total += legs[i].amountIn;
        }
        assertEq(total, amountIn, "splits add up to the input");
    }

    /// @dev Legs -> the ApiRoute's `paths` and `weightsBps` (share of the quoted input; the last takes the remainder).
    function _pathsAndWeights(Leg[] memory legs, uint256 amountIn)
        internal
        pure
        returns (bytes[] memory paths, uint16[] memory weights)
    {
        uint256 n = legs.length;
        paths = new bytes[](n);
        weights = new uint16[](n);
        uint256 left = 10_000;
        for (uint256 i; i < n; ++i) {
            paths[i] = legs[i].path;
            // casting to 'uint16' is safe because a split's input never exceeds the quote's input (at most 10,000)
            // forge-lint: disable-next-line(unsafe-typecast)
            weights[i] = i + 1 == n ? uint16(left) : uint16(legs[i].amountIn * 10_000 / amountIn);
            left -= weights[i];
        }
    }

    /// @dev One split of `quote.route` -> one leg.
    function _leg(V3Chain memory c, string memory json, string memory split, address tokenIn, address tokenOut)
        internal
        view
        returns (Leg memory leg)
    {
        address prev = tokenIn;
        leg.path = abi.encodePacked(tokenIn);
        uint256 h;
        while (vm.keyExistsJson(json, string.concat(split, "[", vm.toString(h), "]"))) {
            string memory hop = string.concat(split, "[", vm.toString(h), "]");
            (address hOut, uint24 fee) = _hop(c, json, hop, prev);
            if (h == 0) leg.amountIn = vm.parseUint(vm.parseJsonString(json, string.concat(hop, ".amountIn")));
            leg.path = abi.encodePacked(leg.path, fee, hOut);
            prev = hOut;
            ++h;
        }
        assertEq(prev, tokenOut, "split ends in tokenOut");
    }

    /// @dev One `V3PoolInRoute` hop: V3 only, chained from `prev`, and its `address` is the factory pool. The quote's
    ///      `fee` is in hundredths of a bip (500 = 0.05%), the `uint24` the path takes.
    function _hop(V3Chain memory c, string memory json, string memory hop, address prev)
        internal
        view
        returns (address hOut, uint24 fee)
    {
        assertEq(vm.parseJsonString(json, string.concat(hop, ".type")), "v3-pool", "V3 hops only");
        assertEq(vm.parseJsonAddress(json, string.concat(hop, ".tokenIn.address")), prev, "hops chain token to token");
        hOut = vm.parseJsonAddress(json, string.concat(hop, ".tokenOut.address"));
        // casting to 'uint24' is safe because V3 fees are at most 1,000,000 (a fixture outside that fails the pool check)
        // forge-lint: disable-next-line(unsafe-typecast)
        fee = uint24(vm.parseUint(vm.parseJsonString(json, string.concat(hop, ".fee"))));
        assertEq(
            c.factory.getPool(prev, hOut, fee),
            vm.parseJsonAddress(json, string.concat(hop, ".address")),
            "hop pool is the factory pool"
        );
    }
}
