// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ICoreVaultIncome} from "../../../src/interfaces/ICoreVaultIncome.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {ManagerFeeVault} from "../../../src/core/ManagerFeeVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {SpokeIncomeTypes} from "../../../src/spoke/SpokeIncomeTypes.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {PayoutCalls} from "../../utils/PayoutCalls.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice Attributed Income in the Hub dollar index (DEC-161; checklist doc 10): recognition at every mint, burn and
///         accepted report (DEC-117, DEC-138), conversion at each collection's rate per token, the fee paid in USDC at
///         the collection to the DEC-128 item 4 destinations, the collection on every chain (DEC-122, DEC-124, DEC-172)
///         and Income Withdrawal in USDC.
/// @dev The worked examples are doc 10 section 4's with the fund's performance fee of 10% (DEC-184's floor) taken at
///      recognition (DEC-117 item 3): every holder's dollars are the document's times 0.9. "Ana" is the manager (her
///      seed share plus 99), so Ana and Bruno hold 100 shares each as in the document. No flow fee (DEC-106 predates the
///      example; it never touches income, DEC-113).
contract CoreVaultIncomeTest is CoreVaultFixture {
    using stdStorage for StdStorage;
    address internal caio = makeAddr("caio");
    ManagerFeeVault internal feeVault;

    function setUp() public override {
        super.setUp();
        _deployAtMinimumFees();
        feeVault = ManagerFeeVault(vault.managerFeeVault());
        _deposit(manager, 99e6); // Ana: 100 shares with the seed's one
        _deposit(bruno, 100e6);
        _deliver(_spokeReport(0, 0));
        vm.warp(block.timestamp + 1);
        _deliver(_spokeReport(0, 0));
        deal(address(usdc), protocol, 0);
    }

    /// @dev Sells WETH at `usdcPerWeth` (whole USDC) in the hub mock's collections.
    function _wethAt(uint256 usdcPerWeth) internal {
        hubVault.setSaleRate(address(weth), usdcPerWeth * 1e6, 1e18);
    }

    function _withdraw(address who) internal returns (uint256) {
        vm.prank(who);
        return vault.withdrawIncome();
    }

    function _request(address who) internal returns (uint64) {
        vm.prank(who);
        return vault.requestIncomeWithdrawal(0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Doc 10 section 4: the worked examples (DEC-161)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Two collections at different prices: 0.10 WETH sold at 2,660 then 0.04 WETH at 2,800. The dollar index
    ///      keeps Bruno's 133 (here 119.70) from the first collection while Ana withdraws, and adds 56 (50.40) each.
    function test_DEC161_twoCollectionsAtDifferentPricesKeepEachShare() public {
        _earnHubIncome(address(weth), 0.1e18);
        _wethAt(2660);
        assertEq(_withdraw(manager), 0, "nothing converted before the collection");
        _request(manager); // Ana asks: the collection sells 0.10 WETH for 266 USDC
        assertApproxEqAbs(_withdraw(manager), 119.7e6, 1, "Ana: 133 x 0.9");
        assertApproxEqAbs(_incomeOf(bruno), 119.7e6, 1, "Bruno's 133 x 0.9 stay on the Hub in his name");

        _earnHubIncome(address(weth), 0.04e18);
        _wethAt(2800);
        _request(bruno);
        assertApproxEqAbs(_withdraw(bruno), 170.1e6, 2, "Bruno: (133 + 56) x 0.9");
        assertApproxEqAbs(_incomeOf(manager), 50.4e6, 1, "Ana: 56 x 0.9");

        // The fee is one more owner at the same rates (D-40): 10% of each sale, paid in USDC, half to each.
        uint256 fee = 26.6e6 + 11.2e6;
        assertEq(usdc.balanceOf(protocol), fee / 2, "the protocol slice (DEC-106 default 50%)");
        assertEq(usdc.balanceOf(address(feeVault)), fee / 2, "the manager's part in the ManagerFeeVault");
        assertEq(weth.balanceOf(address(feeVault)), 0, "DEC-124 item 2: fees are paid in dollars only");
    }

    /// @dev Who enters mid-interval: 0.02 WETH before Caio's 100 shares, 0.03 after, the collection sells 0.05 at
    ///      2,800 (140 USDC): Ana and Bruno 56 each, Caio 28 (times 0.9).
    function test_DEC014_anEntrantTakesNothingOfTheIntervalBeforeItsMint() public {
        _earnHubIncome(address(weth), 0.02e18);
        _deposit(caio, 100e6); // the mint's valuation recognizes the 0.02 for Ana and Bruno (DEC-138)
        assertEq(vault.unconvertedIncome(caio, 0, address(weth)), 0, "none of the WETH earned before");
        assertApproxEqAbs(vault.unconvertedIncome(manager, 0, address(weth)), 0.009e18, 1);
        _earnHubIncome(address(weth), 0.03e18);
        _wethAt(2800);
        _request(caio);
        assertApproxEqAbs(_incomeOf(manager), 50.4e6, 1, "Ana: 56 x 0.9");
        assertApproxEqAbs(_incomeOf(bruno), 50.4e6, 1, "Bruno: 56 x 0.9");
        assertApproxEqAbs(_incomeOf(caio), 25.2e6, 1, "Caio: 28 x 0.9");
    }

    /// @dev DEC-161 item 2: Caio's adjustment of the 2,800 collection is converted at 2,800 even when he comes back
    ///      after two more collections at 3,000 and 2,500.
    function test_DEC161_aLateHolderIsConvertedAtTheRateOfItsOwnInterval() public {
        _earnHubIncome(address(weth), 0.02e18);
        _deposit(caio, 100e6);
        _earnHubIncome(address(weth), 0.03e18);
        _wethAt(2800);
        _request(manager);
        _earnHubIncome(address(weth), 0.03e18); // 0.0001 a share for all 300
        _wethAt(3000);
        _request(manager);
        _earnHubIncome(address(weth), 0.03e18);
        _wethAt(2500);
        _request(manager);
        // 28 + 100 x 0.0001 x 3,000 + 100 x 0.0001 x 2,500 = 83, times 0.9.
        assertApproxEqAbs(_withdraw(caio), 74.7e6, 3, "the 2,800 rate for the first interval");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Recognition (DEC-117, DEC-138)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC138_hubIncomeIsRecognizedAtEveryMintAndBurn() public {
        _earnHubIncome(address(usdc), 100e6);
        _deposit(caio, 50e6);
        ICoreVaultIncome.IncomeTokenState memory t = vault.incomeToken(0, address(usdc));
        assertEq(t.counter, 100e6, "the hub counter is the last recognized");
        assertEq(t.recognized, 90e6, "the net enters the open interval");
        assertEq(t.feeUnits, 10e6, "the fee is owed in token units until the collection (D-40)");

        _earnHubIncome(address(usdc), 10e6);
        PayoutCalls.request(vault, bruno, 10e6, ICoreVaultPayouts.PayoutMode.Instant);
        assertEq(vault.incomeToken(0, address(usdc)).counter, 110e6, "the burn's valuation recognized it too");
    }

    function test_DEC117_aFailedHubReadKeepsTheLastCounterAndNeverBlocksABurn() public {
        _earnHubIncome(address(usdc), 100e6);
        hubVault.setBuildReverts(true);
        PayoutCalls.request(vault, bruno, 10e6, ICoreVaultPayouts.PayoutMode.Instant);
        assertEq(vault.incomeToken(0, address(usdc)).counter, 0, "nothing recognized on a failed read");
        hubVault.setBuildReverts(false);
        _deposit(caio, 10e6);
        assertEq(vault.incomeToken(0, address(usdc)).counter, 100e6, "the next read recognizes the whole advance");
    }

    function test_Q60_aRegressedCounterIsSkippedWithAnEvent() public {
        hubVault.setCumulativeIncome(address(usdc), 100e6);
        _deposit(caio, 10e6);
        hubVault.setCumulativeIncome(address(usdc), 50e6);
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.IncomeCounterSkipped(0, address(usdc), 100e6, 50e6);
        _collectHubIncome();
        _deposit(caio, 10e6);
        assertEq(vault.incomeToken(0, address(usdc)).counter, 100e6);
    }

    /// @dev DEC-110 ("settling what accrued first"): the Hub income earned before a decrease is recognized at the old
    ///      performance fee, the income earned after it at the new one.
    function test_DEC110_aDecreaseRecognizesTheHubIncomeAtTheOldFee() public {
        CoreVaultFixture.setUp();
        vault = _deploy(_mandate(2000), _config(0));
        deal(address(usdc), protocol, 0);
        feeVault = ManagerFeeVault(vault.managerFeeVault());
        _deposit(bruno, 100e6);
        _earnHubIncome(address(usdc), 1000e6);
        vm.prank(manager);
        vault.decreaseManagerFee(1000, 0);
        _earnHubIncome(address(usdc), 1000e6);
        _collectHubIncome();
        assertEq(usdc.balanceOf(protocol) + usdc.balanceOf(address(feeVault)), 200e6 + 100e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fees at the collection (DEC-112, DEC-124 item 2, DEC-128 item 4)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC128_feePaidInUsdcAtTheCollectionToBothDestinations() public {
        registry.setSlice(500);
        _earnHubIncome(address(weth), 1e18);
        _wethAt(2000);
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.IncomeCollectionClosed(0, bytes32(0), 2000e6, 1800e6, 200e6, 10e6, 500);
        _collectHubIncome();
        assertEq(usdc.balanceOf(protocol), 10e6, "5% of the fee to the Protocol Recipient");
        assertEq(usdc.balanceOf(address(feeVault)), 190e6, "the rest to the ManagerFeeVault");

        registry.setSlice(5000);
        _earnHubIncome(address(weth), 1e18);
        _collectHubIncome();
        assertEq(usdc.balanceOf(protocol), 10e6 + 100e6, "50% of the next fee");
        assertEq(usdc.balanceOf(address(feeVault)), 190e6 + 100e6);
    }

    function test_DEC112_theSliceIsClampedToFiveAndFiftyPercent() public {
        registry.setSlice(0);
        _hubIncomeCollected(address(usdc), 1000e6);
        assertEq(usdc.balanceOf(protocol), 5e6, "never 0: 5% of the 100 fee");
        registry.setSlice(9000);
        _hubIncomeCollected(address(usdc), 1000e6);
        assertEq(usdc.balanceOf(protocol), 5e6 + 50e6, "at most 50%");
        registry.setReverts(true);
        _hubIncomeCollected(address(usdc), 1000e6);
        assertEq(usdc.balanceOf(protocol), 5e6 + 50e6 + 50e6, "DEC-106 default when the registry fails");
    }

    function test_S12_aFeeTransferThatFailsIsOwed() public {
        vm.mockCallRevert(address(usdc), abi.encodeCall(IERC20.transfer, (address(feeVault), 50e6)), "blocklisted");
        _hubIncomeCollected(address(usdc), 1000e6);
        assertEq(vault.owedFees(address(usdc), address(feeVault)), 50e6, "the manager part waits, owed");
        assertEq(
            usdc.balanceOf(address(vault)), _ledgerUsdc() + 50e6, "everything held is ledgered, including the owed fee"
        );
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Income Withdrawal (DEC-117 item 4, DEC-122, DEC-124; doc 15 gap 16)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC124_incomeWithdrawalPaysUsdcWithoutFees() public {
        _hubIncomeCollected(address(usdc), 200e6);
        uint256 before = usdc.balanceOf(bruno);
        uint256 owed = _incomeOf(bruno);
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.IncomeWithdrawn(bruno, address(usdc), owed);
        assertApproxEqAbs(_withdraw(bruno), 90e6, 1, "half of the 180 net; no Payout Fee, no flow fee (DEC-113)");
        assertEq(usdc.balanceOf(bruno) - before, owed);
        assertEq(_withdraw(bruno), 0, "nothing left");
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
    }

    function test_DocGap16_aFailedIncomeTransferIsOwedNotWithdrawn() public {
        _hubIncomeCollected(address(usdc), 200e6);
        uint256 owed = _incomeOf(bruno);
        vm.mockCallRevert(address(usdc), abi.encodeCall(IERC20.transfer, (bruno, owed)), "blocklisted");
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.IncomeTransferOwed(bruno, address(usdc), owed);
        _withdraw(bruno);
        assertEq(vault.owedFees(address(usdc), bruno), owed);
        vm.clearMockedCalls();
        vault.claimOwedFees(address(usdc), bruno);
        assertEq(usdc.balanceOf(bruno), owed);
    }

    function test_DEC117_incomeWithdrawalWorksWhileClosing() public {
        _earnHubIncome(address(usdc), 200e6);
        vm.prank(manager);
        vault.closeFund();
        assertEq(uint8(vault.fundState()), uint8(ICoreVaultLifecycle.FundState.Closing));
        _request(bruno);
        vault.settleIncomeWithdrawal(bruno);
        assertApproxEqAbs(usdc.balanceOf(bruno), 90e6, 1, "DEC-117 item 4: in any fund state");
    }

    function test_DEC117_convertedIncomeRemainsWithdrawableWhenClosed() public {
        _hubIncomeCollected(address(usdc), 200e6);
        stdstore.target(address(vault)).sig("fundState()").enable_packed_slots()
            .checked_write(uint256(ICoreVaultLifecycle.FundState.Closed));
        assertEq(uint8(vault.fundState()), uint8(ICoreVaultLifecycle.FundState.Closed));
        assertApproxEqAbs(_withdraw(bruno), 90e6, 1);
        assertEq(_incomeOf(bruno), 0);
    }

    /// @dev DEC-045, DEC-047: a full exit pays every converted dollar in the same transaction; what the burned shares
    ///      earned and no collection converted yet is paid once a collection converts it.
    function test_DEC045_aFullExitPaysTheConvertedIncomeAndTheRestAfterTheNextCollection() public {
        _hubIncomeCollected(address(usdc), 200e6); // 90 converted for Bruno
        _earnHubIncome(address(usdc), 100e6); // 45 more, recognized at the exit's valuation
        PayoutCalls.fullExit(vault, bruno);
        assertEq(shares.balanceOf(bruno), 0);
        assertApproxEqAbs(
            usdc.balanceOf(bruno), 98e6 + 90e6, 1, "principal less the 2% Payout Fee, plus the converted income"
        );
        assertApproxEqAbs(
            vault.unconvertedIncome(bruno, 0, address(usdc)), 45e6, 1, "the burned shares keep what they earned"
        );
        _collectHubIncome();
        assertApproxEqAbs(_withdraw(bruno), 45e6, 1, "paid at a zero balance once converted");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Hub collection (DEC-172)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC172_hubIncomeIsSoldForUsdcInTheSameCollection() public {
        _earnHubIncome(address(usdc), 100e6);
        _earnHubIncome(address(weth), 0.05e18);
        _wethAt(2000);
        _collectHubIncome();
        assertEq(hubVault.collections(), 1);
        // 100 USDC + 100 USDC of WETH, less the 10% fee, half each.
        assertApproxEqAbs(_incomeOf(bruno), 90e6, 1);
        assertEq(weth.balanceOf(address(vault)), 0, "the Core Vault never holds income in kind");
    }

    function test_DEC056_aFailedSaleLeavesTheTokenIntervalOpen() public {
        _earnHubIncome(address(weth), 0.05e18); // no sale rate: the sale fails
        _collectHubIncome();
        assertEq(_incomeOf(bruno), 0);
        assertApproxEqAbs(vault.unconvertedIncome(bruno, 0, address(weth)), 0.0225e18, 1, "still Bruno's, in WETH");
        _wethAt(2000);
        _collectHubIncome();
        assertApproxEqAbs(_incomeOf(bruno), 45e6, 1, "converted at the next collection");
    }

    function test_DEC056_aFailedHubCollectionNeverBlocksTheRequest() public {
        _earnHubIncome(address(usdc), 100e6);
        hubVault.setCollectReverts(true);
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.HubIncomeCollectionFailed();
        _request(bruno);
        hubVault.setCollectReverts(false);
        _request(bruno);
        assertApproxEqAbs(_incomeOf(bruno), 45e6, 1);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Spoke collection (DEC-122 items 1 and 5, DEC-161, DEC-166, DEC-175)
    // ---------------------------------------------------------------------------------------------------------------

    bytes32 internal constant HOME = keccak256("income-home");

    /// @dev A spoke report with WETH income counters at `cumulative` and that income in the collected bucket.
    function _spokeIncomeReport(uint256 cumulative, uint256 inBucket) internal returns (ReportCodec.Report memory r) {
        r = _spokeIncome(_spokeReport(0, 0), address(spokeWeth), cumulative);
        r.collectedIncome = new ReportCodec.TokenAmount[](1);
        r.collectedIncome[0] = ReportCodec.TokenAmount(address(spokeWeth), inBucket);
    }

    /// @dev The report a spoke publishes after executing a collection of round `round`: `sold` WETH sold for
    ///      `obtained` USDG, sent home in `transitId` to arrive as `toArrive` USDC.
    function _collectionReport(
        uint256 cumulative,
        uint64 resultId,
        uint64 round,
        bytes32 transitId,
        uint256 sold,
        uint256 obtained,
        uint256 toArrive
    ) internal returns (ReportCodec.Report memory r) {
        r = _spokeIncome(_spokeReport(0, 0), address(spokeWeth), cumulative);
        SpokeIncomeTypes.CollectionResult[] memory list = new SpokeIncomeTypes.CollectionResult[](1);
        list[0].resultId = resultId;
        list[0].round = round;
        list[0].transitId = transitId;
        list[0].amountSent = obtained;
        if (transitId != bytes32(0)) {
            list[0].tokens = new address[](1);
            list[0].tokens[0] = address(spokeWeth);
            list[0].sold = new uint256[](1);
            list[0].sold[0] = sold;
            list[0].obtained = new uint256[](1);
            list[0].obtained[0] = obtained;
            r = _inFlightToHub(r, transitId, toArrive, TransferKind.Income);
        }
        r.collectionResults = abi.encode(list);
    }

    function _fillIncome(bytes32 transitId, uint256 amount) internal {
        pool.fill(
            address(vault), address(usdc), amount, TransitMessage.encode(FUND_ID, SPOKE, transitId, TransferKind.Income)
        );
    }

    function test_DEC122_aRequestPublishesOneCollectOrderWhenASpokeShowsIncome() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        uint256 before = hubWormhole.publishedCount();
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.IncomeWithdrawalRequested(manager, 1);
        assertEq(_request(manager), 1, "round 1");
        assertEq(hubWormhole.publishedCount(), before + 1, "one order");
        MockWormholeCore.Published memory p = hubWormhole.published(before);
        assertEq(p.emitter, address(vault), "DEC-111: the Core Vault is the emitter");
        assertEq(p.consistencyLevel, OrderCodec.CONSISTENCY_INSTANT);
        OrderCodec.Order memory o = OrderCodec.decode(p.payload);
        assertEq(o.kind, OrderCodec.COLLECT);
        assertEq(o.fundId, FUND_ID);
        assertEq(o.requestId, bytes32(uint256(1)));
        assertEq(o.attempt, 0);
        ICoreVaultIncome.IncomeCollectionState memory c = vault.incomeCollection();
        assertEq(c.pendingSpokes, 1, "the round waits for spoke 0");
        assertEq(c.deadline, block.timestamp + OrderCodec.ORDER_LIFETIME);

        // A request during the round joins it: no second order.
        assertEq(_request(bruno), 1);
        assertEq(hubWormhole.publishedCount(), before + 1, "piggy-backs on the round in flight");
    }

    function test_DEC122_noOrderWithoutSpokeIncome() public {
        _deliver(_spokeReport(0, 0));
        uint256 before = hubWormhole.publishedCount();
        assertEq(_request(bruno), 0);
        assertEq(hubWormhole.publishedCount(), before);
        vault.settleIncomeWithdrawal(bruno); // nothing to wait for
        vm.deal(bruno, 1 ether);
        vm.prank(bruno);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultIncome.MessageFeeNotUsed.selector, 1));
        vault.requestIncomeWithdrawal{value: 1}(0);
    }

    function test_DEC151_anExpiredRoundIsPublishedAgainAsANewAttempt() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        uint256 count = hubWormhole.publishedCount();
        vm.warp(block.timestamp + OrderCodec.ORDER_LIFETIME + 1);
        assertEq(_request(bruno), 1, "the same round");
        assertEq(hubWormhole.publishedCount(), count + 1);
        OrderCodec.Order memory o = OrderCodec.decode(hubWormhole.published(count).payload);
        assertEq(o.attempt, 1, "a new attempt, so a new order id");
    }

    /// @dev D-41, DEC-166 item 2, DEC-175: the spoke's sale and the bridge are the fund's: WETH sold for 266 USDG, 265
    ///      USDC arrive, and the rate is 2,650 per WETH. The request settles only once the round is converted.
    function test_DEC161_aSpokeCollectionConvertsAtTheDollarsCreditedOnTheHub() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18)); // 0.1 WETH recognized: 0.01 fee, 0.09 net
        _request(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultIncome.IncomeCollectionPending.selector, 1));
        vault.settleIncomeWithdrawal(manager);

        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        assertEq(vault.incomeCollection().openResults, 1, "read, waiting for its transfer");
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultIncome.IncomeCollectionPending.selector, 1));
        vault.settleIncomeWithdrawal(manager);

        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.IncomeCollectionClosed(1, HOME, 265e6, 238.5e6, 26.5e6, 13.25e6, 5000);
        _fillIncome(HOME, 265e6);
        ICoreVaultIncome.IncomeCollectionState memory c = vault.incomeCollection();
        assertEq(c.pendingSpokes, 0);
        assertEq(c.openResults, 0);
        assertApproxEqAbs(vault.settleIncomeWithdrawal(manager), 119.25e6, 1, "Ana: half of 0.09 WETH at 2,650");
        assertApproxEqAbs(_incomeOf(bruno), 119.25e6, 1);
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
    }

    function test_DEC161_anArrivalBeforeItsReportConvertsWhenTheReportComes() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        _fillIncome(HOME, 265e6); // held apart: no report lists it yet (DEC-080)
        assertEq(vault.unmatchedArrivals(), 265e6);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        assertEq(vault.unmatchedArrivals(), 0);
        assertApproxEqAbs(_incomeOf(manager), 119.25e6, 1);
        assertEq(vault.incomeCollection().pendingSpokes, 0);
    }

    function test_DEC161_partialArrivalsWaitForTheFullListedCollection() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        _fillIncome(HOME, 1);
        assertEq(_incomeOf(manager), 0);
        assertEq(vault.incomeCollection().openResults, 1);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultIncome.IncomeCollectionPending.selector, uint64(1)));
        vault.settleIncomeWithdrawal(manager);
        _fillIncome(HOME, 265e6 - 1);
        assertApproxEqAbs(vault.settleIncomeWithdrawal(manager), 119.25e6, 1);
        assertEq(vault.incomeCollection().openResults, 0);
        assertGe(usdc.balanceOf(address(vault)), _ledgerUsdc());
    }

    function test_DEC161_partialArrivalBeforeTheReportCannotCloseTheCollection() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        _fillIncome(HOME, 1);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        assertEq(_incomeOf(manager), 0);
        assertEq(vault.incomeCollection().openResults, 1);
        _fillIncome(HOME, 265e6 - 1);
        assertApproxEqAbs(_incomeOf(manager), 119.25e6, 1);
    }

    function test_DEC122_emptyRetryCannotSettleBeforeAnEarlierCollectionsArrival() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        _deliver(_collectionReport(0.1e18, 2, 1, bytes32(0), 0, 0, 0));
        assertEq(vault.incomeCollection().openResults, 1);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultIncome.IncomeCollectionPending.selector, uint64(1)));
        vault.settleIncomeWithdrawal(manager);
        _fillIncome(HOME, 265e6);
        assertApproxEqAbs(vault.settleIncomeWithdrawal(manager), 119.25e6, 1);
    }

    function test_DEC122_aSpokeWithNothingToSendClosesItsPartOfTheRound() public {
        _deliver(_spokeIncomeReport(1, 1));
        _request(manager);
        _deliver(_collectionReport(1, 1, 1, bytes32(0), 0, 0, 0));
        assertEq(vault.incomeCollection().pendingSpokes, 0);
        vault.settleIncomeWithdrawal(manager);
    }

    /// @dev DEC-066: a refunded send is sent again under the same result; the Hub follows the new transfer.
    function test_DEC066_aResentResultConvertsWithItsNewTransfer() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        bytes32 resent = keccak256("resent");
        _deliver(_collectionReport(0.1e18, 1, 1, resent, 0.1e18, 266e6, 264e6));
        _fillIncome(resent, 264e6);
        assertApproxEqAbs(_incomeOf(manager), 118.8e6, 1, "half of 0.09 WETH at 2,640");
        assertEq(vault.incomeCollection().openResults, 0);
    }

    /// @dev DEC-138 on a spoke: income recognized from the report before a deposit is not the entrant's.
    function test_DEC138_spokeIncomeRecognizedFromAReportBeforeAnEntryIsNotTheEntrants() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _deposit(caio, 100e6);
        _request(manager);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 300e6, 300e6));
        _fillIncome(HOME, 300e6);
        assertEq(_incomeOf(caio), 0);
        assertApproxEqAbs(_incomeOf(manager), 135e6, 1);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Ledger (DEC-080)
    // ---------------------------------------------------------------------------------------------------------------

    function testFuzz_DEC080_everyCollectedDollarLandsInExactlyOnePlace(
        uint96 usdcIncome,
        uint96 wethIncome,
        uint16 slice
    ) public {
        registry.setSlice(uint16(bound(slice, 0, 10_000)));
        uint256 a = bound(usdcIncome, 0, 1e15);
        uint256 b = bound(wethIncome, 0, 1e24);
        _earnHubIncome(address(usdc), a);
        _deposit(caio, 10e6);
        _earnHubIncome(address(weth), b);
        _wethAt(2000);
        _collectHubIncome();
        uint256 obtained = a + b * 2000e6 / 1e18;
        uint256 paidOut = usdc.balanceOf(protocol) + usdc.balanceOf(address(feeVault));
        assertLe(paidOut + _heldIncome(), obtained, "fees plus held never exceed what the sales obtained");
        uint256 owed = _incomeOf(manager) + _incomeOf(bruno) + _incomeOf(caio);
        assertLe(owed, _heldIncome(), "the holders are never owed more than is held");
        assertGe(usdc.balanceOf(address(vault)), _ledgerUsdc(), "the ledger is backed");
        assertLe(obtained - paidOut - owed, 8, "at most rounding dust is nobody's");
    }
}
