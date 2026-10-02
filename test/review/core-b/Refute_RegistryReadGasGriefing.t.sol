// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ManagerRegistry} from "../../../src/core/ManagerRegistry.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";

/// @notice Refutation: the registry read in CoreVaultIncomeLogic.protocolSliceBps is wrapped in try/catch and falls
///         back to the 50% default. A caller who controls the gas of the collection (anyone, through the permissionless
///         forward, or the relayer of an Income fill) would profit the protocol at the manager's expense if some gas
///         limit made the read run out of gas while the rest of the collection still completed. Sweep every gas limit
///         around the minimum that succeeds, with the REAL ManagerRegistry and a 10% slice for the manager.
/// @dev Re-run on main. S-12 now pays both fees through `trySafeTransfer` and books a failed transfer as owed, so the
///      sweep also checks that no gas limit turns a fee transfer into an owed fee (an out-of-gas inside the try would
///      leave 1/64 of the gas, far too little for the two owed-fee writes). Main: 1,008 successful limits, lowest
///      148,250 gas (999 and 150,500 without the fee-vault reads, which warm that account); the review measured 859
///      successful limits on `e5c778a`. Refutation holds. WP-07 (DEC-131 pattern) moved the income split into its own
///      linked library, which this sweep reaches cold where `CoreVaultLogic` was warm from the deposit (2,500 gas),
///      and added three fee terms to the wiring every library call carries: 996 successful limits, lowest 151,250;
///      every successful one still read the registry.
contract Refute_RegistryReadGasGriefing is CoreVaultFixture {
    function test_refute_noGasLimitForcesTheDefaultSlice() public {
        ManagerRegistry real = new ManagerRegistry(address(this));
        real.setProtocolSliceBps(manager, 1000); // negotiated 10% of the manager fee
        vm.etch(address(registry), address(real).code);
        // Copy the entry into the etched registry's storage by setting it through the etched code's owner path.
        vm.store(address(registry), bytes32(0), bytes32(uint256(uint160(address(this))))); // Ownable._owner slot
        ManagerRegistry(address(registry)).setProtocolSliceBps(manager, 1000);
        assertEq(ManagerRegistry(address(registry)).protocolSliceBps(manager), 1000);

        _deposit(alice, 10_000e6);
        address feeVault = vault.managerFeeVault();
        uint256 successes;
        uint256 minGas;
        for (uint256 g = 60_000; g <= 400_000; g += 250) {
            uint256 snap = vm.snapshotState();
            uint256 before = usdc.balanceOf(protocol);
            uint256 feeVaultBefore = usdc.balanceOf(feeVault);
            (bool ok,) =
                address(hubVault).call{gas: g}(abi.encodeCall(MockHubSpokeVault.forwardIncome, (address(usdc), 100e6)));
            if (ok) {
                ++successes;
                if (minGas == 0) minGas = g;
                // 20% performance fee on 100 = 20; a 10% slice of it = 2. The default would give 10.
                assertEq(usdc.balanceOf(protocol) - before, 2e6, "a successful collection always read the registry");
                assertEq(usdc.balanceOf(feeVault) - feeVaultBefore, 18e6, "and paid the manager fee in full");
                assertEq(vault.owedFees(address(usdc), protocol), 0, "no slice booked as owed (S-12)");
                assertEq(vault.owedFees(address(usdc), feeVault), 0, "no manager fee booked as owed (S-12)");
            }
            vm.revertToState(snap);
        }
        console2.log("successful gas limits tried", successes);
        console2.log("lowest successful gas limit ", minGas);
        assertEq(successes, 996);
        assertEq(minGas, 151_250);
    }
}
