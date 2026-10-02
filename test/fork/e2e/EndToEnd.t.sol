// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {VaaLib, VaaBody, VaaEnvelope} from "wormhole-sdk/libraries/VaaLib.sol";
import {toUniversalAddress} from "wormhole-sdk/Utils.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {ISpokeVaultUnwind} from "../../../src/interfaces/ISpokeVaultUnwind.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {IManagerRegistry} from "../../../src/interfaces/IManagerRegistry.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {IChainlinkAggregatorV3} from "../../../src/interfaces/external/IChainlinkAggregatorV3.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {EndToEndBase} from "./EndToEndBase.sol";

/// @notice End-to-end fork scenario (docs/ARCHITECTURE.md §7): one fund driven across the pinned Arbitrum One and
///         Robinhood Chain forks against the live protocols (Across SpokePools, Uniswap V4 pools, the Aave V3 Pool, the
///         Wormhole Cores, the Chainlink ETH / USD feed) and the Fund Factory deployed through the deterministic
///         deployer on both chains. Each phase asserts its rules and cites the decision that governs them.
/// @dev The phases are `internal` so an adversarial variant (`EndToEndAdversarial.t.sol`) can replay a prefix of the
///      scenario and branch from it; `EndToEndForkTest` below runs the ten phases in order.
abstract contract EndToEndScenario is EndToEndBase {
    using AdvancedWormholeOverride for ICoreBridge;

    /// @dev DEC-127: the manager seeds the Mandate minimum, 100 USDC: 0.25 of flow fee, 99 whole shares at 1.00.
    uint256 internal constant MANAGER_SEED_SHARES = 99e18;
    uint256 internal constant MANAGER_SEED_IDLE = 99e6;
    uint256 internal constant HUB_ALLOCATION = 5000e6;
    uint256 internal constant AAVE_SUPPLY = 2000e6;
    uint256 internal constant HUB_V4_USDC = 3000e6;
    uint256 internal constant SPOKE_V4_USDG = 3000e6;
    uint256 internal constant AAVE_ACCRUAL_TIME = 1 hours;
    uint256 internal constant BRUNO_DEPOSIT = 11_000e6;
    uint256 internal constant ANA_PAYOUT = 3000e6;
    uint256 internal constant BRUNO_ABOVE_FREE_IDLE = 1000e6;
    uint256 internal constant DONATION = 1234e6;

    uint256 internal spokeSwapMinWeth;
    VaaEnvelope internal publishedEnvelope;
    bytes internal publishedPayload;

    // -----------------------------------------------------------------------------------------------------------------
    // Phase 1: factories on both forks, predicted addresses, the Mandate, createFund and createSpoke
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-053, DEC-054: the Mandate names every hub and spoke address before any exists; the factory lands at one
    ///      address on both chains and puts each contract at its prediction.
    function _phase1CreateFund() internal {
        _onArbitrum();
        hubDeployment = _deployProtocol(recipient, guardian, registryOwner);
        FundFactory factory = hubDeployment.factory;
        creationNumber = factory.nextCreationNumber();
        IFundFactory.FundAddresses memory predicted = factory.predictAddresses(creationNumber, manager, _chainIds());
        fundId = predicted.fundId;
        Mandate memory m = _buildMandate(factory, fundId, _plan());
        mandateHash = MandateLib.hash(m);
        _assertMandate(m, predicted);

        IFundFactory.HubParams memory p = _hubParams(creationNumber, _plan(), _coreVaultCreationCode(hubDeployment));
        _fundManagerSeed(ARB_USDC, manager, address(factory), p.seedAmount);
        vm.prank(manager);
        IFundFactory.FundAddresses memory a = factory.createFund(m, p);
        assertEq(a.coreVault, predicted.coreVault, "DEC-054: Core Vault at its prediction");
        assertEq(a.chains[0].spokeVault, predicted.chains[0].spokeVault, "DEC-054: hub Spoke Vault at its prediction");
        core = ICoreVault(a.coreVault);
        shareToken = a.shareToken;
        managerFeeVault = a.managerFeeVault;
        receiver = IValueReportReceiver(a.valueReportReceiver);
        hubSpoke = ISpokeVault(a.chains[0].spokeVault);
        hubUniswap = a.chains[0].uniswapV4Adapter;
        hubAave = a.chains[0].aaveV3Adapter;
        hubAcross = a.chains[0].acrossBridgeAdapter;
        assertEq(core.mandateHash(), mandateHash, "DEC-053: the Mandate is written once at creation");
        assertEq(core.flowFeeBps(), FLOW_FEE_BPS, "DEC-106: default flow fee");
        // DEC-127, DEC-061, DEC-113: the fund is born with the manager's seed, at least the Mandate minimum, at 1.00.
        assertEq(p.seedAmount, MIN_FIRST_DEPOSIT, "the manager seeds the minimum");
        assertEq(IERC20(shareToken).balanceOf(manager), MANAGER_SEED_SHARES, "DEC-127: the first shares");
        assertEq(core.idle(), MANAGER_SEED_IDLE);
        assertEq(core.sharePrice(), ShareMath.INITIAL_SHARE_PRICE, "DEC-061: 1 share = 1.00 USDC");

        _createSpoke(m, predicted);
    }

    /// @dev DEC-031, DEC-037, DEC-069, DEC-086, DEC-088, DEC-095, DEC-102, DEC-107, DEC-108, QA19, ruling 2026-09-29.
    function _assertMandate(Mandate memory m, IFundFactory.FundAddresses memory predicted) internal pure {
        address hubUni = predicted.chains[0].uniswapV4Adapter;
        address hubAaveAdapter = predicted.chains[0].aaveV3Adapter;
        assertEq(m.hubChainId, ARBITRUM, "DEC-011: Arbitrum One is the Hub Chain");
        assertEq(m.spokes.length, 1);
        assertEq(m.spokes[0].chainId, ROBINHOOD);
        assertEq(m.spokes[0].wormholeChainId, WORMHOLE_ROBINHOOD, "DEC-086: Wormhole chain 72");
        assertEq(
            m.spokes[0].spokeVault,
            toUniversalAddress(predicted.chains[1].spokeVault),
            "DEC-054: the predicted Robinhood Spoke Vault"
        );
        assertEq(m.spokes[0].spokeToken, RH_USDG, "DEC-031: Across delivers USDG on Robinhood");
        assertEq(m.spokes[0].maxReportAge, 1588, "ruling 2026-09-29: 1,587 s plus one block");
        assertEq(m.spokes[0].spokeCap, 4000e6, "DEC-037, DEC-095: 40% of the first deposit, in USDC");
        assertEq(m.pools[0].poolKey, ARB_WETH_USDC_POOL_ID, "DEC-030: hub WETH/USDC 0.05%");
        assertEq(m.pools[1].poolKey, bytes32(uint256(uint160(ARB_USDC))), "DEC-018, DEC-028: Aave USDC on the hub");
        assertEq(m.pools[2].poolKey, RH_WETH_USDG_POOL_ID, "DEC-030: spoke WETH/USDG 0.05%");
        assertEq(m.bridgeAdapters.length, 2, "DEC-088: Across on both sides");
        assertEq(m.bridgeAdapters[0].adapter, predicted.chains[0].acrossBridgeAdapter);
        assertEq(m.bridgeAdapters[1].adapter, predicted.chains[1].acrossBridgeAdapter);
        assertEq(m.payoutFeeBps, 200, "DEC-102: Payout Fee 2%");
        assertEq(m.minFirstDeposit, 100e6, "DEC-061: 100 USDC minimum first deposit");
        assertEq(m.performanceFeeBps, 2000, "DEC-107: performance fee 20%");
        assertEq(m.managementFeeBps, 0, "DEC-108: management fee 0");
    }

    /// @dev DEC-054: same operator and salt give the same factory address on Robinhood; the Spoke Vault lands at the
    ///      address the hub's Mandate already names.
    function _createSpoke(Mandate memory m, IFundFactory.FundAddresses memory predicted) internal {
        _onRobinhood();
        Deployment memory rd = _deployProtocol(recipient, guardian, registryOwner);
        assertEq(address(rd.factory), address(hubDeployment.factory), "DEC-054: one factory address on both chains");
        vm.prank(manager);
        IFundFactory.ChainAddresses memory s =
            rd.factory.createSpoke(creationNumber, m, _spokeParams(mandateHash, _plan()));
        assertEq(s.spokeVault, predicted.chains[1].spokeVault, "DEC-054: Spoke Vault at its prediction");
        assertEq(toUniversalAddress(s.spokeVault), m.spokes[0].spokeVault);
        spokeVault = ISpokeVault(s.spokeVault);
        spokeUniswap = s.uniswapV4Adapter;
        spokeAcross = s.acrossBridgeAdapter;
        assertEq(spokeVault.mandateHash(), mandateHash, "FF-OQ-1: the spoke's Mandate is the hub's");
        assertEq(spokeVault.coreVault(), address(core));
        assertEq(spokeVault.fundId(), fundId);
        assertEq(spokeVault.baseToken(), RH_USDG);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Phase 2: Ana deposits 10,000 USDC
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-127: the first deposit after the manager's seed, at 1.00 (the Mandate minimum bound the seed). DEC-106:
    ///      25 bps flow fee to the Protocol Recipient, taken before pricing. DEC-035: whole shares only.
    function _phase2AnaDeposits() internal {
        _onArbitrum();
        deal(ARB_USDC, ana, ANA_DEPOSIT);
        vm.startPrank(ana);
        IERC20(ARB_USDC).approve(address(core), ANA_DEPOSIT);
        uint256 recipientBefore = IERC20(ARB_USDC).balanceOf(recipient);
        (uint256 shares, uint256 charged) = core.deposit(ANA_DEPOSIT, 0);
        vm.stopPrank();

        uint256 fee = ANA_DEPOSIT * FLOW_FEE_BPS / 10_000;
        assertEq(fee, 25e6);
        assertEq(IERC20(ARB_USDC).balanceOf(recipient) - recipientBefore, fee, "DEC-106: flow fee to the protocol");
        assertEq(shares, 9975e18, "DEC-061: 9,975 whole shares at 1.00");
        assertEq(shares % 1e18, 0, "DEC-035: whole shares");
        assertEq(charged, ANA_DEPOSIT, "DEC-035: nothing left over at 1.00");
        assertEq(IERC20(shareToken).balanceOf(ana), shares);
        assertEq(core.idle(), MANAGER_SEED_IDLE + ANA_DEPOSIT - fee);
        assertEq(core.shareAssets(), MANAGER_SEED_IDLE + ANA_DEPOSIT - fee);
        assertEq(core.sharePrice(), ShareMath.INITIAL_SHARE_PRICE, "DEC-061: 1 share = 1.00 USDC");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Phase 3: allocation to the hub Spoke Vault, Aave supply, a Uniswap V4 position, income on both
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-017, DEC-072: only Free Idle moves to the hub Spoke Vault. DEC-079, DEC-080: the vault's ledger follows
    ///      what the adapters return. DEC-068: Aave interest is income. DEC-092: income stays outside Share Assets.
    function _phase3HubAllocationAndIncome() internal {
        _onArbitrum();
        uint256 idleBefore = core.idle();
        vm.prank(manager);
        core.allocateToHubSpokeVault(HUB_ALLOCATION);
        assertEq(core.idle(), idleBefore - HUB_ALLOCATION, "DEC-072: Free Idle allocated");
        assertEq(hubSpoke.unallocatedBalance(ARB_USDC), HUB_ALLOCATION, "DEC-055: Unallocated Balance, not Idle");
        assertEq(core.shareAssets(), idleBefore, "DEC-104: a move between buckets keeps Share Assets");

        vm.prank(manager);
        (bytes32 aaveKey, uint256 supplied,) =
            hubSpoke.openPosition(hubAave, _aavePoolKey(), AAVE_SUPPLY, 0, abi.encode(AAVE_SUPPLY));
        hubAavePosition = aaveKey;
        assertEq(supplied, AAVE_SUPPLY, "AAVE-2: explicit amount supplied");

        _openHubUniswapPosition();

        _advance(AAVE_ACCRUAL_TIME);
        IAdapter.PositionValue memory aave = IAdapter(hubAave).positionValue(hubAavePosition);
        assertEq(aave.principal0, AAVE_SUPPLY, "DEC-068: principal stays the amount supplied");
        assertGt(aave.income0, 0, "DEC-068: interest since supply is income");

        arbitrumRouter = _deployRouter(ARB_V4_POOL_MANAGER, ARB_WETH, ARB_USDC, 10_000e18, 50_000_000e6);
        _generateFees(
            arbitrumRouter, _hubPoolKey(), ARB_V4_STATE_VIEW, _center(ARB_V4_STATE_VIEW, ARB_WETH_USDC_POOL_ID)
        );
        IAdapter.PositionValue memory v4 = IAdapter(hubUniswap).positionValue(hubUniswapPosition);
        assertGt(v4.income0, 0, "DEC-079: WETH fees");
        assertGt(v4.income1, 0, "DEC-079: USDC fees");
        assertEq(core.shareAssets(), _sumOfBuckets(), "DEC-092, DEC-104: income is outside Share Assets");
    }

    /// @dev Half of the USDC is swapped to WETH through the adapter in the Mandate pool, then both go into a range
    ///      around the current price; what the position does not use returns to Unallocated Balance (DEC-079).
    function _openHubUniswapPosition() internal {
        uint256 half = HUB_V4_USDC / 2;
        uint256 usdcBefore = hubSpoke.unallocatedBalance(ARB_USDC);
        uint256 weth = _swapHubUsdcForWeth(half);
        bytes memory params = _openParams(_center(ARB_V4_STATE_VIEW, ARB_WETH_USDC_POOL_ID), weth, half);
        vm.prank(manager);
        (bytes32 key, uint256 used0, uint256 used1) =
            hubSpoke.openPosition(hubUniswap, ARB_WETH_USDC_POOL_ID, weth, half, params);
        hubUniswapPosition = key;
        assertGt(used0, 0);
        assertGt(used1, 0);
        assertEq(hubSpoke.unallocatedBalance(ARB_WETH), weth - used0, "DEC-079: unused WETH back");
        assertEq(hubSpoke.unallocatedBalance(ARB_USDC), usdcBefore - half - used1, "DEC-079: unused USDC back");
        assertEq(hubSpoke.positions().length, 2);
    }

    /// @dev OQ-04 stance: the manager swaps Unallocated Balance through the adapter in a Mandate pool, with a minimum
    ///      from the hub price source.
    function _swapHubUsdcForWeth(uint256 usdcIn) internal returns (uint256 weth) {
        uint256 minWeth = _minWethFor(usdcIn);
        vm.prank(manager);
        weth = hubSpoke.swapExactInput(hubUniswap, ARB_WETH_USDC_POOL_ID, ARB_USDC, usdcIn, minWeth, _swapParams());
        assertEq(hubSpoke.unallocatedBalance(ARB_WETH), weth, "DEC-080: swap output credited from the adapter");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Phase 4: 4,000 USDC to Robinhood through the live Across SpokePool
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-037, DEC-095: the Spoke Cap bounds the send. DEC-158, DEC-162: the manager passes no bridge parameter;
    ///      the Across adapter fixes the amount to arrive. DEC-066: a per-send escrow is the depositor. DEC-085: Share
    ///      Assets count the transit at the amount that will arrive. DEC-087: the vault fixes recipient, token pair and
    ///      message.
    function _phase4SendToRobinhood() internal {
        _deliverFirstSpokeReport();
        _onArbitrum();
        _assertSendRefusals();

        uint256 assetsBefore = core.shareAssets();
        uint256 idleBefore = core.idle();
        uint32 depositId = IAcrossSpokePool(ARB_ACROSS_SPOKE_POOL).numberOfDeposits();
        vm.recordLogs();
        vm.prank(manager);
        transitId = core.sendToSpoke(0, BRIDGE_AMOUNT, 0, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Transit memory t = core.transit(transitId);
        amountToArrive = t.amountToArrive;
        assertEq(uint8(t.state), uint8(TransitState.Sent), "DEC-066: state Sent");
        assertEq(amountToArrive, BRIDGE_AMOUNT - BRIDGE_FEE, "DEC-162: the adapter's amount to arrive");
        assertEq(t.bridgeRef, bytes32(uint256(depositId)), "Across deposit id");
        assertEq(t.fillDeadline, block.timestamp + 6 hours, "DEC-066: 6 h fill deadline");
        _assertFundsDeposited(logs, t, depositId);

        assertEq(core.idle(), idleBefore - BRIDGE_AMOUNT);
        assertEq(core.inFlightValue(), amountToArrive, "DEC-085: In-flight Value at the amount that will arrive");
        assertEq(assetsBefore - core.shareAssets(), BRIDGE_FEE, "DEC-085: Share Assets drop by the bridge fee only");
        (, uint256 inFlightSent,, uint256 cap) = core.spokeCapUsage(0);
        assertEq(inFlightSent, BRIDGE_AMOUNT, "DEC-066 C1: the Spoke Cap counts the amount sent");
        assertEq(cap, SPOKE_CAP);
        assertEq(IERC20(ARB_USDC).allowance(address(core), ARB_ACROSS_SPOKE_POOL), 0, "DEC-087: approval reset");

        // The spoke swap minimum comes from the hub price source (USDG at 1:1, ruling 2026-09-29).
        spokeSwapMinWeth = _minWethFor(SPOKE_V4_USDG / 2);
    }

    /// @dev The Spoke Cap refuses a send above it; DEC-158: a manager who passes his own amount to arrive (a quote in
    ///      `bridgeData`) is refused by the Across adapter, so he cannot widen the gap a relayer keeps.
    function _assertSendRefusals() internal {
        uint256 above = BRIDGE_AMOUNT + 1e6;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeCapExceeded.selector, 0, 0, above, SPOKE_CAP));
        core.sendToSpoke(0, above, 0, "");

        vm.prank(manager);
        vm.expectRevert(AcrossBridgeAdapter.QuotesNotSupported.selector);
        core.sendToSpoke(0, BRIDGE_AMOUNT, 0, abi.encode(uint256(1)));
    }

    /// @dev The live SpokePool's `FundsDeposited`: destination, deposit id, the escrow as depositor, the vault-fixed
    ///      recipient, tokens, amounts and message (DEC-066, DEC-087).
    function _assertFundsDeposited(Vm.Log[] memory logs, Transit memory t, uint32 depositId) internal {
        (uint256 destination, uint256 id, bytes32 depositor, DepositData memory d) =
            _fundsDeposited(logs, ARB_ACROSS_SPOKE_POOL);
        assertEq(destination, ROBINHOOD);
        assertEq(id, depositId);
        assertEq(depositor, toUniversalAddress(t.escrow), "DEC-066: the per-send escrow is the depositor");
        assertEq(d.inputToken, toUniversalAddress(ARB_USDC));
        assertEq(d.outputToken, toUniversalAddress(RH_USDG));
        assertEq(d.inputAmount, BRIDGE_AMOUNT);
        assertEq(d.outputAmount, amountToArrive);
        assertEq(d.quoteTimestamp, block.timestamp);
        assertEq(d.fillDeadline, t.fillDeadline);
        assertEq(d.recipient, toUniversalAddress(address(spokeVault)), "DEC-087: the Mandate's Spoke Vault");
        (bytes32 messageFund, uint256 origin, bytes32 messageTransit, TransferKind kind) =
            TransitMessage.decode(d.message);
        assertEq(messageFund, fundId);
        assertEq(origin, ARBITRUM);
        assertEq(messageTransit, transitId);
        assertEq(uint8(kind), uint8(TransferKind.Principal));
        acrossMessage = d.message;
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Phase 5: the fill on Robinhood, a WETH/USDG position, fees, the report on the real Wormhole Core
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-090, OQ-01, OQ-09: the arrival is credited and recorded per transit id. DEC-096: it tops up Operating
    ///      Cash. DEC-070, DEC-086, DEC-093: the report is built from the ledger and published finalized.
    function _phase5FillPositionAndReport() internal {
        _onRobinhood();
        address vault = address(spokeVault);
        // Across fill as the fork suites simulate it: the output token reaches the recipient and the SpokePool calls
        // the handler with the deposit's message (docs/INTEGRATIONS.md).
        deal(RH_USDG, vault, IERC20(RH_USDG).balanceOf(vault) + amountToArrive);
        vm.prank(RH_ACROSS_SPOKE_POOL);
        spokeVault.handleV3AcrossMessage(RH_USDG, amountToArrive, relayer, acrossMessage);
        assertEq(SpokeVault(vault).arrivals(transitId), amountToArrive, "OQ-09: credited total per transit id");
        assertEq(spokeVault.cumulativeReceived(), amountToArrive);
        assertEq(spokeVault.operatingCash(), SPOKE_OPERATING_CASH_TOP_UP, "DEC-096: the arrival tops up Operating Cash");
        assertEq(spokeVault.unallocatedBalance(RH_USDG), amountToArrive - SPOKE_OPERATING_CASH_TOP_UP);

        _openSpokeUniswapPosition();
        robinhoodRouter = _deployRouter(RH_V4_POOL_MANAGER, RH_WETH, RH_USDG, 10_000e18, 50_000_000e6);
        _generateFees(
            robinhoodRouter, _spokePoolKey(), RH_V4_STATE_VIEW, _center(RH_V4_STATE_VIEW, RH_WETH_USDG_POOL_ID)
        );
        IAdapter.PositionValue memory v4 = IAdapter(spokeUniswap).positionValue(spokeUniswapPosition);
        assertGt(v4.income0, 0, "DEC-079: WETH fees on the spoke");
        assertGt(v4.income1, 0, "DEC-079: USDG fees on the spoke");

        _publishReport();
    }

    function _openSpokeUniswapPosition() internal {
        uint256 half = SPOKE_V4_USDG / 2;
        vm.prank(manager);
        uint256 weth = spokeVault.swapExactInput(
            spokeUniswap, RH_WETH_USDG_POOL_ID, RH_USDG, half, spokeSwapMinWeth, _swapParams()
        );
        int24 center = _center(RH_V4_STATE_VIEW, RH_WETH_USDG_POOL_ID);
        vm.prank(manager);
        (bytes32 key, uint256 used0, uint256 used1) =
            spokeVault.openPosition(spokeUniswap, RH_WETH_USDG_POOL_ID, weth, half, _openParams(center, weth, half));
        spokeUniswapPosition = key;
        assertGt(used0, 0);
        assertGt(used1, 0);
        assertEq(spokeVault.positions().length, 1);
    }

    /// @dev Security review S-14: the hub funds a spoke only once it accepted a report from it. The new Spoke Vault's
    ///      first (empty) report, published on the real Robinhood Core and delivered on the real Arbitrum Core.
    function _deliverFirstSpokeReport() internal {
        _onRobinhood();
        vm.recordLogs();
        spokeVault.report();
        VaaBody[] memory published = ICoreBridge(RH_WORMHOLE_CORE).fetchPublishedMessages(vm.getRecordedLogs());
        assertEq(published.length, 1);
        _onArbitrum();
        ICoreBridge arbitrumCore = ICoreBridge(ARB_WORMHOLE_CORE);
        arbitrumCore.setUpOverride();
        VaaEnvelope memory e = published[0].envelope;
        e.timestamp = uint32(block.timestamp);
        bytes memory vaa = VaaLib.encode(arbitrumCore.sign(VaaBody(e, published[0].payload)));
        (, uint64 reportSequence) = receiver.deliver(vaa);
        assertEq(reportSequence, 1, "S-14: the spoke's first report");
    }

    /// @dev `report()` publishes to the real Robinhood Core; the message is read back from the logs.
    function _publishReport() internal {
        vm.recordLogs();
        (uint64 sequence, uint64 wormholeSequence) = spokeVault.report();
        VaaBody[] memory published = ICoreBridge(RH_WORMHOLE_CORE).fetchPublishedMessages(vm.getRecordedLogs());
        assertEq(published.length, 1);
        VaaEnvelope memory e = published[0].envelope;
        assertEq(e.emitterChainId, WORMHOLE_ROBINHOOD, "DEC-086: Wormhole chain 72");
        assertEq(e.emitterAddress, toUniversalAddress(address(spokeVault)), "DEC-086: the Spoke Vault is the emitter");
        assertEq(e.sequence, wormholeSequence);
        assertEq(e.consistencyLevel, 1, "DEC-093: finalized");

        ReportCodec.Report memory r = ReportCodec.decode(published[0].payload);
        assertEq(sequence, 2);
        assertEq(r.sequence, 2, "DEC-093: the report after the spoke's first one (S-14)");
        assertEq(r.fundId, fundId);
        assertEq(r.spokeChainId, ROBINHOOD);
        assertEq(r.timestamp, block.timestamp);
        assertEq(r.arrivedTransits.length, 1);
        assertEq(r.arrivedTransits[0].transitId, transitId, "DEC-090: the arrival is listed by transit id");
        assertEq(r.arrivedTransits[0].amount, amountToArrive, "OQ-09: at its credited total");
        assertEq(r.cumulativeReceived, amountToArrive);
        assertEq(r.operatingCash, SPOKE_OPERATING_CASH_TOP_UP, "DEC-096: Operating Cash on its own line");
        assertEq(r.positions.length, 1);
        assertGt(r.positions[0].income0 + r.positions[0].income1, 0, "DEC-079: income apart from principal");
        assertEq(r.inFlightToHub.length, 0);
        publishedEnvelope = e;
        publishedPayload = published[0].payload;
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Phase 6: the VAA delivered on Arbitrum
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-086, DEC-093: the receiver verifies the guardian quorum (WormholeOverride on the real Arbitrum Core), the
    ///      emitter and the sequence. DEC-066, DEC-090: the listed arrival confirms the transit and it leaves In-flight
    ///      Value. Ruling 2026-09-29: the spoke's quantities are priced through Chainlink for WETH and 1:1 for USDG.
    function _phase6DeliverReport() internal {
        _onArbitrum();
        // The guardian override was set up in phase 4, when the spoke's first report was delivered (S-14).
        ICoreBridge arbitrumCore = ICoreBridge(ARB_WORMHOLE_CORE);
        uint256 assetsBefore = core.shareAssets();
        uint256 inFlightBefore = core.inFlightValue();
        assertEq(inFlightBefore, amountToArrive);

        // The VAA a guardian quorum signs for the published message: emitter chain 72, the Spoke Vault, finalized.
        VaaEnvelope memory e = VaaEnvelope(
            uint32(block.timestamp),
            publishedEnvelope.nonce,
            WORMHOLE_ROBINHOOD,
            toUniversalAddress(address(spokeVault)),
            publishedEnvelope.sequence,
            1
        );
        bytes memory vaa = VaaLib.encode(arbitrumCore.sign(VaaBody(e, publishedPayload)));
        vm.prank(makeAddr("anyone"));
        (uint256 spokeIndex, uint64 reportSequence) = receiver.deliver(vaa);
        assertEq(spokeIndex, 0);
        assertEq(reportSequence, 2);
        assertTrue(receiver.isReportFresh(0), "DEC-099: within the report lifetime");

        Transit memory t = core.transit(transitId);
        assertEq(uint8(t.state), uint8(TransitState.ArrivalConfirmed), "DEC-066, DEC-090: ArrivalConfirmed");
        assertEq(core.inFlightValue(), 0, "DEC-085: In-flight Value dropped");
        (uint256 spokeValue, uint256 inFlightSent,,) = core.spokeCapUsage(0);
        assertEq(inFlightSent, 0, "DEC-066: the Spoke Cap is released on arrival");

        _assertSpokePricing();
        (ReportCodec.Report memory r,,) = receiver.latestReport(0);
        uint256 spokePrincipal = _principalValue(r);
        assertEq(spokeValue, spokePrincipal);
        assertEq(core.shareAssets(), assetsBefore - inFlightBefore + spokePrincipal, "DEC-083: the spoke value entered");
        assertLt(spokePrincipal, amountToArrive, "DEC-096: Operating Cash and the swap's Market Costs left");
        assertGt(spokePrincipal, amountToArrive * 99 / 100);
        assertEq(core.shareAssets(), _sumOfBuckets(), "DEC-104: Share Assets is the sum of its buckets");
        assertGt(core.grossAssets(), core.shareAssets(), "DEC-098: Gross Assets add income and Operating Cash");
        emit log_named_decimal_uint("Share Price after the Robinhood report (USDC)", core.sharePrice(), 24);
    }

    /// @dev Ruling 2026-09-29 (Q57 b): Robinhood WETH through the ETH / USD feed, USDG at 1:1.
    function _assertSpokePricing() internal view {
        (, int256 answer,,,) = IChainlinkAggregatorV3(ARB_ETH_USD_FEED).latestRoundData();
        IPriceSource prices = IPriceSource(hubDeployment.priceSource);
        (uint256 weth,) = prices.priceInUsdc(RH_WETH);
        (uint256 usdg,) = prices.priceInUsdc(RH_USDG);
        assertEq(weth, Math.mulDiv(SafeCast.toUint256(answer), 1e24, 1e26), "Chainlink ETH / USD for WETH");
        assertEq(usdg, 1e18, "USDG at 1:1");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Phase 7: hub income collected and split, Bruno enters, Ana withdraws her income
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev Ruling 2026-09-29, DEC-107, DEC-109: the split happens when collected income reaches the Core Vault. DEC-014
    ///      (CS-OQ-1 stance): income is attributed at collection to the holders of that moment, so the income already
    ///      generated is collected before Bruno enters and he captures none of it. DEC-025, DEC-073: Income Withdrawal.
    function _phase7IncomeAndBrunoDeposit() internal {
        _onArbitrum();
        (uint256 netUsdc, uint256 netWeth) = _collectHubIncome();
        // DEC-014: the holders while it was earned, Ana and the manager's seed (DEC-127), pro rata to their shares.
        uint256 anaShares = IERC20(shareToken).balanceOf(ana);
        uint256 supply = IERC20(shareToken).totalSupply();
        assertEq(supply, MANAGER_SEED_SHARES + anaShares);
        assertApproxEqAbs(
            core.attributedIncome(ana, ARB_USDC),
            netUsdc * anaShares / supply,
            1,
            "DEC-014: Ana held while it was earned"
        );
        assertApproxEqAbs(core.attributedIncome(ana, ARB_WETH), netWeth * anaShares / supply, 1);

        _brunoDeposits();

        uint256 anaUsdc = core.attributedIncome(ana, ARB_USDC);
        uint256 anaWeth = core.attributedIncome(ana, ARB_WETH);
        uint256 usdcBefore = IERC20(ARB_USDC).balanceOf(ana);
        uint256 wethBefore = IERC20(ARB_WETH).balanceOf(ana);
        uint256 sharesBefore = IERC20(shareToken).balanceOf(ana);
        vm.startPrank(ana);
        assertEq(core.withdrawIncome(ARB_USDC), anaUsdc, "DEC-073: Income Withdrawal pays Attributed Income");
        assertEq(core.withdrawIncome(ARB_WETH), anaWeth);
        vm.stopPrank();
        assertEq(IERC20(ARB_USDC).balanceOf(ana) - usdcBefore, anaUsdc, "LC-143: no flow fee on Income Withdrawal");
        assertEq(IERC20(ARB_WETH).balanceOf(ana) - wethBefore, anaWeth, "DEC-109: paid in kind");
        assertEq(IERC20(shareToken).balanceOf(ana), sharesBefore, "DEC-025: no share is burned");
        assertEq(core.attributedIncome(ana, ARB_USDC), 0);
        vm.prank(bruno);
        assertEq(core.withdrawIncome(ARB_USDC), 0, "DEC-014: Bruno has nothing to withdraw");
    }

    /// @dev DEC-092: collecting moves income from the positions to the collected bucket and never touches Share Assets.
    function _collectHubIncome() internal returns (uint256 netUsdc, uint256 netWeth) {
        uint256 assetsBefore = core.shareAssets();
        vm.startPrank(manager);
        IAdapter.Amounts memory v4 = hubSpoke.collectIncome(hubUniswap, hubUniswapPosition);
        IAdapter.Amounts memory aave = hubSpoke.collectIncome(hubAave, hubAavePosition);
        vm.stopPrank();
        assertGt(v4.income0, 0);
        assertGt(v4.income1, 0);
        assertGt(aave.income0, 0, "DEC-068: Aave interest collected");
        uint256 usdcIncome = hubSpoke.collectedIncome(ARB_USDC);
        uint256 wethIncome = hubSpoke.collectedIncome(ARB_WETH);
        assertEq(usdcIncome, v4.income1 + aave.income0);
        assertEq(wethIncome, v4.income0);
        // AAVE-3: Aave's scaled rounding is borne by principal, at most a unit per operation.
        assertApproxEqAbs(core.shareAssets(), assetsBefore, 2, "DEC-092: collection leaves Share Assets");

        assertEq(IManagerRegistry(hubDeployment.managerRegistry).protocolSliceBps(manager), 5000, "DEC-106: 50% slice");
        netUsdc = _forwardAndAssertSplit(ARB_USDC, usdcIncome);
        netWeth = _forwardAndAssertSplit(ARB_WETH, wethIncome);
    }

    /// @dev DEC-107: 20% performance fee on the collected amount; DEC-106, DEC-110: half of it to the Protocol
    ///      Recipient; DEC-109: the rest of the fee to the ManagerFeeVault, in kind, at once; the net to the holders.
    function _forwardAndAssertSplit(address token, uint256 amount) internal returns (uint256 net) {
        uint256 fee = amount * PERFORMANCE_FEE_BPS / 10_000;
        uint256 slice = fee * 5000 / 10_000;
        net = amount - fee;
        uint256 recipientBefore = IERC20(token).balanceOf(recipient);
        uint256 feeVaultBefore = IERC20(token).balanceOf(managerFeeVault);
        uint256 collectedBefore = core.collectedIncome(token);
        vm.prank(makeAddr("anyone"));
        assertEq(hubSpoke.forwardIncomeToCoreVault(token), amount, "permissionless forward");
        assertEq(IERC20(token).balanceOf(recipient) - recipientBefore, slice, "DEC-106: protocol slice");
        assertEq(IERC20(token).balanceOf(managerFeeVault) - feeVaultBefore, fee - slice, "DEC-109: ManagerFeeVault");
        assertEq(core.collectedIncome(token) - collectedBefore, net, "ruling 2026-09-29: the net to the accumulator");
    }

    /// @dev DEC-014: Bruno enters at the Share Price that excludes every income bucket (DEC-092) and owes nothing of
    ///      the income collected before him. DEC-035, DEC-061: whole shares, the rest stays in his wallet. Q57 reading,
    ///      OQ-10: a mint needs a fresh report and fresh prices.
    function _brunoDeposits() internal {
        _refreshEthUsdFeed();
        uint256 price = core.sharePrice();
        uint256 assetsBefore = core.shareAssets();
        uint256 anaUsdc = core.attributedIncome(ana, ARB_USDC);
        deal(ARB_USDC, bruno, BRUNO_DEPOSIT);
        vm.startPrank(bruno);
        IERC20(ARB_USDC).approve(address(core), BRUNO_DEPOSIT);
        (uint256 shares, uint256 charged) = core.deposit(BRUNO_DEPOSIT, 0);
        vm.stopPrank();

        (uint256 expectedShares, uint256 forShares, uint256 fee) =
            ShareMath.previewDeposit(BRUNO_DEPOSIT, FLOW_FEE_BPS, price);
        assertEq(shares, expectedShares, "DEC-035: whole shares at the new Share Price");
        assertEq(shares % 1e18, 0);
        assertEq(charged, forShares + fee);
        assertEq(IERC20(ARB_USDC).balanceOf(bruno), BRUNO_DEPOSIT - charged, "DEC-061: the remainder stays");
        assertEq(core.shareAssets(), assetsBefore + forShares);
        assertApproxEqAbs(core.sharePrice(), price, price / 1e9, "DEC-061: rounding only");
        assertEq(core.attributedIncome(bruno, ARB_USDC), 0, "DEC-014: none of the income already generated");
        assertEq(core.attributedIncome(bruno, ARB_WETH), 0, "DEC-014: none of the income already generated");
        assertEq(core.attributedIncome(ana, ARB_USDC), anaUsdc, "DEC-014: Ana keeps hers");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Phase 8: Ana's Standard Payout of 3,000 USDC
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-072, DEC-095: Standard reserves the amount in the Payout Reserve. DEC-060, DEC-067: after the term it is
    ///      paid from Idle. DEC-077: shares rounded down, the payout never above the request. DEC-105: one Share Price.
    ///      DEC-106: flow fee on the amount paid. DEC-024: one request, closed by the claim.
    function _phase8AnaStandardPayout() internal {
        _onArbitrum();
        uint256 idleBefore = core.idle();
        vm.prank(ana);
        core.requestPayout(ANA_PAYOUT, ICoreVaultPayouts.PayoutMode.Standard);
        ICoreVault.PayoutRequest memory req = core.payoutRequest(ana);
        assertEq(req.reserved, ANA_PAYOUT, "DEC-072: reserved as USDC");
        assertEq(core.payoutReserve(), ANA_PAYOUT);
        assertEq(req.termEndsAt, block.timestamp + 72 hours, "DEC-060: 72 h term");
        assertEq(IERC20(shareToken).balanceOf(ana), 9975e18, "DEC-077: nothing burned at request");
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.PayoutTermNotEnded.selector, req.termEndsAt));
        core.claimPayout("");

        _advance(72 hours);
        uint256 price = core.sharePrice();
        uint256 shares = ShareMath.sharesToBurn(ANA_PAYOUT, price);
        uint256 gross = ShareMath.usdcFor(shares, price);
        uint256 recipientBefore = IERC20(ARB_USDC).balanceOf(recipient);
        uint256 anaBefore = IERC20(ARB_USDC).balanceOf(ana);
        vm.prank(ana);
        ICoreVault.PayoutReceipt memory receipt = core.claimPayout("");

        assertEq(receipt.sharePrice, price, "DEC-105: one Share Price");
        assertEq(receipt.sharesBurned, shares, "DEC-077: whole shares rounded down");
        assertEq(receipt.usdcGross, gross);
        assertLe(gross, ANA_PAYOUT, "DEC-077: never above the request");
        assertEq(receipt.unwindProceeds, 0, "DEC-067: Idle paid");
        assertEq(receipt.payoutFee, 0, "DEC-102: no Payout Fee on a Standard Payout");
        assertEq(receipt.flowFee, ShareMath.flowFee(gross, FLOW_FEE_BPS), "DEC-106: flow fee on the amount paid");
        assertEq(receipt.usdcPaid, gross - receipt.flowFee);
        assertEq(receipt.usdcOutstanding, 0);
        assertEq(IERC20(ARB_USDC).balanceOf(ana) - anaBefore, receipt.usdcPaid);
        assertEq(IERC20(ARB_USDC).balanceOf(recipient) - recipientBefore, receipt.flowFee);
        assertEq(IERC20(shareToken).balanceOf(ana), 9975e18 - shares);
        assertEq(core.idle(), idleBefore - gross);
        assertEq(core.payoutReserve(), 0, "DEC-072: reserve released");
        assertFalse(core.payoutRequest(ana).open, "DEC-024: request closed");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Phase 9: Bruno's Instant Payout above Free Idle, with an automatic unwind
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice Values read before Bruno's claim.
    struct InstantPlan {
        uint256 request;
        uint256 balance;
        uint256 target;
        uint256 supply;
        uint256 operatingCash;
        uint256 aavePrincipal;
        uint256 brunoUsdc;
        uint256 hubUnallocated;
        uint256 v4Value;
        uint128 v4Liquidity;
    }

    /// @dev DEC-068: Partial Payout when the unwind falls short. DEC-069: Mandate order, hub V4 first. DEC-059: the Aave
    ///      Exact-Value Position is read, not exited, when V4 covers the target. DEC-081: shortfall plus 2%. DEC-097:
    ///      the margin's Market Costs are the fund's. DEC-102: 2% Payout Fee into Operating Cash. DEC-105: the burn at
    ///      the Share Price read after the unwind; the Settlement Price is recorded only.
    function _phase9BrunoInstantPayoutWithUnwind() internal {
        _onArbitrum();
        InstantPlan memory plan = _planInstant();
        vm.prank(bruno);
        core.requestPayout(plan.request, ICoreVaultPayouts.PayoutMode.Instant);
        assertEq(core.payoutRequest(bruno).reserved, 0, "DEC-095: no reserve for an Instant Payout");

        bytes memory hints = _unwindHints(plan.target);
        vm.recordLogs();
        vm.prank(bruno);
        ICoreVault.PayoutReceipt memory receipt = core.claimPayout(hints);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 target, uint256 proceeds) = _unwound(logs);
        assertEq(target, plan.target, "DEC-081: the shortfall plus 2%");
        assertEq(proceeds, receipt.unwindProceeds, "DEC-080: proceeds reached Idle through returnToIdle");
        assertGt(proceeds, 0);
        _assertHubV4UnwoundFirst(plan, target);

        assertEq(receipt.totalShares, plan.supply);
        assertEq(receipt.sharePrice, ShareMath.sharePrice(receipt.shareAssets, receipt.totalShares), "DEC-105");
        assertEq(receipt.usdcGross, ShareMath.usdcFor(receipt.sharesBurned, receipt.sharePrice));
        assertEq(receipt.payoutFee, ShareMath.bpsOf(receipt.usdcGross, 200), "DEC-102: 2% Payout Fee");
        assertEq(core.operatingCash(), plan.operatingCash, "DEC-144: the Payout Fee stays in Idle");
        assertEq(receipt.flowFee, ShareMath.flowFee(receipt.usdcGross, FLOW_FEE_BPS), "DEC-106");
        assertEq(receipt.usdcPaid, receipt.usdcGross - receipt.payoutFee - receipt.flowFee);
        assertEq(IERC20(ARB_USDC).balanceOf(bruno) - plan.brunoUsdc, receipt.usdcPaid);
        assertEq(
            receipt.payoutSettlementPrice,
            Math.mulDiv(proceeds, 1e36, receipt.sharesBurned),
            "DEC-084, DEC-105: Settlement Price recorded only"
        );
        assertEq(IERC20(shareToken).balanceOf(bruno), plan.balance - receipt.sharesBurned);
        _assertPayoutOutcome(plan, receipt);
        emit log_named_decimal_uint("Instant Payout unwind target (USDC)", target, 6);
        emit log_named_decimal_uint("Instant Payout outstanding after the claim (USDC)", receipt.usdcOutstanding, 6);
    }

    /// @dev Bruno asks 1,000 USDC more than Free Idle; the expected unwind target is read at the pre-claim price.
    function _planInstant() internal view returns (InstantPlan memory plan) {
        uint256 free = core.freeIdle();
        uint256 price = core.sharePrice();
        plan.request = free + BRUNO_ABOVE_FREE_IDLE;
        plan.balance = IERC20(shareToken).balanceOf(bruno);
        assertGt(ShareMath.usdcFor(plan.balance, price), plan.request, "Bruno holds more than he asks");
        uint256 wanted = ShareMath.usdcFor(Math.min(ShareMath.sharesToBurn(plan.request, price), plan.balance), price);
        uint256 shortfall = wanted - free;
        plan.target = shortfall + shortfall * 200 / 10_000;
        plan.supply = IERC20(shareToken).totalSupply();
        plan.operatingCash = core.operatingCash();
        plan.aavePrincipal = IAdapter(hubAave).positionValue(hubAavePosition).principal0;
        plan.brunoUsdc = IERC20(ARB_USDC).balanceOf(bruno);
        plan.hubUnallocated = hubSpoke.unallocatedBalance(ARB_USDC);
        IAdapter.PositionValue memory v4 = IAdapter(hubUniswap).positionValue(hubUniswapPosition);
        plan.v4Value = _spotValue(v4);
        plan.v4Liquidity = v4.liquidity;
    }

    /// @dev WETH/USDC principal of a hub V4 position at the pool's spot price, as the Spoke Vault values an unwind step
    ///      (final verification): USDC at par, WETH through `IAdapter.spotQuote`.
    function _spotValue(IAdapter.PositionValue memory v4) internal view returns (uint256) {
        return v4.principal1 + IAdapter(hubUniswap).spotQuote(ARB_WETH_USDC_POOL_ID, ARB_WETH, v4.principal0);
    }

    /// @dev DEC-069: the hub V4 position is first in Mandate order. Final verification: the vault closes it only when
    ///      its whole value is needed, otherwise it decreases only the share the shortfall needs; the Aave Exact-Value
    ///      Position is read (DEC-059) and covers at most what the V4 swap fell short of the spot value (Market Costs,
    ///      DEC-097), since the stop condition is re-evaluated after every step.
    function _assertHubV4UnwoundFirst(InstantPlan memory plan, uint256 target) internal view {
        ISpokeVault.PositionRef[] memory p = hubSpoke.positions();
        uint256 shortfall = target - plan.hubUnallocated;
        if (plan.v4Value <= shortfall) {
            assertEq(p.length, 1, "DEC-069: the whole V4 value was needed, so it closed first");
            assertEq(p[0].adapter, hubAave);
        } else {
            assertEq(p.length, 2, "final verification: the V4 position was only decreased");
            assertLt(
                IAdapter(hubUniswap).positionValue(hubUniswapPosition).liquidity,
                plan.v4Liquidity,
                "DEC-069: the hub V4 position was unwound first, by the shortfall only"
            );
        }
        uint256 aaveAfter = IAdapter(hubAave).positionValue(hubAavePosition).principal0;
        assertLe(aaveAfter, plan.aavePrincipal);
        assertLe(
            plan.aavePrincipal - aaveAfter,
            shortfall * SWAP_TOLERANCE_BPS / 10_000,
            "DEC-059: Aave covers at most what the V4 swap fell short"
        );
    }

    /// @dev One hint per position the unwind may visit, in Mandate order (DEC-069). Final verification: the vault
    ///      sizes the exits itself, so a hint only tightens a swap: here the V4 step's WETH swap gets a Chainlink-based
    ///      minimum for the WETH the vault will take out (the whole position, or the share the shortfall needs),
    ///      stricter than the vault's own floor (spot less MAX_UNWIND_SLIPPAGE_BPS); Aave needs no hint.
    function _unwindHints(uint256 target) internal view returns (bytes memory) {
        IAdapter.PositionValue memory v4 = IAdapter(hubUniswap).positionValue(hubUniswapPosition);
        uint256 held = hubSpoke.unallocatedBalance(ARB_USDC);
        uint256 shortfall = target > held ? target - held : 0;
        uint256 value = _spotValue(v4);
        uint256 wethOut = value <= shortfall ? v4.principal0 : Math.mulDiv(v4.principal0, shortfall, value);
        SpokeVaultTypes.UnwindSwap[] memory swaps = new SpokeVaultTypes.UnwindSwap[](1);
        swaps[0] = SpokeVaultTypes.UnwindSwap({
            adapter: hubUniswap,
            poolKey: ARB_WETH_USDC_POOL_ID,
            tokenIn: ARB_WETH,
            minAmountOut: _usdcValue(ARB_WETH, wethOut) * (10_000 - SWAP_TOLERANCE_BPS) / 10_000,
            params: _swapParams()
        });
        SpokeVaultTypes.UnwindHint[] memory hints = new SpokeVaultTypes.UnwindHint[](2);
        hints[0] = SpokeVaultTypes.UnwindHint({swaps: swaps});
        hints[1] = SpokeVaultTypes.UnwindHint({swaps: new SpokeVaultTypes.UnwindSwap[](0)});
        return abi.encode(hints);
    }

    function _unwound(Vm.Log[] memory logs) internal view returns (uint256 target, uint256 proceeds) {
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(hubSpoke) || logs[i].topics[0] != ISpokeVaultUnwind.UnwoundForPayout.selector
            ) {
                continue;
            }
            ++seen;
            (target, proceeds) = abi.decode(logs[i].data, (uint256, uint256));
        }
        assertEq(seen, 1, "one automatic unwind");
    }

    /// @dev DEC-068: a full Payout closes the request; a Partial Payout burns only what was paid and leaves the rest of
    ///      the request open.
    function _assertPayoutOutcome(InstantPlan memory plan, ICoreVault.PayoutReceipt memory receipt) internal view {
        ICoreVault.PayoutRequest memory req = core.payoutRequest(bruno);
        if (receipt.usdcOutstanding == 0) {
            assertFalse(req.open, "DEC-074: the Payout closed the request");
            assertEq(
                receipt.sharesBurned,
                Math.min(ShareMath.sharesToBurn(plan.request, receipt.sharePrice), plan.balance),
                "DEC-077: rounded down at the consolidated price"
            );
        } else {
            assertTrue(req.open, "DEC-068: Partial Payout leaves the request open");
            assertEq(req.usdcOutstanding, plan.request - receipt.usdcGross, "DEC-068: the rest stays open");
            assertEq(receipt.usdcOutstanding, req.usdcOutstanding);
        }
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Phase 10: invariants
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-072: the Payout Reserve never exceeds Idle. DEC-091: whole shares only. DEC-104: Share Assets is the sum
    ///      of its buckets. DEC-080: a donation reaches no base, leaves the Share Price and is swept.
    function _phase10Invariants() internal {
        _onArbitrum();
        assertLe(core.payoutReserve(), core.idle(), "DEC-072: Payout Reserve <= Idle");
        assertEq(IERC20(shareToken).totalSupply() % 1e18, 0, "DEC-091: totalSupply is whole shares");
        assertEq(core.shareAssets(), _sumOfBuckets(), "DEC-104: Share Assets equals the sum of buckets");
        assertEq(core.sweepExcess(ARB_USDC), 0, "DEC-080: the ledger covers every unit held");

        uint256 price = core.sharePrice();
        uint256 idleBefore = core.idle();
        uint256 recipientBefore = IERC20(ARB_USDC).balanceOf(recipient);
        deal(ARB_USDC, address(core), IERC20(ARB_USDC).balanceOf(address(core)) + DONATION);
        assertEq(core.sharePrice(), price, "DEC-080: a donation never moves the Share Price");
        assertEq(core.idle(), idleBefore, "DEC-080: nor Idle");
        assertEq(core.excessRecipient(), recipient);
        assertEq(core.sweepExcess(ARB_USDC), DONATION, "DEC-080, DEC-101: swept by the garbage collector");
        assertEq(IERC20(ARB_USDC).balanceOf(recipient) - recipientBefore, DONATION);
        assertEq(core.sharePrice(), price);
        assertEq(core.shareAssets(), _sumOfBuckets());
    }
}

/// @notice The ten phases in order, one fund from creation to the value-base invariants.
contract EndToEndForkTest is EndToEndScenario {
    /// @notice DEC-054 end to end: create, deposit, allocate, bridge, fill, report, deliver, deposit again, collect,
    ///         pay out (Standard, then Instant with an unwind) and the value-base invariants at the end.
    function test_DEC054_forkEndToEndOneFundAcrossArbitrumAndRobinhood() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();
        _phase4SendToRobinhood();
        _phase5FillPositionAndReport();
        _phase6DeliverReport();
        _phase7IncomeAndBrunoDeposit();
        _phase8AnaStandardPayout();
        _phase9BrunoInstantPayoutWithUnwind();
        _phase10Invariants();
    }
}
