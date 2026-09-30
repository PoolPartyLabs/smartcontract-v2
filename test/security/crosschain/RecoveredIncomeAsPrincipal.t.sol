// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";

/// @title Final verification of security review S-4: a recovered Income transfer home enters Idle as Principal
/// @notice `CoreVault.recoverUnlistedArrival` (S-4) credits an arrival no accepted report listed to Idle once no report
///         can list it any more. It has no way to know the transfer's kind (the Across message's claim is
///         unauthenticated, OQ-01), so a send home of kind Income that reaches the hub during a report outage longer
///         than the retention is recovered as Principal: it raises the Share Price for every holder of the moment
///         instead of entering the accumulator net of the performance fee (DEC-107, DEC-109, ruling 2026-09-29). The
///         manager's fee and the protocol slice on that income are never taken, and DEC-014 attribution is by shares
///         at recovery time. Bounded by the income that was in flight and needs an outage of several days; no value
///         leaves the fund. Pinned so the deviation is a known one.
contract RecoveredIncomeAsPrincipalTest is CrossChainFixture {
    function test_VF_S4_recoveredIncomeSendHomeSkipsTheFeeSplitAndTheAccumulator() public {
        _deposit(alice, 100_000e6);
        (, uint256 outboundDeposit) = _sendToSpoke(50_000e6, 49_975e6);
        _fillOnSpoke(outboundDeposit);
        _reportAndDeliver(900);

        // Income earned on the spoke, sent home as Income, filled on the hub before any report lists it.
        _strangerFillOnSpoke(attacker, keccak256("spoke income"), 10_000e6, TransferKind.Income);
        assertEq(spoke.collectedIncome(address(usdg)), 10_000e6, "income sits in the spoke's collected bucket");
        (bytes32 homeTransit, uint256 homeDeposit) = _sendToHub(10_000e6, TransferKind.Income, _quote(9995e6));
        skip(120);
        _fillOnHub(homeDeposit);
        uint256 filledAt = block.timestamp;
        assertEq(core.unmatchedArrivals(), 9995e6, "held apart until a report lists it");

        uint256 idleBefore = core.idle();
        uint256 collectedBefore = core.collectedIncome(address(usdc));
        uint256 feeVaultBefore = IERC20(address(usdc)).balanceOf(core.managerFeeVault());
        uint256 protocolBefore = IERC20(address(usdc)).balanceOf(protocol);

        // No report is accepted until the spoke has stopped listing the send home; then the recovery opens.
        skip(FILL_DEADLINE + 3 days + MAX_REPORT_AGE + 1);
        _reportAndDeliver(900);
        vm.warp(filledAt + 6 hours + 3 days + 2 * uint256(MAX_REPORT_AGE));
        assertEq(core.recoverUnlistedArrival(0, homeTransit), 9995e6, "S-4: recovered");

        // The income reached Idle as Principal: no fee split, nothing for the accumulator.
        assertEq(core.idle(), idleBefore + 9995e6, "VF: the whole Income arrival entered Idle");
        assertEq(core.collectedIncome(address(usdc)), collectedBefore, "VF: nothing entered the collected income");
        assertEq(core.attributedIncome(alice, address(usdc)), 0, "VF: the holder is owed no Attributed Income");
        assertEq(IERC20(address(usdc)).balanceOf(core.managerFeeVault()), feeVaultBefore, "VF: no manager fee");
        assertEq(IERC20(address(usdc)).balanceOf(protocol), protocolBefore, "VF: no protocol slice");
        assertEq(core.owedFees(address(usdc), protocol), 0, "VF: no fee owed either");

        // For reference, the same 9,995 USDC listed by a report would have paid 1,999 USDC of fees (20%, half each).
        uint256 fee = 9995e6 * 2000 / 10_000;
        assertEq(fee, 1999e6);
    }
}
