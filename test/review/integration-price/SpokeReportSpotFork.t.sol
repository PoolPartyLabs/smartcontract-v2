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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {VaaLib, VaaBody, VaaEnvelope} from "wormhole-sdk/libraries/VaaLib.sol";
import {toUniversalAddress} from "wormhole-sdk/Utils.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {IntegrationPriceBase, PoolActor} from "./IntegrationPriceBase.sol";

/// @notice Part 1.2 (spoke) of the integration-price review: report 02 C-01, spoke variant. On the Robinhood fork a
///         stranger moves the real WETH/USDG pool, calls the permissionless `report()` and moves the pool back inside
///         ONE PoolManager unlock; the VAA is signed with WormholeOverride on the real Arbitrum Core and delivered to the
///         fund's real ValueReportReceiver; the hub then prices the spoke position at the frozen composition through the
///         real ChainlinkPriceSource.
/// @dev Fund (factory, scripts' Mandate, Spoke Cap 250,000): Alice 500,000 USDC, the claimant 60,000 (earlier); 200,000
///      USDC sent to Robinhood through the live Across SpokePool (fill simulated as the project's fork suites do), a
///      WETH/USDG position of about 150,000 USDG there, an honest report delivered first.
/// @notice Ported to fix/pp-sc-fix-independent-review (review C-02 spoke route, security sweep S-1, S-14): the moved
///         report still carries the spot principals, but the hub recomputes the spoke position from the report's
///         liquidity and ticks at the price-source price, so Share Assets, the claim and the deposit stay at the fair
///         price. e5c778a: stranger's round trip 230.58 USDG, Share Price +0.7685%, a 50,000 claim kept 381 shares, a
///         100,000 deposit lost 699.58.
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
///      ARBITRUM_FORK_BLOCK=<head - 300> ROBINHOOD_FORK_BLOCK=<head - 300>
///      forge test -j 1 --match-path 'test/review/integration-price/SpokeReportSpotFork.t.sol' -vv
contract SpokeReportSpotFork is IntegrationPriceBase {
    using AdvancedWormholeOverride for ICoreBridge;

    uint256 internal constant ALICE_DEPOSIT = 500_000e6;
    uint256 internal constant CLAIMANT_STAKE = 60_000e6;
    uint256 internal constant SEND = 200_000e6;
    uint256 internal constant SPOKE_V4_VALUE = 150_000e6;
    uint256 internal constant CLAIM = 50_000e6;

    address internal claimant = makeAddr("claimant");
    address internal carol = makeAddr("carol");
    PoolKey internal spokeKey;
    uint256 internal oracleCached; // price1e18 of WETH read on Arbitrum (USDG at 1:1)
    int24 internal spokeLower;
    int24 internal spokeUpper;
    bytes32 internal spokePosition;

    // ------------------------------------------------------------------ set-up across both forks

    function _setUp() internal {
        _createForks();
        _onArbitrum();
        Mandate memory m = _createFund(_pricePlan(250_000e6), new PoolKey[](0));
        oracleCached = _oracle();
        ICoreBridge(ARB_WORMHOLE_CORE).setUpOverride();
        _deposit(alice, ALICE_DEPOSIT);
        _deposit(claimant, CLAIMANT_STAKE);
        _createSpoke(m);
        // Port to the fix branch (security review S-14): the hub sends to a spoke only once it accepted a report from
        // it, so the new Spoke Vault's first (empty) report is delivered before the send.
        _deliverLatest(_reportNow());
        _sendToRobinhood();
        _onArbitrum();
        _deliverLatest(_reportNow()); // honest baseline report (no pool move)
        _onArbitrum();
    }

    function _createSpoke(Mandate memory m) internal {
        FundPlan memory plan = _pricePlan(250_000e6);
        _onRobinhood();
        Deployment memory rd = _deployProtocol(recipient, guardian, registryOwner, registryOwner);
        vm.prank(manager);
        IFundFactory.ChainAddresses memory s =
            rd.factory.createSpoke(creationNumber, m, _spokeParams(mandateHash, plan));
        spokeVault = ISpokeVault(s.spokeVault);
        spokeUniswap = s.uniswapV4Adapter;
        spokeSwapAdapter = s.uniswapV3SwapAdapter;
        spokeAcross = s.acrossBridgeAdapter;
        spokeKey = _spokePoolKey();
    }

    function _sendToRobinhood() internal {
        _onArbitrum();
        vm.recordLogs();
        vm.prank(manager);
        transitId = core.sendToSpoke(0, SEND, 0, ""); // DEC-162: the Across adapter fixes the amount to arrive
        (,,, DepositData memory d) = _fundsDeposited(vm.getRecordedLogs(), ARB_ACROSS_SPOKE_POOL);
        acrossMessage = d.message;
        amountToArrive = d.outputAmount;

        _onRobinhood();
        deal(RH_USDG, address(spokeVault), IERC20(RH_USDG).balanceOf(address(spokeVault)) + amountToArrive);
        vm.prank(RH_ACROSS_SPOKE_POOL);
        spokeVault.handleV3AcrossMessage(RH_USDG, amountToArrive, relayer, acrossMessage);
        robinhoodRouter = _deployRouter(RH_V4_POOL_MANAGER, RH_WETH, RH_USDG, 100_000e18, 500_000_000e6);
        _spokeOpenAround(100_000, 100_000, SPOKE_V4_VALUE);
    }

    function _spokeOpenAround(uint256 downPpm, uint256 upPpm, uint256 value) internal {
        (spokeLower, spokeUpper) = _ticksAroundOn(RH_V4_STATE_VIEW, spokeKey, downPpm, upPpm);
        (uint160 sqrtP,,,) = IStateView(RH_V4_STATE_VIEW).getSlot0(spokeKey.toId());
        uint256 a0 = SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(spokeUpper), 1e18, true);
        uint256 a1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(spokeLower), sqrtP, 1e18, true);
        uint256 v0 = Math.mulDiv(a0, oracleCached, 1e18);
        uint256 usdgForWeth = Math.mulDiv(value, v0, v0 + a1);
        uint256 weth = _spokeBuyWeth(usdgForWeth);
        bytes memory params = abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: spokeLower,
                tickUpper: spokeUpper,
                liquidity: 0,
                amount0Max: SafeCast.toUint128(weth),
                amount1Max: SafeCast.toUint128(value - usdgForWeth),
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.prank(manager);
        (spokePosition,,) =
            spokeVault.openPosition(spokeUniswap, RH_WETH_USDG_POOL_ID, weth, value - usdgForWeth, params);
    }

    /// @dev DEC-136: through the spoke's Uniswap V3 swap adapter, never in the fund's V4 pool, whose price stays put.
    function _spokeBuyWeth(uint256 usdgTotal) internal returns (uint256 weth) {
        (uint160 start,,,) = IStateView(RH_V4_STATE_VIEW).getSlot0(spokeKey.toId());
        uint256 chunks = 1 + usdgTotal / 5000e6;
        uint256 chunk = usdgTotal / chunks;
        for (uint256 i; i < chunks; ++i) {
            uint256 amount = i == chunks - 1 ? usdgTotal - chunk * (chunks - 1) : chunk;
            vm.prank(manager);
            uint256 out = spokeVault.swap(spokeSwapAdapter, RH_USDG, RH_WETH, amount, 300, "");
            assertGe(out, Math.mulDiv(amount, 1e18, oracleCached) * 97 / 100, "within 3% of the oracle");
            weth += out;
        }
        (uint160 end,,,) = IStateView(RH_V4_STATE_VIEW).getSlot0(spokeKey.toId());
        assertEq(end, start, "DEC-136: the fund's pool never traded");
    }

    // ------------------------------------------------------------------ reports

    struct Published {
        VaaEnvelope envelope;
        bytes payload;
    }

    /// @notice An honest `report()` on Robinhood with the pool where it is.
    function _reportNow() internal returns (Published memory p) {
        _onRobinhood();
        vm.recordLogs();
        spokeVault.report();
        p = _published(vm.getRecordedLogs());
    }

    function _published(Vm.Log[] memory logs) internal view returns (Published memory p) {
        VaaBody[] memory published = ICoreBridge(RH_WORMHOLE_CORE).fetchPublishedMessages(logs);
        assertEq(published.length, 1, "one Wormhole message");
        p.envelope = published[0].envelope;
        p.payload = published[0].payload;
    }

    /// @notice Signs the message with the overridden guardian set of the real Arbitrum Core and delivers it (anyone).
    function _deliverLatest(Published memory p) internal {
        _onArbitrum();
        VaaEnvelope memory e = VaaEnvelope(
            uint32(block.timestamp),
            p.envelope.nonce,
            WORMHOLE_ROBINHOOD,
            toUniversalAddress(address(spokeVault)),
            p.envelope.sequence,
            1
        );
        bytes memory vaa = VaaLib.encode(ICoreBridge(ARB_WORMHOLE_CORE).sign(VaaBody(e, p.payload)));
        vm.prank(makeAddr("anyone"));
        receiver.deliver(vaa);
    }

    /// @notice Spoke position principal in the latest accepted report, at the report's composition and at the oracle's.
    function _reportedSpokePosition() internal view returns (uint256 asReported, uint256 atOracle) {
        (ReportCodec.Report memory r,,) = receiver.latestReport(0);
        ReportCodec.PositionReport memory pos = r.positions[0];
        asReported = pos.principal1 + Math.mulDiv(pos.principal0, oracleCached, 1e18);
        uint160 sqrtOracle = SafeCast.toUint160(Math.sqrt(Math.mulDiv(oracleCached, 1 << 192, 1e18)));
        (uint256 a0, uint256 a1) = _amountsAt(sqrtOracle, pos.tickLower, pos.tickUpper, pos.liquidity);
        atOracle = a1 + Math.mulDiv(a0, oracleCached, 1e18);
    }

    // ------------------------------------------------------------------ the attack

    uint256 internal assetsFair;
    uint256 internal priceFair;
    uint256 internal fairReported;
    uint256 internal fairAtOracle;
    uint256 internal badReported;
    uint256 internal badAtOracle;
    uint256 internal assetsBad;
    int256 internal strangerCost;

    function test_REVIEW_C02_spokeReportAtAMovedCompositionNoLongerMovesTheSharePrice() public {
        _setUp();
        assetsFair = core.shareAssets();
        priceFair = ShareMath.sharePrice(assetsFair, IERC20(shareToken).totalSupply());
        (fairReported, fairAtOracle) = _reportedSpokePosition();
        _deliverLatest(_strangerReportsAtAMovedPrice());
        _measureMovedReport();
        _claimAndDepositAtTheMovedPrice();
        _lifetimeAndDisplacement();
    }

    /// @notice 1. Robinhood: a stranger moves the pool under the fund's range, calls report() and moves it back, in one
    ///         unlock (it holds only what the net fee needs).
    function _strangerReportsAtAMovedPrice() internal returns (Published memory bad) {
        _onRobinhood();
        PoolActor stranger = new PoolActor(IPoolManager(RH_V4_POOL_MANAGER));
        deal(RH_USDG, address(stranger), 2000e6);
        deal(RH_WETH, address(stranger), 1e18);
        uint256 usdg0 = IERC20(RH_USDG).balanceOf(address(stranger));
        uint256 weth0 = IERC20(RH_WETH).balanceOf(address(stranger));
        uint160 edge = TickMath.getSqrtPriceAtTick(spokeLower - spokeKey.tickSpacing);
        (uint160 before,,,) = IStateView(RH_V4_STATE_VIEW).getSlot0(spokeKey.toId());
        vm.recordLogs();
        stranger.around(spokeKey, true, edge, address(spokeVault), abi.encodeCall(ISpokeVault.report, ()));
        bad = _published(vm.getRecordedLogs());
        (uint160 afterPush,,,) = IStateView(RH_V4_STATE_VIEW).getSlot0(spokeKey.toId());
        assertEq(afterPush, before, "pool back at its exact start price in the same transaction");
        strangerCost = int256(usdg0) - int256(IERC20(RH_USDG).balanceOf(address(stranger)))
            + (int256(weth0) - int256(IERC20(RH_WETH).balanceOf(address(stranger)))) * int256(oracleCached) / 1e18;
    }

    /// @notice 2. Arbitrum: the VAA was delivered by anyone; the hub prices the frozen composition.
    function _measureMovedReport() internal {
        assetsBad = core.shareAssets();
        uint256 priceBad = ShareMath.sharePrice(assetsBad, IERC20(shareToken).totalSupply());
        (badReported, badAtOracle) = _reportedSpokePosition();
        console2.log("===== spoke report frozen under a +-10% range (spoke position about 150,000)");
        console2.log("round trip on Robinhood paid by the stranger (USD 6dp)");
        console2.logInt(strangerCost);
        console2.log("spoke position in the honest report: as reported / at oracle composition");
        console2.log(fairReported, fairAtOracle);
        console2.log("spoke position in the moved report: as reported / at oracle composition");
        console2.log(badReported, badAtOracle);
        console2.log("Share Assets fair / with the moved report", assetsFair, assetsBad);
        console2.log("Share Price inflation (ppm)", Math.mulDiv(priceBad, 1e6, priceFair) - 1e6);
        assertGt(badReported, fairReported, "the stranger still moves the principals the report carries");
        assertEq(assetsBad, assetsFair, "the hub prices it at the oracle composition: Share Assets unmoved");
        assertApproxEqAbs(
            badAtOracle, fairAtOracle, 1, "option (a) on the hub: recomputed at the oracle it does not move"
        );
    }

    /// @notice 3. The claimant's Idle-paid claim at the inflated price, then a depositor within the report lifetime.
    function _claimAndDepositAtTheMovedPrice() internal {
        vm.prank(claimant);
        ICoreVault.PayoutReceipt memory r = core.requestPayout(CLAIM, ICoreVaultPayouts.PayoutMode.Instant, 0);
        uint256 fairShares = ShareMath.sharesToBurn(CLAIM, priceFair);
        console2.log("claim of 50,000: shares burned fair / with the moved report");
        console2.log(fairShares / 1e18, r.sharesBurned / 1e18);
        assertEq(r.unwindProceeds, 0, "Idle paid");
        assertEq(r.sharesBurned, fairShares, "the fair shares burned");

        _refreshEthUsdFeed();
        uint256 carolShares = _deposit(carol, 100_000e6);
        console2.log("Carol's 100,000 deposit: shares minted with the moved report", carolShares / 1e18);
        console2.log("Carol's value right after (99,750 net of the 25 bps flow fee)", _holderValue(carol));
        assertApproxEqAbs(_holderValue(carol), 99_750e6, 1e6, "the deposit is priced fair");
    }

    /// @notice 4. How long it stays: mints close after the report lifetime; payouts keep using it until displaced.
    function _lifetimeAndDisplacement() internal {
        (ReportCodec.Report memory rep,,) = receiver.latestReport(0);
        _advance(ROBINHOOD_MAX_REPORT_AGE + 1 - (block.timestamp - rep.timestamp));
        _refreshEthUsdFeed();
        deal(ARB_USDC, carol, 1000e6);
        vm.startPrank(carol);
        IERC20(ARB_USDC).approve(address(core), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.StaleSpokeReport.selector, 0));
        core.deposit(1000e6, 0);
        vm.stopPrank();
        _advance(2 hours);
        (uint256 stillReported,) = _reportedSpokePosition();
        assertEq(stillReported, badReported, "two hours later the payout valuation still uses the moved report");
        uint256 assetsLate = core.shareAssets();

        // 5. Displacement: anyone publishes an honest report and delivers it; the price comes back.
        _deliverLatest(_reportNow());
        (uint256 honestReported,) = _reportedSpokePosition();
        uint256 assetsHonest = core.shareAssets();
        console2.log("after an honest report: spoke position as reported", honestReported);
        console2.log("Share Assets two hours on with the moved report / after the honest one", assetsLate, assetsHonest);
        console2.log("Carol's value once displaced (paid 99,750 net of the flow fee)", _holderValue(carol));
        assertLt(honestReported, badReported, "an honest report displaces it");
        // e5c778a: the whole 4,291.50 gap was in force for two hours and Carol overpaid.
        assertApproxEqAbs(assetsLate, assetsHonest, 2e6, "no gap was in force");
        assertApproxEqAbs(_holderValue(carol), 99_750e6, 1e6, "Carol paid the fair price");
    }
}
