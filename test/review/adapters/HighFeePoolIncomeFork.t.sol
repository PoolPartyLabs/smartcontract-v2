// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {ManagerFeeVault} from "../../../src/core/ManagerFeeVault.sol";
import {AdaptersForkBase, IPermit2Of} from "./AdaptersForkBase.sol";

/// @notice (adapters review) One-shot variant of the wash-trade channel: the Mandate lists a hookless WETH/USDC pool
///         with a 100% static LP fee. The fund is its only LP. One manager swap with `minAmountOut = 0` paid the whole
///         input to the fund's own position as fees, which the adapter reported as income (DEC-079), and the Core Vault
///         charged the performance fee on it (DEC-107). e5c778a: 100,000 USDC in one call, the manager withdrew
///         12,500 and the protocol took 12,500.
/// @notice Ported to fix/pp-sc-fix-independent-review (review M-02): the adapter refuses a hookless pool above a 1% LP
///         fee (`PoolFeeTooHigh`, `MAX_POOL_FEE` = 10,000), so the one-shot pool cannot be listed.
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 300>
///      forge test -j 1 --match-path 'test/review/adapters/HighFeePoolIncomeFork.t.sol' -vv
contract HighFeePoolIncomeFork is AdaptersForkBase {
    function _secondFee() internal pure override returns (uint24) {
        return 1_000_000;
    }

    /// @dev Only the fork and the 100% pool: the fund cannot be deployed with it.
    function setUp() public override {
        _forkAndInitializeSecondPool();
    }

    function _keysWith(PoolKey memory second) internal view returns (PoolKey[] memory keys) {
        keys = new PoolKey[](2);
        keys[0] = liveKey;
        keys[1] = second;
    }

    /// @dev The `permit2` address is read before the caller arms `expectRevert`, so the revert expected is the
    ///      constructor's.
    function _newAdapter(PoolKey[] memory keys, address permit2) internal returns (UniswapV4Adapter) {
        return new UniswapV4Adapter(
            makeAddr("vault"),
            makeAddr("guardian"),
            IPoolManager(PM),
            IPositionManager(POSM),
            IStateView(SV),
            IAllowanceTransfer(permit2),
            keys
        );
    }

    function test_REVIEW_M02_fullFeeMandatePoolIsRefusedByTheAdapter() public {
        address permit2 = IPermit2Of(POSM).permit2();
        PoolKey[] memory keys = _keysWith(secondKey);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4Adapter.PoolFeeTooHigh.selector, secondPool, uint24(1_000_000)));
        _newAdapter(keys, permit2);

        // The bound is exact: one pip above 1% is refused, 1% itself is accepted (re-attack at the boundary).
        PoolKey memory above = PoolKey(Currency.wrap(WETH), Currency.wrap(USDC), 10_001, 60, IHooks(address(0)));
        keys = _keysWith(above);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4Adapter.PoolFeeTooHigh.selector, PoolId.unwrap(above.toId()), uint24(10_001)
            )
        );
        _newAdapter(keys, permit2);
        PoolKey memory atCap = PoolKey(Currency.wrap(WETH), Currency.wrap(USDC), 10_000, 60, IHooks(address(0)));
        _newAdapter(_keysWith(atCap), permit2);
    }
}

/// @notice What M-02 allowed at the cap: the same channel through a 1% Mandate pool in which the fund is the only LP.
///         Each round trip of the manager's own Unallocated Balance through the fund's own range turned 2% of the leg
///         into "income" with no loss to anyone but the holders, and nothing bounded the number of round trips.
/// @notice FIXED by DEC-136 (founder, 2026-10-02: "swaps are not done in the fund pools"): the manager's swaps run
///         through the Mandate swap adapter (the real `UniswapV3SwapAdapter` on Arbitrum One), which never trades in a
///         fund's V4 pool. The round trips leave the 1% pool and the fund's position in it untouched: no income, no fee.
///         Performance fee 25% (the Mandate cap), protocol slice 50%, as in the original one-shot test.
contract OnePercentPoolWashFork is AdaptersForkBase {
    uint256 internal constant ROUND_TRIPS = 3;
    uint256 internal constant LEG = 20_000e6;

    function _secondFee() internal pure override returns (uint24) {
        return 10_000;
    }

    function test_REVIEW_M02_DEC136_onePercentPoolWashNoLongerReachesTheFundsPool() public {
        // 1. Alice deposits 1,000,000 USDC; the manager allocates 400,000 to the hub Spoke Vault.
        _depositAs(alice, 1_000_000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(400_000e6);

        // 2. The manager buys WETH through the swap adapter and opens a +-10% position of about 100,000 in the 1% pool,
        //    where the fund is the only LP.
        vm.prank(manager);
        uint256 weth = hubVault.swap(address(hubSwap), USDC, WETH, 50_000e6, 0, "");
        int24 lo = _floor(tick0, 60) - 960;
        bytes memory params = abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: lo,
                tickUpper: lo + 1920,
                liquidity: 0,
                amount0Max: uint128(weth),
                amount1Max: uint128(50_000e6),
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.prank(manager);
        (bytes32 pk,,) = hubVault.openPosition(address(adapter), secondPool, weth, 50_000e6, params);

        address mfv = vault.managerFeeVault();
        (, int24 tickBefore,,) = IStateView(SV).getSlot0(PoolId.wrap(secondPool));
        uint256 protocolBefore =
            _usd(IERC20(WETH).balanceOf(protocolRecipient), IERC20(USDC).balanceOf(protocolRecipient));

        // 3. Round trips of 20,000 USDC with no maximum loss: they run in Uniswap V3, not in the fund's 1% pool.
        for (uint256 i; i < ROUND_TRIPS; ++i) {
            vm.prank(manager);
            uint256 wethOut = hubVault.swap(address(hubSwap), USDC, WETH, LEG, 0, "");
            vm.prank(manager);
            hubVault.swap(address(hubSwap), WETH, USDC, wethOut, 0, "");
        }

        // 4. Collect: the position earned nothing from them, and nothing is split.
        vm.prank(manager);
        IAdapter.Amounts memory inc = hubVault.collectIncome(address(adapter), pk);
        (, int24 tickAfter,,) = IStateView(SV).getSlot0(PoolId.wrap(secondPool));
        console2.log("income reported by the adapter, WETH / USDC", inc.income0, inc.income1);
        assertEq(tickAfter, tickBefore, "DEC-136: the fund's 1% pool never traded");
        assertEq(inc.income0, 0);
        assertEq(inc.income1, 0);
        assertEq(_usd(IERC20(WETH).balanceOf(mfv), IERC20(USDC).balanceOf(mfv)), 0, "nothing for the manager");
        assertEq(
            _usd(IERC20(WETH).balanceOf(protocolRecipient), IERC20(USDC).balanceOf(protocolRecipient)),
            protocolBefore,
            "nothing for the protocol"
        );
    }
}
