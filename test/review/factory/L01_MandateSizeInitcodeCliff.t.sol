// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {Test} from "forge-std/Test.sol";
import {Mandate, MandateLib, PoolConfig} from "../../../src/mandate/Mandate.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {Create3Harness} from "../../mocks/factory/Create3Harness.sol";
import {FactoryReviewFixture} from "./FactoryReviewFixture.sol";

/// @dev Exposes the internal `MandateLib.validate` to the test.
contract MandateValidator {
    function validate(Mandate memory m) external pure {
        MandateLib.validate(m);
    }
}

/// @notice Review port of factory L01, consolidated finding L-10 (no register entry). Still present on main: no list
///         bound was added, and the fixes made the Core Vault's creation code larger, so the init-code wall comes
///         earlier (50,602 bytes at 66 extra pools against 49,316 on `e5c778a`). WP-07 moved the payout path into a
///         linked library (DEC-131 pattern): 49,854 bytes at 66, the wall back at 63 extra pools. The test now solves
///         the wall from the build instead of pinning it (Mandate v2, WP-07 B). Gas on main: 20.52M,
///         23.76M, 27.17M, 31.49M and 36.42M for 0, 10, 20, 30 and 40 extra hub pools (review: 20.7M to 37.0M).
///         Mandate v2 dropped the unwind order (DEC-137): 96 bytes per extra pool instead of 192, the init-code wall
///         at 143 extra pools, and 20.90M, 24.64M, 30.69M and 32.83M of gas for 0, 20, 50 and 60.
///         Original note: neither `MandateLib.validate` nor the factory bounds the Mandate's lists, while the cost of creating
///         a fund grows with them: every fund contract validates the Mandate (O(n^2) duplicate scans), the hub Spoke
///         Vault and the Core Vault copy it into storage, and each contract's init code carries the ABI-encoded Mandate.
///         (1) Gas: with ~30 hub pools beyond the fixture's, `createFund` needs more than Arbitrum One's 32,000,000 gas
///         per transaction and can never be mined. (2) Init code: the Core Vault's creation code is 34,084 bytes, so a
///         Mandate encoding above ~15 KB pushes its init code past EIP-3860's 49,152 bytes; the CREATE inside the CREATE3
///         proxy fails and `createFund` reverts with EMPTY revert data. No check names either limit.
contract L01_MandateSizeInitcodeCliff is FactoryReviewFixture {
    uint256 internal constant ARBITRUM_MAX_TX_GAS = 32_000_000;

    /// @dev The fixture Mandate plus `extra` hub Uniswap V4 pools (each also an unwind step until Mandate v2 removed
    ///      the unwind order, DEC-137).
    function _bigMandate(Deployment memory d, uint256 extra)
        internal
        view
        returns (Mandate memory m, IFundFactory.HubParams memory p)
    {
        FundPlan memory plan = _plan();
        uint256 n = d.factory.nextCreationNumber();
        m = _buildMandate(d.factory, d.factory.fundIdOf(HUB, n, manager), plan);
        p = _hubParams(n, plan, _coreVaultCreationCode(d));
        address hubUniswap = m.adapters[0].adapter;

        PoolConfig[] memory pools = new PoolConfig[](m.pools.length + extra);
        PoolKey[] memory keys = new PoolKey[](1 + extra);
        for (uint256 i; i < m.pools.length; ++i) {
            pools[i] = m.pools[i];
        }
        keys[0] = p.uniswapV4Pools[0];
        for (uint256 i; i < extra; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            PoolKey memory k = _poolKey(address(weth), address(usdc), uint24(100 + i), int24(int256(1 + i)));
            bytes32 id = PoolId.unwrap(k.toId());
            pools[m.pools.length + i] = PoolConfig(HUB, hubUniswap, id);
            keys[1 + i] = k;
        }
        m.pools = pools;
        p.uniswapV4Pools = keys;
    }

    /// @dev createFund gas as the hub pool list grows (Arbitrum One caps a transaction at 32,000,000 gas).
    /// @dev One size per test: since the creation-time price check (independent review M-03) the five creations no
    ///      longer fit in one test's gas limit. On main: 20.52M, 23.76M, 27.17M, 31.49M, 36.42M.
    function _createFundGas(uint256 extraPools) internal returns (uint256 used) {
        Deployment memory d = _hubChain();
        (Mandate memory m, IFundFactory.HubParams memory p) = _bigMandate(d, extraPools);
        _fundManagerSeed(address(usdc), manager, address(d.factory), p.seedAmount);
        vm.prank(manager);
        uint256 g = gasleft();
        d.factory.createFund(m, p);
        used = g - gasleft();
        console2.log("extra hub pools", extraPools, "createFund gas", used);
    }

    function test_POC_REVIEW_L10_createFundGas_0ExtraPools() public {
        assertLt(_createFundGas(0), ARBITRUM_MAX_TX_GAS);
    }

    function test_POC_REVIEW_L10_createFundGas_20ExtraPools() public {
        assertLt(_createFundGas(20), ARBITRUM_MAX_TX_GAS);
    }

    /// @dev A valid Mandate with 60 extra hub pools needs more gas than one Arbitrum transaction allows (40 before
    ///      Mandate v2 dropped the unwind order).
    function test_POC_REVIEW_L10_createFundGasGrowsPastTheArbitrumTransactionCap() public {
        assertGt(
            _createFundGas(60), ARBITRUM_MAX_TX_GAS, "a valid Mandate needs more gas than one Arbitrum transaction"
        );
    }

    /// @dev The init code wall, by arithmetic on the exact bytes `_deployCoreVault` assembles (creation code plus
    ///      `abi.encode(m, c)`, `c` rebuilt field by field as the factory fills it). The EVM behaviour past 49,152 bytes
    ///      is shown by L01_InitCodeLimitProbe (run with the mainnet limit). The wall is solved from the bytes each extra
    ///      hub pool adds, so the test follows the Core Vault's size instead of pinning it; MandateLib accepts the
    ///      Mandate at the wall.
    function test_POC_REVIEW_L10_coreVaultInitCodePassesEip3860ForAValidMandate() public {
        Deployment memory d = _hubChain();
        MandateValidator validator = new MandateValidator();
        (Mandate memory m0, IFundFactory.HubParams memory p) = _bigMandate(d, 0);
        (Mandate memory m1,) = _bigMandate(d, 1);
        CoreVaultConfig memory c = _config(d, p.creationNumber);
        uint256 base = p.coreVaultCreationCode.length + abi.encode(m0, c).length;
        uint256 perPool = abi.encode(m1, c).length - abi.encode(m0, c).length;
        uint256 wall = (49_152 - base) / perPool + 1;

        (Mandate memory m,) = _bigMandate(d, wall);
        validator.validate(m); // MandateLib accepts it
        uint256 initCode = p.coreVaultCreationCode.length + abi.encode(m, c).length;
        console2.log("abi.encode(Mandate) bytes at the wall", abi.encode(m).length);
        console2.log("Core Vault init code bytes at the wall", initCode);
        console2.log("bytes per extra hub pool", perPool);
        console2.log("first extra-pool count above EIP-3860", wall);
        assertGt(initCode, 49_152, "above EIP-3860: the Core Vault can never be created from this valid Mandate");
        assertEq(perPool, 96, "one PoolConfig per extra pool (192 with the unwind step before Mandate v2)");
    }

    function _config(Deployment memory d, uint256 creationNumber) internal view returns (CoreVaultConfig memory c) {
        c.fundId = d.factory.fundIdOf(HUB, creationNumber, manager);
        c.usdc = address(usdc);
        c.hubSpokeVault = address(1);
        c.reportReceiver = address(1);
        c.managerRegistry = address(registry);
        c.priceSource = address(prices);
        c.acrossSpokePool = address(hubAcross);
        c.wormholeCore = address(1);
        c.protocolRecipient = recipient;
        c.excessRecipient = recipient;
        c.escrowImplementation = address(1);
        c.flowFeeBps = 25;
        c.shareName = "Pool Party Fund 1";
        c.shareSymbol = "PP-1";
    }
}

/// @notice Probe for [L-01], small enough to deploy under the mainnet size limits. Run with
///         `FOUNDRY_CODE_SIZE_LIMIT=24576 forge test --match-contract L01_InitCodeLimitProbe`: under the limit, the CREATE3
///         proxy's CREATE of a 49,153-byte init code fails and `Create3.deploy` reverts with empty data. Without the
///         variable, this repository's test EVM accepts it (the default Foundry configuration used by the suite does not
///         enforce EIP-3860 on contract-created contracts).
contract L01_InitCodeLimitProbe is Test {
    function _initCode(uint256 size) internal pure returns (bytes memory code) {
        code = new bytes(size);
        (code[0], code[1], code[2], code[3], code[4]) = (0x60, 0x01, 0x60, 0x00, 0xf3); // runtime: one zero byte
    }

    function test_POC_REVIEW_L10_probe_create3InitCodeAboveEip3860() public {
        Create3Harness h = new Create3Harness();
        (bool ok, bytes memory reason) =
            address(h).call(abi.encodeCall(Create3Harness.deploy, (bytes32(uint256(2)), _initCode(49_153))));
        emit log_named_uint("deployed (1) or reverted (0)", ok ? 1 : 0);
        emit log_named_uint("revert data bytes", ok ? 0 : reason.length);
        if (vm.envOr("FOUNDRY_CODE_SIZE_LIMIT", uint256(0)) == 24_576) {
            assertFalse(ok, "mainnet limit: the deployment fails");
            assertEq(reason.length, 0, "with empty revert data");
        }
    }
}
