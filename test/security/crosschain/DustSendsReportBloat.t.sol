// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";

/// @title Regression (security review S-11): dust transfers home can no longer bloat the report past a hub block
/// @notice Was PoC `test_POC_dustSendsHomeMakeReportsUndeliverable` (medium, cross-chain lens): the `inFlightToHub` list
///         had no bound, so 500 sends of one base unit made every report VAA need more than Arbitrum One's 32,000,000
///         gas to deliver and the manager could switch the report channel off (mints revert `StaleSpokeReport`).
///
/// Fix (S-11): `sendToHub` reverts `HubBoundInFlightLimit` once `SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT` sends are
/// listed. The test repeats the dust attack and asserts it now FAILS: the list stops at the bound, the report built
/// with a full list is delivered well within a block, and deposits stay open.
contract DustSendsReportBloatPoC is CrossChainFixture {
    /// @dev Arbitrum One's block gas limit: no transaction can use more.
    uint256 internal constant ARBITRUM_BLOCK_GAS_LIMIT = 32_000_000;

    function test_SEC_S11_dustSendsHomeNoLongerMakeReportsUndeliverable() public {
        _deposit(alice, 100_000e6);
        (, uint256 depositId) = _sendToSpoke(50_000e6, 49_975e6);
        _fillOnSpoke(depositId);
        _reportAndDeliver(900);

        // The manager tries 500 sends of one base unit: the list stops at the bound.
        uint256 limit = SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT;
        vm.chainId(SPOKE);
        vm.startPrank(manager);
        for (uint256 i; i < limit; ++i) {
            spoke.sendToHub(1, TransferKind.Principal, 0, _quote(1));
        }
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.HubBoundInFlightLimit.selector, limit));
        spoke.sendToHub(1, TransferKind.Principal, 0, _quote(1));
        vm.stopPrank();
        vm.chainId(HUB);

        // The report with a full list is delivered within a fraction of a hub block.
        uint256 index = _publishReport();
        skip(900);
        bytes memory vaa = _vaa(index);
        uint256 gasBefore = gasleft();
        (bool delivered,) =
            address(receiver).call{gas: ARBITRUM_BLOCK_GAS_LIMIT}(abi.encodeCall(receiver.deliver, (vaa)));
        uint256 used = gasBefore - gasleft();
        assertTrue(delivered, "S-11: the VAA fits in an Arbitrum One block");
        assertLt(used, ARBITRUM_BLOCK_GAS_LIMIT / 4, "S-11: with a wide margin");

        // Deposits stay open on the fresh report.
        _refreshPrices();
        usdc.mint(bob, 10_000e6);
        vm.startPrank(bob);
        usdc.approve(address(core), 10_000e6);
        core.deposit(10_000e6, 0);
        vm.stopPrank();
    }
}
