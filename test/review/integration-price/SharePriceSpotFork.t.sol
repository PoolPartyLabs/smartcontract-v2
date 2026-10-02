// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {IntegrationPriceBase, PoolActor} from "./IntegrationPriceBase.sol";

/// @notice Part 1.2 (hub) of the integration-price review: report 02 C-01 (Share Price at the spot composition of the
///         hub V4 position) reproduced with real swaps in the scripts' pool on a factory-created fund, with the real
///         ChainlinkPriceSource. The claimant wraps its own Idle-paid claim between a swap and the swap back inside ONE
///         PoolManager unlock (flash accounting): the only cost is the LP fee of the round trip.
/// @notice Ported to fix/pp-sc-fix-independent-review (review C-02, security sweep S-1): Share Assets recompute every
///         range position from its liquidity and ticks at the price-source price (`CoreVaultLogic._oracleComposition`),
///         so a push in either direction, at any depth, leaves the Share Price where it was; the claim, the deposit
///         sandwich and the round trip are now pure cost to the attacker.
/// @dev Fund: Alice 250,000 USDC, the attacker 50,000 (earlier), Free Idle kept at 100,000 so a 40,000 Instant claim is
///      paid from Idle; one V4 position worth 100,000 USDC; the rest in Aave.
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 300>
///      forge test -j 1 --match-path 'test/review/integration-price/SharePriceSpotFork.t.sol' -vv
contract SharePriceSpotFork is IntegrationPriceBase {
    uint256 internal constant ALICE_DEPOSIT = 250_000e6;
    uint256 internal constant STAKE = 50_000e6;
    uint256 internal constant FREE_IDLE = 100_000e6;
    uint256 internal constant V4_VALUE = 100_000e6;
    uint256 internal constant CLAIM = 40_000e6;

    PoolActor internal attacker;

    function _setUpFund(uint256 downPpm, uint256 upPpm) internal {
        _arbitrumOnly();
        _createFund(_pricePlan(SPOKE_CAP), new PoolKey[](0), false);
        _deposit(alice, ALICE_DEPOSIT);
        attacker = new PoolActor(IPoolManager(ARB_V4_POOL_MANAGER));
        deal(ARB_USDC, address(attacker), STAKE);
        attacker.deposit(core, ARB_USDC, STAKE);
        _allocate(core.freeIdle() - FREE_IDLE);
        _openAround(hubKey, downPpm, upPpm, V4_VALUE);
        _parkRestInAave();
        // Fees for the round trip (the flash accounting needs no other capital).
        deal(ARB_USDC, address(attacker), 5000e6);
        deal(ARB_WETH, address(attacker), 2e18);
    }

    /// @notice Share Assets and the hub V4 principal while the pool sits at `pushTo` (real swap, then reverted).
    function _readAt(uint160 pushTo)
        internal
        returns (uint256 assets, uint256 v4AsVaultReads, uint256 v4AtOracle, int256 deviationPpm)
    {
        uint256 snap = vm.snapshotState();
        PoolActor mover = new PoolActor(IPoolManager(ARB_V4_POOL_MANAGER));
        deal(ARB_WETH, address(mover), 1000e18);
        deal(ARB_USDC, address(mover), 10_000_000e6);
        (uint160 start,,,) = IStateView(ARB_V4_STATE_VIEW).getSlot0(hubKey.toId());
        if (pushTo != start) mover.swapTo(hubKey, pushTo < start, pushTo);
        assets = core.shareAssets();
        v4AsVaultReads = _hubV4PrincipalAsVaultReads();
        v4AtOracle = _hubV4PrincipalAtOracle();
        uint256 spot1e18 = Math.mulDiv(Math.mulDiv(pushTo, pushTo, 1 << 96), 1e18, 1 << 96);
        deviationPpm = int256(Math.mulDiv(spot1e18, 1e6, _oracle())) - 1e6;
        vm.revertToState(snap);
    }

    struct Outcome {
        uint256 baseShares;
        uint256 baseGross;
        uint256 baseWealth;
        uint256 atkShares;
        uint256 atkGross;
        uint256 atkWealth;
        uint256 aliceBase;
        uint256 aliceAtk;
    }

    /// @notice The claim without and with the push (flash accounting), from the same state.
    function _claimBothWays(uint160 pushTo) internal returns (Outcome memory o) {
        attacker.requestPayout(core, CLAIM, ICoreVaultPayouts.PayoutMode.Instant);
        uint256 snap = vm.snapshotState();
        ICoreVault.PayoutReceipt memory r = attacker.claim(core, "");
        (o.baseShares, o.baseGross, o.baseWealth, o.aliceBase) =
        (r.sharesBurned, r.usdcGross, _wealth(address(attacker)), _holderValue(alice));
        vm.revertToState(snap);
        bytes memory ret =
            attacker.around(hubKey, true, pushTo, address(core), abi.encodeCall(ICoreVaultPayouts.claimPayout, ("")));
        r = abi.decode(ret, (ICoreVaultPayouts.PayoutReceipt));
        (o.atkShares, o.atkGross, o.atkWealth, o.aliceAtk) =
        (r.sharesBurned, r.usdcGross, _wealth(address(attacker)), _holderValue(alice));
        assertEq(r.unwindProceeds, 0, "Idle paid, no unwind");
    }

    function _run(uint256 downPpm, uint256 upPpm, string memory title) internal {
        _setUpFund(downPpm, upPpm);
        uint160 edge = TickMath.getSqrtPriceAtTick(lastLower - hubKey.tickSpacing);
        (uint256 assets0,,,) = _readAt(hubSqrtP0Now());
        (uint256 assetsPushed, uint256 v4Spot, uint256 v4Oracle, int256 dev) = _readAt(edge);
        Outcome memory o = _claimBothWays(edge);
        console2.log("=====", title);
        console2.log("Share Assets at rest / pushed under the range", assets0, assetsPushed);
        console2.log("V4 principal as the vault reads it pushed / at the oracle composition", v4Spot, v4Oracle);
        console2.log("slot0 deviation from the oracle when pushed (ppm)");
        console2.logInt(dev);
        console2.log("Share Price inflation (ppm)", Math.mulDiv(assetsPushed, 1e6, assets0) - 1e6);
        console2.log("shares burned without / with the push", o.baseShares / 1e18, o.atkShares / 1e18);
        console2.log("USDC gross without / with", o.baseGross, o.atkGross);
        console2.log("attacker wealth without / with the push");
        console2.log(o.baseWealth, o.atkWealth);
        console2.log("attacker net gain (after the round-trip fee)");
        console2.logInt(int256(o.atkWealth) - int256(o.baseWealth));
        console2.log("Alice value without / with", o.aliceBase, o.aliceAtk);
        // e5c778a: the push burned 182 / 379 / 3,131 fewer shares and netted +48.87 / +213.52 / +2,764.56 (+-5/10/50%).
        assertEq(assetsPushed, assets0, "Share Assets unmoved by the push");
        assertGt(v4Spot, v4Oracle, "the adapter's spot read still moves, the Core Vault no longer uses it");
        assertEq(o.atkShares, o.baseShares, "the same shares burned for the same claim");
        assertEq(o.atkGross, o.baseGross, "the same USDC paid");
        assertLt(o.atkWealth, o.baseWealth, "the round trip is pure cost");
        assertEq(o.aliceAtk, o.aliceBase, "Alice pays nothing");
    }

    function hubSqrtP0Now() internal view returns (uint160 s) {
        (s,,,) = IStateView(ARB_V4_STATE_VIEW).getSlot0(hubKey.toId());
    }

    function test_REVIEW_C02_idlePaidClaim_plusMinus5() public {
        _run(50_000, 50_000, "Idle-paid claim of 40,000, V4 +-5% worth 100,000");
    }

    function test_REVIEW_C02_idlePaidClaim_plusMinus10() public {
        _run(100_000, 100_000, "Idle-paid claim of 40,000, V4 +-10% worth 100,000");
    }

    function test_REVIEW_C02_idlePaidClaim_plusMinus50() public {
        _run(500_000, 500_000, "Idle-paid claim of 40,000, V4 +-50% worth 100,000");
    }

    /// @notice Pushes down and up, from 1% to 50%: Share Assets never move (e5c778a: +0.456% to +8.487%).
    function test_REVIEW_C02_noInflationAtAnyPushDepth_plusMinus10() public {
        _setUpFund(100_000, 100_000);
        uint160 start = hubSqrtP0Now();
        (uint256 assets0,, uint256 v4Oracle0,) = _readAt(start);
        uint256[7] memory fractionsPpm = [uint256(990_000), 980_000, 950_000, 900_000, 500_000, 1_020_000, 1_100_000];
        console2.log("===== inflation by push, V4 +-10% worth 100,000 in a fund of", assets0);
        for (uint256 i; i < fractionsPpm.length; ++i) {
            uint160 pushTo = SafeCast.toUint160(Math.mulDiv(start, Math.sqrt(fractionsPpm[i] * 1e12), 1e9));
            (uint256 a, uint256 v4Spot, uint256 v4Oracle, int256 dev) = _readAt(pushTo);
            console2.log("price x (ppm)", fractionsPpm[i]);
            console2.log("  slot0 vs oracle (ppm)");
            console2.logInt(dev);
            console2.log("  V4 principal as read (spot composition)", v4Spot);
            console2.log("  V4 principal at oracle composition (option a)", v4Oracle);
            console2.log("  Share Price inflation (ppm)", Math.mulDiv(a, 1e6, assets0) - 1e6);
            assertEq(v4Oracle, v4Oracle0, "option (a): unmoved by the push");
            assertEq(a, assets0, "Share Assets unmoved by the push");
        }
    }

    /// @notice A depositor sandwiched by a push that holds for the deposit (the attacker needs the capital here).
    ///         e5c778a: a 100,000 deposit lost 710.07.
    function test_REVIEW_C02_depositSandwich_plusMinus10() public {
        _setUpFund(100_000, 100_000);
        address carol = makeAddr("carol");
        uint160 edge = TickMath.getSqrtPriceAtTick(lastLower - hubKey.tickSpacing);
        deal(ARB_WETH, address(attacker), 200e18);
        uint256 snap = vm.snapshotState();
        uint256 sharesFair = _deposit(carol, 100_000e6);
        uint256 fair = _holderValue(carol);
        vm.revertToState(snap);

        PoolActor.Leg[] memory legs = _one(_pushLeg(hubKey, ARB_V4_STATE_VIEW, edge));
        uint256 attackerBefore = _wealth(address(attacker));
        uint256 aliceBefore = _holderValue(alice);
        attacker.push(legs);
        uint256 sharesPushed = _deposit(carol, 100_000e6);
        attacker.restore(legs);
        uint256 got = _holderValue(carol);
        console2.log("===== deposit of 100,000 sandwiched by a push under a +-10% range");
        console2.log("shares minted fair / sandwiched", sharesFair / 1e18, sharesPushed / 1e18);
        console2.log("Carol value fair / sandwiched", fair, got);
        console2.log("Carol value change vs a fair deposit");
        console2.logInt(int256(got) - int256(fair));
        console2.log("attacker wealth change (holder of 50,000, pays the round trip)");
        int256 attackerChange = int256(_wealth(address(attacker))) - int256(attackerBefore);
        console2.logInt(attackerChange);
        console2.log("Alice value change");
        console2.logInt(int256(_holderValue(alice)) - int256(aliceBefore));
        assertEq(sharesPushed, sharesFair, "the same shares minted");
        assertEq(got, fair, "the sandwiched depositor pays the fair price");
        assertLt(attackerChange, 0, "the round trip is pure cost");
    }
}
