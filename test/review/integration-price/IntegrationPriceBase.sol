// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {Mandate, MandateLib, PoolConfig, UnwindStep} from "../../../src/mandate/Mandate.sol";
import {EndToEndBase} from "../../fork/e2e/EndToEndBase.sol";
import {V4SwapRouter} from "../../mocks/v4/V4SwapRouter.sol";

/// @notice A contract actor on the real PoolManager: a shareholder of the fund (it deposits, requests and claims as
///         itself) and a trader that swaps to a price limit, adds and removes liquidity, and can wrap a call between a
///         swap and the swap back inside ONE `unlock` (V4 flash accounting: only the net of the two swaps is settled).
/// @dev Every token it spends was dealt to it by the test, which checks at the end what it got back (the dealt WETH
///      stands for a flash loan).
contract PoolActor is IUnlockCallback {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable pm;

    uint8 private constant OP_SWAP = 0;
    uint8 private constant OP_MODIFY = 1;
    uint8 private constant OP_AROUND = 2;

    /// @notice One pool the attack moves: pushed to `pushTo` (down when `down`), optional USDC-only liquidity
    ///         [jitLo, jitHi] left under the pushed price, then taken back and the pool restored to `restoreTo`.
    struct Leg {
        PoolKey key;
        bool down;
        uint160 pushTo;
        int24 jitLo;
        int24 jitHi;
        uint128 jitLiq;
        uint160 restoreTo;
    }

    /// @notice Pool price seen at the moment of the wrapped call or claim (for the fix-option checks).
    uint160 public sqrtAtCall;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    // ------------------------------------------------------------------ shareholder verbs (this contract is the holder)

    function deposit(ICoreVault core, address usdc, uint256 amount) external returns (uint256 shares) {
        IERC20(usdc).approve(address(core), amount);
        (shares,) = core.deposit(amount, 0);
    }

    function requestPayout(ICoreVault core, uint256 amount, ICoreVault.PayoutMode mode) external {
        core.requestPayout(amount, mode);
    }

    function claim(ICoreVault core, bytes calldata hints) external returns (ICoreVault.PayoutReceipt memory) {
        return core.claimPayout(hints);
    }

    // ------------------------------------------------------------------ pool verbs, each in its own unlock

    function swapTo(PoolKey memory key, bool zeroForOne, uint160 limit) public {
        pm.unlock(abi.encode(OP_SWAP, abi.encode(key, zeroForOne, limit)));
    }

    function modify(PoolKey memory key, int24 lo, int24 hi, int256 liquidity) public {
        pm.unlock(abi.encode(OP_MODIFY, abi.encode(key, lo, hi, liquidity)));
    }

    /// @notice The claimant's attack in one call: push every leg, claim its own Payout Request, restore every leg.
    function attack(Leg[] memory legs, ICoreVault core, bytes memory hints)
        external
        returns (ICoreVault.PayoutReceipt memory receipt)
    {
        push(legs);
        (sqrtAtCall,,,) = pm.getSlot0(legs[0].key.toId());
        receipt = core.claimPayout(hints);
        restore(legs);
    }

    /// @notice First half of a sandwich around someone else's transaction.
    function push(Leg[] memory legs) public {
        for (uint256 i; i < legs.length; ++i) {
            swapTo(legs[i].key, legs[i].down, legs[i].pushTo);
            if (legs[i].jitLiq != 0) {
                modify(legs[i].key, legs[i].jitLo, legs[i].jitHi, int256(uint256(legs[i].jitLiq)));
            }
        }
    }

    /// @notice Second half: take the liquidity back and restore every pool to its start price.
    function restore(Leg[] memory legs) public {
        for (uint256 i; i < legs.length; ++i) {
            if (legs[i].jitLiq != 0) {
                modify(legs[i].key, legs[i].jitLo, legs[i].jitHi, -int256(uint256(legs[i].jitLiq)));
            }
            swapTo(legs[i].key, !legs[i].down, legs[i].restoreTo);
        }
    }

    /// @notice Inside ONE unlock: swap to `pushTo`, call `target` with `data`, swap back to the exact start price, and
    ///         settle only the net of the two swaps (V4 flash accounting: no capital beyond the fees).
    function around(PoolKey memory key, bool zeroForOne, uint160 pushTo, address target, bytes memory data)
        external
        returns (bytes memory ret)
    {
        ret = pm.unlock(abi.encode(OP_AROUND, abi.encode(key, zeroForOne, pushTo, target, data)));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (uint8 op, bytes memory p) = abi.decode(raw, (uint8, bytes));
        if (op == OP_SWAP) {
            (PoolKey memory key, bool zeroForOne, uint160 limit) = abi.decode(p, (PoolKey, bool, uint160));
            BalanceDelta d = _swap(key, zeroForOne, limit);
            _resolve(key.currency0, d.amount0());
            _resolve(key.currency1, d.amount1());
            return "";
        }
        if (op == OP_MODIFY) {
            (PoolKey memory key, int24 lo, int24 hi, int256 liquidity) = abi.decode(p, (PoolKey, int24, int24, int256));
            (BalanceDelta d,) = pm.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(lo, hi, liquidity, 0), "");
            _resolve(key.currency0, d.amount0());
            _resolve(key.currency1, d.amount1());
            return "";
        }
        return _around(p);
    }

    function _around(bytes memory p) private returns (bytes memory ret) {
        (PoolKey memory key, bool zeroForOne, uint160 pushTo, address target, bytes memory data) =
            abi.decode(p, (PoolKey, bool, uint160, address, bytes));
        (uint160 start,,,) = pm.getSlot0(key.toId());
        BalanceDelta a = _swap(key, zeroForOne, pushTo);
        (sqrtAtCall,,,) = pm.getSlot0(key.toId());
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        BalanceDelta b = _swap(key, !zeroForOne, start);
        _resolve(key.currency0, int128(a.amount0()) + int128(b.amount0()));
        _resolve(key.currency1, int128(a.amount1()) + int128(b.amount1()));
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint160 limit) private returns (BalanceDelta) {
        return pm.swap(key, IPoolManager.SwapParams(zeroForOne, -int256(uint256(type(uint128).max)), limit), "");
    }

    function _resolve(Currency currency, int128 amount) private {
        if (amount < 0) {
            pm.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(pm), uint256(uint128(-amount)));
            pm.settle();
        } else if (amount > 0) {
            pm.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/// @notice Shared base of the integration-price review: a fund created by the real FundFactory with the Mandate the
///         project's scripts build (script/FundMandate.sol: hub Uniswap V4 WETH/USDC 0.05% then Aave V3 USDC in the
///         unwind order, Robinhood WETH/USDG 0.05% spoke), the real ChainlinkPriceSource on the live ETH / USD feed, the
///         real Aave V3 Pool, PoolManager, PositionManager, StateView and Permit2 (test/fork/e2e/EndToEndBase.sol).
/// @dev Fund positions are built the way a manager would in a thin pool: WETH is bought through the Mandate pool in
///      chunks, and after each chunk an arbitrageur (the e2e `trader`) swaps the pool back to its start price, so the
///      pool ends where the market put it and the fund's composition is the one that price implies.
abstract contract IntegrationPriceBase is EndToEndBase {
    using StateLibrary for IPoolManager;

    address internal alice = makeAddr("alice");

    PoolKey internal hubKey;
    bytes32 internal hubPoolId;
    uint160 internal hubSqrtP0;
    int24 internal hubTick0;

    /// @dev Tick range of the last position opened by `_openAround`.
    int24 internal lastLower;
    int24 internal lastUpper;

    // ------------------------------------------------------------------ forks and fund creation

    /// @dev Hub-only runs select only the Arbitrum fork (the Mandate still lists the Robinhood spoke, as the scripts
    ///      build it; with no accepted report the spoke adds nothing to Share Assets).
    function _arbitrumOnly() internal {
        arbitrumFork = vm.createFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        vm.selectFork(arbitrumFork);
        clock = block.timestamp;
    }

    /// @notice The scripts' plan (script/CreateFund.s.sol defaults, as the e2e scenario uses them) with a Spoke Cap.
    function _pricePlan(uint256 spokeCap) internal view returns (FundPlan memory plan) {
        plan.manager = manager;
        plan.hubChainId = ARBITRUM;
        plan.usdc = ARB_USDC;
        plan.hubPool = _hubPoolKey();
        plan.hubAaveAsset = ARB_USDC;
        plan.spokeChainId = ROBINHOOD;
        plan.spokeWormholeChainId = WORMHOLE_ROBINHOOD;
        plan.spokeToken = RH_USDG;
        plan.spokePool = _spokePoolKey();
        plan.spokeCap = spokeCap;
        plan.maxReportAge = ROBINHOOD_MAX_REPORT_AGE;
        plan.spokeOperatingCashFloor = SPOKE_OPERATING_CASH_FLOOR;
        plan.spokeOperatingCashTopUp = SPOKE_OPERATING_CASH_TOP_UP;
        plan.minFirstDeposit = MIN_FIRST_DEPOSIT;
        plan.performanceFeeBps = PERFORMANCE_FEE_BPS;
        plan.maxBridgeFeeBps = MAX_BRIDGE_FEE_BPS;
    }

    /// @notice Deploys the protocol on the selected Arbitrum fork and creates the fund through the real factory.
    /// @param extraHubPools Additional hub Uniswap V4 pools, appended to the Mandate pool list and placed in the
    ///        unwind order right after the scripts' V4 step (before Aave) when `extraInUnwind`.
    function _createFund(FundPlan memory plan, PoolKey[] memory extraHubPools, bool extraInUnwind)
        internal
        returns (Mandate memory m)
    {
        hubDeployment = _deployProtocol(recipient, guardian, registryOwner);
        FundFactory factory = hubDeployment.factory;
        creationNumber = factory.nextCreationNumber();
        fundId = factory.fundIdOf(ARBITRUM, creationNumber, manager);
        m = _buildMandate(factory, fundId, plan);
        if (extraHubPools.length != 0) m = _withExtraHubPools(m, extraHubPools, extraInUnwind);
        mandateHash = MandateLib.hash(m);

        IFundFactory.HubParams memory p =
            _hubParams(creationNumber, plan, _coreVaultCreationCode(hubDeployment.coreVaultLogic));
        if (extraHubPools.length != 0) {
            PoolKey[] memory keys = new PoolKey[](1 + extraHubPools.length);
            keys[0] = plan.hubPool;
            for (uint256 i; i < extraHubPools.length; ++i) {
                keys[i + 1] = extraHubPools[i];
            }
            p.uniswapV4Pools = keys;
        }
        _fundManagerSeed(ARB_USDC, manager, address(factory), p.seedAmount);
        vm.prank(manager);
        IFundFactory.FundAddresses memory a = factory.createFund(m, p);
        core = ICoreVault(a.coreVault);
        shareToken = a.shareToken;
        managerFeeVault = a.managerFeeVault;
        receiver = IValueReportReceiver(a.valueReportReceiver);
        hubSpoke = ISpokeVault(a.chains[0].spokeVault);
        hubUniswap = a.chains[0].uniswapV4Adapter;
        hubAave = a.chains[0].aaveV3Adapter;
        hubAcross = a.chains[0].acrossBridgeAdapter;

        hubKey = plan.hubPool;
        hubPoolId = PoolId.unwrap(hubKey.toId());
        (hubSqrtP0, hubTick0,,) = IStateView(ARB_V4_STATE_VIEW).getSlot0(PoolId.wrap(hubPoolId));
        arbitrumRouter = _deployRouter(ARB_V4_POOL_MANAGER, ARB_WETH, ARB_USDC, 100_000e18, 500_000_000e6);
    }

    function _withExtraHubPools(Mandate memory m, PoolKey[] memory extra, bool inUnwind)
        internal
        pure
        returns (Mandate memory)
    {
        address hubUni = m.adapters[0].adapter;
        PoolConfig[] memory pools = new PoolConfig[](m.pools.length + extra.length);
        for (uint256 i; i < m.pools.length; ++i) {
            pools[i] = m.pools[i];
        }
        for (uint256 i; i < extra.length; ++i) {
            pools[m.pools.length + i] = PoolConfig(m.hubChainId, hubUni, PoolId.unwrap(extra[i].toId()));
        }
        m.pools = pools;
        if (inUnwind) {
            UnwindStep[] memory order = new UnwindStep[](m.unwindOrder.length + extra.length);
            order[0] = m.unwindOrder[0];
            for (uint256 i; i < extra.length; ++i) {
                order[1 + i] = UnwindStep(m.hubChainId, hubUni, PoolId.unwrap(extra[i].toId()));
            }
            for (uint256 i = 1; i < m.unwindOrder.length; ++i) {
                order[extra.length + i] = m.unwindOrder[i];
            }
            m.unwindOrder = order;
        }
        return m;
    }

    // ------------------------------------------------------------------ oracle

    /// @notice price1e18 of WETH from the fund's own price source (Chainlink ETH / USD): USDC base units per wei * 1e18.
    function _oracle() internal view returns (uint256 price) {
        (price,) = IPriceSource(hubDeployment.priceSource).priceInUsdc(ARB_WETH);
    }

    /// @notice sqrtPriceX96 of the WETH/USDC pool that the oracle price implies (WETH is currency0).
    function _oracleSqrtPrice() internal view returns (uint160) {
        // price of currency1 per currency0 in raw units = price1e18 / 1e18; sqrt in Q96.
        return SafeCast.toUint160(Math.sqrt(Math.mulDiv(_oracle(), 1 << 192, 1e18)));
    }

    // ------------------------------------------------------------------ holders and the manager

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        deal(ARB_USDC, who, IERC20(ARB_USDC).balanceOf(who) + amount);
        vm.startPrank(who);
        IERC20(ARB_USDC).approve(address(core), amount);
        (shares,) = core.deposit(amount, 0);
        vm.stopPrank();
    }

    function _allocate(uint256 amount) internal {
        vm.prank(manager);
        core.allocateToHubSpokeVault(amount);
    }

    /// @dev Swaps the pool back to `target` from either side (an arbitrageur).
    function _arbTo(V4SwapRouter router, PoolKey memory key, address stateView, uint160 target) internal {
        (uint160 now_,,,) = IStateView(stateView).getSlot0(key.toId());
        if (now_ == target) return;
        vm.prank(trader);
        router.swap(key, target < now_, -int256(uint256(type(uint128).max)), target);
        (now_,,,) = IStateView(stateView).getSlot0(key.toId());
        assertEq(now_, target, "arbitrage restored the price");
    }

    /// @notice The manager buys WETH with `usdcTotal` of hub Unallocated USDC through `key`, in `chunks`; after each
    ///         chunk the arbitrageur restores the pool to the price it had before.
    function _buyWethInChunks(PoolKey memory key, uint256 usdcTotal, uint256 chunks) internal returns (uint256 weth) {
        bytes32 id = PoolId.unwrap(key.toId());
        (uint160 start,,,) = IStateView(ARB_V4_STATE_VIEW).getSlot0(PoolId.wrap(id));
        uint256 chunk = usdcTotal / chunks;
        for (uint256 i; i < chunks; ++i) {
            uint256 amount = i == chunks - 1 ? usdcTotal - chunk * (chunks - 1) : chunk;
            uint256 minOut = _minWethFor(amount);
            bytes memory params = _swapParams();
            vm.prank(manager);
            weth += hubSpoke.swapExactInput(hubUniswap, id, ARB_USDC, amount, minOut, params);
            _arbTo(arbitrumRouter, key, ARB_V4_STATE_VIEW, start);
        }
    }

    /// @notice Ticks of the range [price * (1 - down), price * (1 + up)] around the current price, on the spacing.
    function _ticksAround(PoolKey memory key, uint256 downPpm, uint256 upPpm)
        internal
        view
        returns (int24 lo, int24 hi)
    {
        return _ticksAroundOn(ARB_V4_STATE_VIEW, key, downPpm, upPpm);
    }

    function _ticksAroundOn(address stateView, PoolKey memory key, uint256 downPpm, uint256 upPpm)
        internal
        view
        returns (int24 lo, int24 hi)
    {
        (uint160 sqrtP,,,) = IStateView(stateView).getSlot0(key.toId());
        uint160 sqrtLo = SafeCast.toUint160(Math.mulDiv(sqrtP, Math.sqrt((1e6 - downPpm) * 1e12), 1e9));
        uint160 sqrtHi = SafeCast.toUint160(Math.mulDiv(sqrtP, Math.sqrt((1e6 + upPpm) * 1e12), 1e9));
        lo = _floorTick(TickMath.getTickAtSqrtPrice(sqrtLo), key.tickSpacing);
        hi = _floorTick(TickMath.getTickAtSqrtPrice(sqrtHi), key.tickSpacing) + key.tickSpacing;
    }

    function _floorTick(int24 t, int24 spacing) internal pure returns (int24 r) {
        r = t / spacing * spacing;
        if (r > t) r -= spacing;
    }

    /// @notice Builds a hub V4 position worth about `value` USDC over [price * (1 - down), price * (1 + up)] around the
    ///         current price of `key`: buys the WETH leg in chunks in the scripts' hub pool (arbitraged back), then
    ///         opens in `key` with both legs.
    function _openAround(PoolKey memory key, uint256 downPpm, uint256 upPpm, uint256 value)
        internal
        returns (bytes32 positionKey)
    {
        (lastLower, lastUpper) = _ticksAround(key, downPpm, upPpm);
        uint256 usdcForWeth = _usdcForWethLeg(key, value);
        uint256 weth = usdcForWeth == 0 ? 0 : _buyWethInChunks(hubKey, usdcForWeth, 1 + usdcForWeth / 5000e6);
        positionKey = _openWith(key, weth, value - usdcForWeth);
    }

    /// @dev USDC to turn into WETH so that a position over [lastLower, lastUpper] worth `value` is balanced now.
    function _usdcForWethLeg(PoolKey memory key, uint256 value) internal view returns (uint256) {
        (uint160 sqrtP,,,) = IStateView(ARB_V4_STATE_VIEW).getSlot0(key.toId());
        uint256 a0 = SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(lastUpper), 1e18, true);
        uint256 a1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(lastLower), sqrtP, 1e18, true);
        uint256 v0 = Math.mulDiv(a0, _oracle(), 1e18);
        return Math.mulDiv(value, v0, v0 + a1);
    }

    function _openWith(PoolKey memory key, uint256 weth, uint256 usdcLeg) internal returns (bytes32 positionKey) {
        bytes memory params = abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: lastLower,
                tickUpper: lastUpper,
                liquidity: 0,
                amount0Max: SafeCast.toUint128(weth),
                amount1Max: SafeCast.toUint128(usdcLeg),
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.prank(manager);
        (positionKey,,) = hubSpoke.openPosition(hubUniswap, PoolId.unwrap(key.toId()), weth, usdcLeg, params);
    }

    /// @notice The hub vault's remaining Unallocated USDC into the Aave USDC position (open or increase).
    function _parkRestInAave() internal {
        uint256 rest = hubSpoke.unallocatedBalance(ARB_USDC);
        if (rest == 0) return;
        vm.prank(manager);
        (hubAavePosition,,) = hubSpoke.openPosition(hubAave, _aavePoolKey(), rest, 0, abi.encode(rest));
    }

    // ------------------------------------------------------------------ attack legs

    /// @notice A leg that pushes `key` down to `fraction1e18` of its current price and leaves USDC-only liquidity just
    ///         under it, sized to absorb up to 200 WETH at about that price (so the vault's own sale clears its floor).
    function _crushLeg(PoolKey memory key, address stateView, uint256 fraction1e18)
        internal
        view
        returns (PoolActor.Leg memory leg)
    {
        (uint160 start,,,) = IStateView(stateView).getSlot0(key.toId());
        leg.key = key;
        leg.down = true;
        leg.restoreTo = start;
        leg.pushTo = SafeCast.toUint160(Math.mulDiv(start, Math.sqrt(fraction1e18 * 1e18), 1e18));
        int24 tick = TickMath.getTickAtSqrtPrice(leg.pushTo);
        leg.jitHi = _floorTick(tick, key.tickSpacing);
        leg.jitLo = leg.jitHi - 100 * key.tickSpacing;
        uint160 sqrtLo = TickMath.getSqrtPriceAtTick(leg.jitLo);
        uint160 sqrtHi = TickMath.getSqrtPriceAtTick(leg.jitHi);
        uint256 budget = Math.mulDiv(Math.mulDiv(leg.pushTo, leg.pushTo, 1 << 96), 200e18, 1 << 96) + 1e6;
        leg.jitLiq = LiquidityAmounts.getLiquidityForAmount1(sqrtLo, sqrtHi, budget);
    }

    /// @notice A leg that pushes `key` to `pushTo` and leaves USDC-only liquidity just under it able to buy about
    ///         `wethCapacity` WETH there.
    function _jitLeg(PoolKey memory key, address stateView, uint160 pushTo, uint256 wethCapacity)
        internal
        view
        returns (PoolActor.Leg memory leg)
    {
        leg = _pushLeg(key, stateView, pushTo);
        int24 tick = TickMath.getTickAtSqrtPrice(pushTo);
        leg.jitHi = _floorTick(tick, key.tickSpacing);
        leg.jitLo = leg.jitHi - 100 * key.tickSpacing;
        uint256 budget = Math.mulDiv(Math.mulDiv(pushTo, pushTo, 1 << 96), wethCapacity, 1 << 96) + 1e6;
        leg.jitLiq = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(leg.jitLo), TickMath.getSqrtPriceAtTick(leg.jitHi), budget
        );
    }

    /// @notice A leg that only pushes `key` to `pushTo` and restores it (no liquidity left behind).
    function _pushLeg(PoolKey memory key, address stateView, uint160 pushTo)
        internal
        view
        returns (PoolActor.Leg memory leg)
    {
        (uint160 start,,,) = IStateView(stateView).getSlot0(key.toId());
        leg.key = key;
        leg.down = pushTo < start;
        leg.pushTo = pushTo;
        leg.restoreTo = start;
    }

    function _one(PoolActor.Leg memory leg) internal pure returns (PoolActor.Leg[] memory legs) {
        legs = new PoolActor.Leg[](1);
        legs[0] = leg;
    }

    // ------------------------------------------------------------------ measurement

    /// @notice Value of a holder's shares at the current Share Price (view valuation at spot, as the vault reads it).
    function _holderValue(address who) internal view returns (uint256) {
        uint256 supply = IERC20(shareToken).totalSupply();
        if (supply == 0) return 0;
        return Math.mulDiv(IERC20(shareToken).balanceOf(who), core.shareAssets(), supply);
    }

    /// @notice An actor's WETH plus USDC at the oracle, plus its shares at the current Share Price.
    function _wealth(address who) internal view returns (uint256) {
        return IERC20(ARB_USDC).balanceOf(who) + Math.mulDiv(IERC20(ARB_WETH).balanceOf(who), _oracle(), 1e18)
            + _holderValue(who);
    }

    /// @notice Principal of every hub V4 position valued at the oracle-implied composition (fix option (a)).
    function _hubV4PrincipalAtOracle() internal view returns (uint256 value) {
        uint160 sqrtOracle = _oracleSqrtPrice();
        ISpokeVault.PositionRef[] memory refs = hubSpoke.positions();
        for (uint256 i; i < refs.length; ++i) {
            if (refs[i].adapter != hubUniswap) continue;
            IAdapter.PositionValue memory v = IAdapter(hubUniswap).positionValue(refs[i].positionKey);
            (uint256 a0, uint256 a1) = _amountsAt(sqrtOracle, v.tickLower, v.tickUpper, v.liquidity);
            value += a1 + Math.mulDiv(a0, _oracle(), 1e18);
        }
    }

    /// @notice Amounts a position of `liquidity` over [lower, upper] holds at `sqrtP` (Pool.modifyLiquidity branches,
    ///         rounded down), the formula the adapter's `_principal` applies at `slot0`.
    function _amountsAt(uint160 sqrtP, int24 lower, int24 upper, uint128 liquidity)
        internal
        pure
        returns (uint256 a0, uint256 a1)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        if (sqrtP <= sqrtA) {
            a0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtP < sqrtB) {
            a0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, false);
            a1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, false);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        }
    }

    /// @notice Principal of every hub V4 position as the vault values it now (spot composition, oracle price).
    function _hubV4PrincipalAsVaultReads() internal view returns (uint256 value) {
        ISpokeVault.PositionRef[] memory refs = hubSpoke.positions();
        for (uint256 i; i < refs.length; ++i) {
            if (refs[i].adapter != hubUniswap) continue;
            IAdapter.PositionValue memory v = IAdapter(hubUniswap).positionValue(refs[i].positionKey);
            value += v.principal1 + Math.mulDiv(v.principal0, _oracle(), 1e18);
        }
    }

    function _log(string memory label, uint256 v6) internal pure {
        console2.log(label, v6);
    }

    function _logSigned(string memory label, int256 v6) internal pure {
        console2.log(label, v6);
    }
}
