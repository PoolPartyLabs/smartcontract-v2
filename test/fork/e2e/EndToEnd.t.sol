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
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {IManagerRegistry} from "../../../src/interfaces/IManagerRegistry.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {IChainlinkAggregatorV3} from "../../../src/interfaces/external/IChainlinkAggregatorV3.sol";
import {Transit, TransitState, TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
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
contract EndToEndForkTest is EndToEndBase {
    using AdvancedWormholeOverride for ICoreBridge;

    uint256 internal constant ANA_BELOW_MINIMUM = MIN_FIRST_DEPOSIT - 1;
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

    /// @notice DEC-054 end to end: create, deposit, allocate, bridge, fill, report, deliver, deposit again, collect,
    ///         pay out (Standard, then Instant with an unwind) and the value-base invariants at the end.
    function test_DEC054_forkEndToEndOneFundAcrossArbitrumAndRobinhood() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();
        _phase4SendToRobinhood();
    }

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

        IFundFactory.HubParams memory p =
            _hubParams(creationNumber, _plan(), _coreVaultCreationCode(hubDeployment.coreVaultLogic));
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
        assertEq(m.unwindOrder.length, 2, "feedback question 2: automatic unwind on hub positions only");
        assertEq(m.unwindOrder[0].adapter, hubUni, "DEC-069: hub Uniswap V4 first");
        assertEq(m.unwindOrder[1].adapter, hubAaveAdapter, "DEC-069: then Aave");
        assertEq(m.bridgeAdapters.length, 2, "DEC-088: Across on both sides");
        assertEq(m.bridgeAdapters[0].adapter, predicted.chains[0].acrossBridgeAdapter);
        assertEq(m.bridgeAdapters[1].adapter, predicted.chains[1].acrossBridgeAdapter);
        assertEq(m.payoutFeeBps, 200, "DEC-102: Payout Fee 2%");
        assertEq(m.standardPayoutTerm, 72 hours, "DEC-060: 72 h term");
        assertEq(m.minFirstDeposit, 100e6, "DEC-061: 100 USDC minimum first deposit");
        assertEq(m.performanceFeeBps, 2000, "DEC-107: performance fee 20%");
        assertEq(m.managementFeeBps, 0, "DEC-108: management fee 0");
        assertEq(m.maxBridgeFeeBps, BRIDGE_FEE * 10_000 / BRIDGE_AMOUNT, "QA19: from the quote used (1.60 on 4,000)");
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

    /// @dev DEC-061: first deposit at least the Mandate minimum, first price 1.00. DEC-106: 25 bps flow fee to the
    ///      Protocol Recipient, taken before pricing. DEC-035: whole shares only.
    function _phase2AnaDeposits() internal {
        _onArbitrum();
        deal(ARB_USDC, ana, ANA_DEPOSIT);
        vm.startPrank(ana);
        IERC20(ARB_USDC).approve(address(core), ANA_DEPOSIT);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVault.BelowMinFirstDeposit.selector, ANA_BELOW_MINIMUM, MIN_FIRST_DEPOSIT)
        );
        core.deposit(ANA_BELOW_MINIMUM, 0);
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
        assertEq(core.idle(), ANA_DEPOSIT - fee);
        assertEq(core.shareAssets(), ANA_DEPOSIT - fee);
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

    /// @dev DEC-037, DEC-095: the Spoke Cap bounds the send. QA19: the quote's fee within `maxBridgeFeeBps`. DEC-066: a
    ///      per-send escrow is the depositor. DEC-085: Share Assets count the transit at the amount that will arrive.
    ///      DEC-087: the vault fixes recipient, token pair and message.
    function _phase4SendToRobinhood() internal {
        _onArbitrum();
        BridgeQuote memory quote = BridgeQuote(BRIDGE_AMOUNT - BRIDGE_FEE, uint32(block.timestamp), 0, address(0));
        _assertSendRefusals(quote);

        uint256 assetsBefore = core.shareAssets();
        uint256 idleBefore = core.idle();
        uint32 depositId = IAcrossSpokePool(ARB_ACROSS_SPOKE_POOL).numberOfDeposits();
        vm.recordLogs();
        vm.prank(manager);
        transitId = core.sendToSpoke(0, BRIDGE_AMOUNT, 0, quote);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Transit memory t = core.transit(transitId);
        amountToArrive = t.amountToArrive;
        assertEq(uint8(t.state), uint8(TransitState.Sent), "DEC-066: state Sent");
        assertEq(amountToArrive, BRIDGE_AMOUNT - BRIDGE_FEE, "DEC-085: the quote's outputAmount");
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

    function _assertSendRefusals(BridgeQuote memory quote) internal {
        uint256 above = BRIDGE_AMOUNT + 1e6;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeCapExceeded.selector, 0, 0, above, SPOKE_CAP));
        core.sendToSpoke(0, above, 0, BridgeQuote(above - BRIDGE_FEE, quote.quoteTimestamp, 0, address(0)));

        BridgeQuote memory greedy = BridgeQuote(quote.outputAmount - 1, quote.quoteTimestamp, 0, address(0));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BridgeFeeAboveMax.selector, BRIDGE_FEE + 1, BRIDGE_FEE));
        core.sendToSpoke(0, BRIDGE_AMOUNT, 0, greedy);
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
}
