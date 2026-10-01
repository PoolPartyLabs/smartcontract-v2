// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
// Imported so the build always emits the probe's artifact (it is otherwise only read by name).
import {OracleAwareV4AdapterProbe} from "./OracleAwareV4AdapterProbe.sol";

/// @notice (adapters review I-01, ported to fix/pp-sc-fix-independent-review) MEASUREMENT: the runtime bytecode the
///         oracle-aware views of `OracleAwareV4AdapterProbe` add, next to today's adapter and the contracts an
///         oracle-guarded unwind would grow (EIP-170 limit 24,576 bytes). e5c778a: adapter 17,854 B, probe 19,726 B
///         (+1,872 B), Spoke Vault 23,644 B (932 B of headroom).
/// @dev Run: forge test --match-path 'test/review/adapters/OracleAwareV4AdapterProbeSize.t.sol' -vv
contract OracleAwareV4AdapterProbeSizeTest is Test {
    uint256 internal constant EIP170 = 24_576;

    function _size(string memory artifact) internal view returns (uint256) {
        return vm.getDeployedCode(artifact).length;
    }

    function test_REVIEW_I01_measure_bytecodeHeadroom() public view {
        uint256 adapter = _size("UniswapV4Adapter.sol:UniswapV4Adapter");
        uint256 probe = _size("OracleAwareV4AdapterProbe.sol:OracleAwareV4AdapterProbe");
        uint256 spokeVault = _size("SpokeVault.sol:SpokeVault");
        uint256 logic = _size("CoreVaultLogic.sol:CoreVaultLogic");
        uint256 lib = _size("SpokeCrossChainLib.sol:SpokeCrossChainLib");
        console2.log("UniswapV4Adapter today", adapter);
        console2.log("probe (e5c778a adapter + oracle-aware views)", probe);
        console2.log("SpokeVault today / headroom", spokeVault, EIP170 - spokeVault);
        console2.log("CoreVaultLogic today / headroom", logic, EIP170 - logic);
        console2.log("SpokeCrossChainLib today / headroom", lib, EIP170 - lib);
        assertLt(probe, EIP170, "the oracle-aware views fit in the adapter");
        assertLt(spokeVault, EIP170, "the Spoke Vault is deployable");
    }
}
