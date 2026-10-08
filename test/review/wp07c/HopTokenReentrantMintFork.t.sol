// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ISwapAdapter} from "../../../src/interfaces/ISwapAdapter.sol";
import {UniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {EndToEndScenario} from "../../fork/e2e/EndToEnd.t.sol";

interface IHopHook {
    function onHop() external;
}

/// @notice A token outside the Mandate that calls out on its first transfer: SwapRouter02 moves it between the hops of
///         an API route (DEC-173), while the hub Spoke Vault's swap is in progress.
contract HookToken is ERC20 {
    address public hook;
    bool public fired;

    constructor() ERC20("Hook", "HOOK") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(address hook_) external {
        hook = hook_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hook != address(0) && !fired && from != address(0)) {
            fired = true;
            IHopHook(hook).onHop();
        }
    }
}

/// @notice Full-range liquidity for the HOOK pools.
contract LiquidityHelper {
    function mint(IUniswapV3Pool pool, int24 lower, int24 upper, uint128 liquidity) external {
        pool.mint(address(this), lower, upper, liquidity, "");
    }

    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata) external {
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        if (owed0 != 0) IERC20(pool.token0()).transfer(msg.sender, owed0);
        if (owed1 != 0) IERC20(pool.token1()).transfer(msg.sender, owed1);
    }
}

/// @notice Deposits its USDC into the Core Vault from the hop token's hook; `catchRevert` keeps the route alive.
contract MidSwapDepositor is IHopHook {
    ICoreVault public immutable core;
    IERC20 public immutable usdc;
    bool public catchRevert;
    bytes public revertData;
    uint256 public shares;

    constructor(ICoreVault core_, IERC20 usdc_) {
        core = core_;
        usdc = usdc_;
    }

    function setCatchRevert(bool catchRevert_) external {
        catchRevert = catchRevert_;
    }

    function onHop() external {
        uint256 amount = usdc.balanceOf(address(this));
        usdc.approve(address(core), amount);
        if (!catchRevert) {
            (shares,) = core.deposit(amount, 0);
            return;
        }
        try core.deposit(amount, 0) returns (uint256 minted, uint256) {
            shares = minted;
        } catch (bytes memory reason) {
            revertData = reason;
        }
    }
}

/// @title Regression (PR #13 review, M-1), Arbitrum fork: a hop token outside the Mandate cannot mint shares at the
///        mid-swap Share Price
/// @notice Was the reviewer's PoC on the real FundFactory fund of the end-to-end scenario: the manager allocates 8,000
///         USDC to the hub Spoke Vault and swaps it to WETH on an API-signed route USDC -> HOOK -> WETH (DEC-173),
///         HOOK's pools priced at the price source. HOOK's transfer hook deposits 5,000 USDC into the Core Vault while
///         the hub ledger shows the 8,000 gone and no WETH yet: Share Price 1.00 seen as 0.21, 24,225 shares minted
///         against 4,987.5 fair, about 5,550 USDC taken from the other holders.
/// @dev Fix: `SpokeVault.buildReport()` reverts while a guarded entry of the vault runs, so the Core Vault's mint
///      valuation reverts. Uncaught, the hook's revert fails the route; caught, the swap completes and nothing is
///      minted.
/// @dev Run: . <rpc env>; forge test --match-path test/review/wp07c/HopTokenReentrantMintFork.t.sol -vv
contract HopTokenReentrantMintFork is EndToEndScenario {
    uint256 internal constant HUB_USDC = 8000e6;
    uint256 internal constant ATTACK_USDC = 5000e6;

    HookToken internal hook;
    MidSwapDepositor internal attacker;
    bytes internal route;

    function setUp() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _onArbitrum();
        vm.prank(manager);
        core.allocateToHubSpokeVault(HUB_USDC);

        hook = new HookToken();
        LiquidityHelper lp = new LiquidityHelper();
        IUniswapV3Factory f = IUniswapV3Factory(ARB_V3_FACTORY);
        IUniswapV3Pool p1 = IUniswapV3Pool(f.createPool(ARB_USDC, address(hook), 3000));
        p1.initialize(uint160(1 << 96));
        IUniswapV3Pool p2 = IUniswapV3Pool(f.createPool(address(hook), ARB_WETH, 3000));
        uint256 usdcPerWeth = _usdcValue(ARB_WETH, 1e18);
        uint256 sqrtP = address(hook) < ARB_WETH
            ? Math.sqrt(Math.mulDiv(1e18, uint256(1) << 192, usdcPerWeth))
            : Math.sqrt(Math.mulDiv(usdcPerWeth, uint256(1) << 192, 1e18));
        p2.initialize(uint160(sqrtP));
        hook.mint(address(lp), 1e15);
        deal(ARB_USDC, address(lp), 1e13);
        deal(ARB_WETH, address(lp), 1e22);
        lp.mint(p1, -887_220, 887_220, 1e12);
        lp.mint(p2, -887_220, 887_220, 1e17);

        bytes[] memory paths = new bytes[](1);
        paths[0] = abi.encodePacked(ARB_USDC, uint24(3000), address(hook), uint24(3000), ARB_WETH);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        route = _signed(hubSwapAdapter, paths, weights, ARB_USDC, ARB_WETH, HUB_USDC);

        attacker = new MidSwapDepositor(core, IERC20(ARB_USDC));
        deal(ARB_USDC, address(attacker), ATTACK_USDC);
        hook.setHook(address(attacker));
    }

    /// @dev The attack as reported: the deposit reverts inside the hop's transfer, so the route reverts.
    function test_REVIEW_PR13_M1_aHopTokenDepositRevertsTheSwap() public {
        uint256 priceBefore = core.sharePrice();
        uint256 supplyBefore = IERC20(core.shareToken()).totalSupply();
        vm.prank(manager);
        // The V3 pool's transfer of the hop token fails (`TransferHelper.safeTransfer`).
        vm.expectRevert(bytes("TF"));
        hubSpoke.swap(hubSwapAdapter, ARB_USDC, ARB_WETH, HUB_USDC, 0, route);
        assertEq(attacker.shares(), 0);
        assertEq(IERC20(core.shareToken()).totalSupply(), supplyBefore, "nothing minted");
        assertEq(core.sharePrice(), priceBefore);
        assertEq(hubSpoke.unallocatedBalance(ARB_USDC), HUB_USDC, "the swap never happened");
    }

    /// @dev A hook that catches its own revert lets the route complete, and still mints nothing.
    function test_REVIEW_PR13_M1_aHopTokenThatCatchesTheRevertMintsNothing() public {
        attacker.setCatchRevert(true);
        uint256 priceBefore = core.sharePrice();
        uint256 supplyBefore = IERC20(core.shareToken()).totalSupply();
        vm.prank(manager);
        uint256 wethOut = hubSpoke.swap(hubSwapAdapter, ARB_USDC, ARB_WETH, HUB_USDC, 0, route);

        assertTrue(hook.fired(), "the hop token called out mid-swap");
        assertEq(attacker.revertData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(attacker.shares(), 0);
        assertEq(IERC20(core.shareToken()).totalSupply(), supplyBefore, "nothing minted");
        assertEq(IERC20(ARB_USDC).balanceOf(address(attacker)), ATTACK_USDC, "the deposit never left the hook");
        assertGt(wethOut, 0);
        assertEq(hubSpoke.unallocatedBalance(ARB_WETH), wethOut);
        // Only the route's fees and price impact (two 0.3% hops) move the Share Price.
        assertGt(core.sharePrice(), priceBefore * 97 / 100);
    }

    /// @dev The Pool Party API's side: EIP-712 over one route for the fund's swap adapter, valid for 5 minutes.
    function _signed(
        address adapter,
        bytes[] memory paths,
        uint16[] memory weights,
        address tokenIn,
        address tokenOut,
        uint256 quotedAmountIn
    ) internal returns (bytes memory) {
        (, uint256 key) = makeAddrAndKey("registryOwner");
        ISwapAdapter.ApiRoute memory r =
            ISwapAdapter.ApiRoute(paths, weights, quotedAmountIn, 0, block.timestamp + 300, "");
        bytes32 structHash = keccak256(
            abi.encode(
                UniswapV3SwapAdapter(adapter).ROUTE_TYPEHASH(),
                tokenIn,
                tokenOut,
                keccak256(abi.encode(paths, weights)),
                quotedAmountIn,
                uint256(0),
                r.deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Pool Party Swap Adapter"),
                keccak256("1"),
                block.chainid,
                adapter
            )
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        r.signature = abi.encodePacked(rr, ss, v);
        return abi.encode(r);
    }
}
