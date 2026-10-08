// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {AccountingPocFixture} from "./AccountingPocFixture.sol";

/// @notice Enters, triggers the collection and conversion of income that was earned before it entered, takes its cut
///         and queues its exit, in one transaction.
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
        // Permissionless: the attacker, not the Manager, decides when the hub income is collected and converted.
        core.requestIncomeWithdrawal(0);
        income = core.withdrawIncome();
        // DEC-077: nothing is locked at request; the Standard Payout carries no Payout Fee.
        core.requestPayout(1_000_000_000e6, ICoreVaultPayouts.PayoutMode.Standard, 0);
    }

    function exit() external returns (uint256 usdcPaid) {
        usdcPaid = core.claimPayout(0).usdcPaid;
    }
}

/// @title PoC (closed): income earned before an entrant's deposit is no longer captured by the entrant through a
///        permissionless collection (DEC-014; security review S-15, CS-OQ-1)
/// @notice Severity when found: MEDIUM (bounded value leak from the holders who earned the income to a just-in-time
///         entrant). FIXED by DEC-138 and the Hub dollar index (DEC-161, WP-10): the hub income is recognized from the
///         hub Spoke Vault's monotonic counters at every mint and burn, inside the valuation the mint already runs, so
///         the entrant's deposit attributes the income earned before it to the holders of that moment; a collection the
///         entrant triggers afterwards only converts it to dollars for them.
///
/// Attack sequence (as found):
///  1. the fund's hub position earns fees over weeks; the Manager collects them (`SpokeVault.collectIncome`), which
///     parks them in the hub Spoke Vault's collected bucket (DEC-092);
///  2. the attacker, in one transaction: `deposit`, a collection (then `forwardIncomeToCoreVault(usdc)`, now an Income
///     Withdrawal request), `withdrawIncome`, `requestPayout(Standard)`;
///  3. 72 hours later it claims the Standard Payout (no Payout Fee) and leaves.
///
/// Impact as found: with 30,000 USDC of collected fees in a 1,000,000 USDC fund and an equal-sized deposit, the entrant
/// took 12,000 USDC of income it never earned. Now it takes none, and the round trip costs it both flow fees.
contract JitIncomeCapturePoC is AccountingPocFixture {
    uint256 internal constant FUND = 1_000_000e6;
    uint256 internal constant FEES_EARNED = 30_000e6;

    function setUp() public {
        _deployFund(2000, 25);
    }

    function test_POC_FIXED_jitEntrantNoLongerCapturesIncomeEarnedBeforeEntry() public {
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

        // Net income after the 20 % performance fee is 24,000 USDC; DEC-014 gives all of it to Alice (and the seed).
        uint256 net = bucket - bucket * 2000 / 10_000;
        assertEq(captured, 0, "DEC-138: the entrant takes nothing of income generated before its entry");
        assertApproxEqAbs(core.incomeOwed(alice), net, 1e6, "Alice keeps all she earned");

        // The entrant leaves through a Standard Payout: both flow fees are its cost.
        vm.warp(block.timestamp + 72 hours);
        uint256 paid = mallory.exit();
        assertEq(shares.balanceOf(address(mallory)), 0, "full exit");
        assertLt(usdc.balanceOf(address(mallory)), FUND, "the round trip now only costs the entrant");
        assertGt(paid, 0);
    }
}
