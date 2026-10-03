pragma solidity 0.8.28;

import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {Mandate, TokenConfig} from "../../../src/mandate/Mandate.sol";
import {DollarIncomeIndex} from "../../../src/libraries/DollarIncomeIndex.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";
import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";
import {PayoutCalls} from "../../utils/PayoutCalls.sol";

contract SettlementCoreVault is CoreVault {
    using DollarIncomeIndex for DollarIncomeIndex.State;

    constructor(Mandate memory mandate, CoreVaultConfig memory config) CoreVault(mandate, config) {}

    function prepareHistory(address holder, uint256 balance) external returns (uint256 dollars) {
        DollarIncomeIndex.State storage index = _s.incomeBook.sources[1].index;
        index.activate(uint64(block.timestamp + 1));
        index.activate(uint64(block.timestamp + 2));
        while (!index.settle(holder, balance)) {}
        index.wait(holder, balance / 2, block.timestamp + 3);
        index.activate(uint64(block.timestamp + 4));
        index.activate(uint64(block.timestamp + 5));
        uint256[] memory sold = new uint256[](15);
        for (uint256 collection; collection < 64; ++collection) {
            for (uint256 token; token < 15; ++token) {
                assert(index.recognize(index.tokens[token], 1000, ShareToken(shareToken).totalSupply()));
                sold[token] = 1000;
            }
            uint64 frozen = index.freeze(sold);
            index.finalizeFrozen(frozen, sold);
            dollars += 15_000;
        }
        _s.incomeBook.heldDollars += dollars;
    }
}

contract IncomeSettlementPathsTest is CoreVaultFixture {
    function setUp() public override {
        super.setUp();
        Mandate memory mandate = _mandate(1000);
        mandate.tokens = new TokenConfig[](16);
        mandate.tokens[0] = TokenConfig(HUB, address(usdc));
        mandate.tokens[1] = TokenConfig(SPOKE, address(usdg));
        mandate.tokens[2] = TokenConfig(SPOKE, address(spokeWeth));
        for (uint256 token = 3; token < 16; ++token) {
            CoreMockToken extra = new CoreMockToken("Income", "INC", 6);
            prices.setPrice(address(extra), 1e18);
            mandate.tokens[token] = TokenConfig(SPOKE, address(extra));
        }
        CoreVaultConfig memory config = _config(0);
        vault = new SettlementCoreVault(mandate, config);
        hubVault.setCoreVault(address(vault));
        receiver.setCoreVault(address(vault));
        bridge.setVault(address(vault));
        shares = ShareToken(vault.shareToken());
        _seedFund(address(vault), address(usdc), 0);
        _deposit(alice, 100e6);
        _deposit(manager, 99e6);
    }

    function _history(address holder) internal {
        uint256 dollars = SettlementCoreVault(address(vault)).prepareHistory(holder, shares.balanceOf(holder));
        usdc.mint(address(vault), dollars);
    }

    function _continue(address holder) internal {
        bool complete;
        uint256 calls;
        while (!complete) {
            vm.cool(address(vault));
            uint256 beforeGas = gasleft();
            vm.prank(bob);
            complete = vault.settleHolderIncome(holder);
            assertLt(beforeGas - gasleft(), 15_000_000);
            assertLt(++calls, 250);
        }
        assertGt(calls, 1);
    }

    function _ready() internal {
        vm.prank(manager);
        vault.closeFund();
        vm.warp(vault.closingDeadline() + 1);
        vault.unwindAllAfterDeadline();
        ReportCodec.Report memory report;
        report.fundId = FUND_ID;
        report.mandateHash = vault.mandateHash();
        report.timestamp = uint64(block.timestamp);
        report.sequence = ++reportSequence;
        SpokeUnwindTypes.OrderResult[] memory results = new SpokeUnwindTypes.OrderResult[](1);
        results[0].requestId = vault.closureRequestId();
        results[0].attempt = 1;
        results[0].orderId = keccak256(abi.encode(OrderCodec.CLOSE, FUND_ID, results[0].requestId, uint32(1)));
        report.unwindResults = abi.encode(results);
        receiver.deliver(0, report);
    }

    function test_maximumHistoryIncomeWithdrawal() public {
        _history(alice);
        _continue(alice);
        vm.cool(address(vault));
        uint256 beforeGas = gasleft();
        vm.prank(alice);
        assertGt(vault.withdrawIncome(), 0);
        assertLt(beforeGas - gasleft(), 15_000_000);
    }

    function test_maximumHistoryPayoutBurn() public {
        _history(alice);
        _continue(alice);
        vm.cool(address(vault));
        uint256 beforeGas = gasleft();
        ICoreVaultPayouts.PayoutReceipt memory receipt = PayoutCalls.fullExit(vault, alice);
        assertEq(receipt.sharesBurned, 100e18);
        assertLt(beforeGas - gasleft(), 15_000_000);
    }

    function test_maximumHistoryClosureFinalizationAndClosedExit() public {
        _history(manager);
        _history(alice);
        _ready();
        _continue(manager);
        vm.cool(address(vault));
        uint256 beforeGas = gasleft();
        vault.finalizeClosure();
        assertLt(beforeGas - gasleft(), 15_000_000);
        assertEq(uint8(vault.fundState()), uint8(ICoreVaultLifecycle.FundState.Closed));
        _continue(alice);
        vm.cool(address(vault));
        beforeGas = gasleft();
        assertGt(vault.exitClosedFund(alice), 0);
        assertLt(beforeGas - gasleft(), 15_000_000);
        assertEq(shares.balanceOf(alice), 0);
    }
}
