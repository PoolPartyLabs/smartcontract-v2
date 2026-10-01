// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {SpokeAForkBase} from "./SpokeAForkBase.sol";

/// @notice [L-05] (spoke-a report L-01) measurement on the real Arbitrum V4 contracts, ported to main: the gas one
///         automatic unwind spends per small position it visits, so the number of positions that exhausts a
///         32M-gas transaction can be read off. Main still has no cap on open positions (S-11 bounds sends home only).
///         e5c778a: 3,428,382 gas at 10 dust positions, 12,050,855 at 40 (about 287k per position).
contract L01_UnwindGasPerPositionFork is SpokeAForkBase {
    address mallory = makeAddr("mallory");

    function _claimGasWithDust(uint256 dust) internal returns (uint256 gasUsed, uint256 proceeds) {
        _depositAs(alice, 1_000_000e6);
        _depositAs(mallory, 50_000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(1_000_000e6);
        // `dust` USDC-only range orders of 5 USDC each, then one of the rest (registry order: dust first).
        for (uint256 i; i < dust; ++i) {
            _openRangeOrder(5e6, int24(int256(i)) * 10);
        }
        _openRangeOrder(1_000_000e6 - dust * 5e6, 0);
        vm.prank(mallory);
        vault.requestPayout(49_000e6, ICoreVault.PayoutMode.Instant);
        uint256 g = gasleft();
        vm.prank(mallory);
        ICoreVault.PayoutReceipt memory r = vault.claimPayout("");
        gasUsed = g - gasleft();
        proceeds = r.unwindProceeds;
    }

    function _openRangeOrder(uint256 amount, int24 shift) internal {
        bytes memory params = abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: _floor10(tick0 - 2230 - shift),
                tickUpper: _floor10(tick0 - 110 - shift),
                liquidity: 0,
                amount0Max: 0,
                amount1Max: uint128(amount),
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.prank(manager);
        hubVault.openPosition(address(adapter), poolId, 0, amount, params);
    }

    function test_POC_REVIEW_L05_fork_unwindGas_10_dust() public {
        (uint256 gasUsed, uint256 proceeds) = _claimGasWithDust(10);
        console2.log("claim gas with 10 dust positions", gasUsed);
        console2.log("proceeds", proceeds);
    }

    function test_POC_REVIEW_L05_fork_unwindGas_40_dust() public {
        (uint256 gasUsed, uint256 proceeds) = _claimGasWithDust(40);
        console2.log("claim gas with 40 dust positions", gasUsed);
        console2.log("proceeds", proceeds);
    }

    /// @dev Direct check against Arbitrum's 32,000,000 per-transaction gas limit.
    function test_POC_REVIEW_L05_fork_unwindGas_160_dust() public {
        (uint256 gasUsed, uint256 proceeds) = _claimGasWithDust(160);
        console2.log("claim gas with 160 dust positions", gasUsed);
        console2.log("proceeds", proceeds);
        assertGt(gasUsed, 32_000_000, "160 positions ahead of the value exceed one Arbitrum transaction");
    }
}
