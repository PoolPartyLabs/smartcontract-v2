// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";

/// @notice Review port of core-a L01, consolidated finding L-01 (register S-17). On `e5c778a` MandateLib accepted any
///         Payout Fee up to 100%; with the flow fee every Instant claim then underflowed and the open request could
///         never close. Since S-17 the Payout Fee was capped at 10,000 - MAX_FLOW_FEE_BPS, and DEC-155 caps it at 10%
///         (`MAX_PAYOUT_FEE_BPS` = 1,000): the review's Mandate is refused at creation, and at the cap with the maximum
///         flow fee (100 bps) an Instant claim still closes.
contract L01_PayoutFeeTrap is CoreVaultFixture {
    function test_REVIEW_L01_payoutFeeAboveTheCapIsRefusedAtCreation() public {
        Mandate memory m = _mandate(2000);
        m.payoutFeeBps = 10_000; // the review's Mandate
        vm.expectRevert(abi.encodeWithSelector(MandateLib.BpsAboveMax.selector, 10_000, 1000));
        new CoreVault(m, _config(25));

        m.payoutFeeBps = 1001; // one above the cap
        vm.expectRevert(abi.encodeWithSelector(MandateLib.BpsAboveMax.selector, 1001, 1000));
        new CoreVault(m, _config(25));
    }

    /// @dev Re-attack at the bound: Payout Fee 1,000 bps and the core's maximum flow fee 100 bps stay below 100%; both
    ///      round down, so the subtraction cannot underflow and the request closes.
    function test_REVIEW_L01_instantClaimAtTheCapWithTheMaxFlowFeeCloses() public {
        Mandate memory m = _mandate(2000);
        m.payoutFeeBps = MandateLib.MAX_PAYOUT_FEE_BPS;
        _deploy(m, _config(100));

        _deposit(alice, 1000e6);
        _request(alice, 500e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        console2.log("gross / payout fee / flow fee / paid", r.usdcGross, r.payoutFee, r.flowFee);
        console2.log("paid", r.usdcPaid);
        assertEq(r.usdcGross, 500e6);
        assertEq(r.payoutFee, 50e6, "10% Payout Fee");
        assertEq(r.flowFee, 5e6);
        assertEq(r.usdcPaid, 445e6);
        assertFalse(vault.payoutRequest(alice).open, "the request closed");
        assertEq(vault.operatingCash(), 50e6);

        // The holder is free to open a Standard request next (no trap).
        _request(alice, 400e6, ICoreVault.PayoutMode.Standard);
        assertTrue(vault.payoutRequest(alice).open);
    }
}
