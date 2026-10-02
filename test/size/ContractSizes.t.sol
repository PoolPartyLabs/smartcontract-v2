// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm, console2} from "forge-std/Test.sol";

/// @title ContractSizesTest
/// @notice DEC-131 items 2 and 3 (b3, b4): every production contract and every linked library fits the smallest code
///         limit across the supported chains, and the check is a test of the suite, not a CI step. The limit is
///         Arbitrum One's EIP-170 24,576 bytes, applied everywhere, Robinhood Chain (98,304) included.
/// @dev Completeness: every top-level `contract` and `library` declared under `src/` must be listed in `_entries`, so
///      a new one fails `test_DEC131_everySourceDeclarationIsListed` until it is classified and sized here. Interfaces
///      and abstract contracts have no code of their own (theirs lands in the listed contracts that inherit them).
///      A margin under 1,000 bytes is logged as a warning, not a failure: DEC-131 left a minimum reserve open.
/// @dev Run: forge test --match-path test/size/ContractSizes.t.sol -vv (fresh build; the sizes are of this build).
contract ContractSizesTest is Test {
    /// @notice EIP-170 on Arbitrum One, the smallest code limit across the supported chains (DEC-131, b4).
    uint256 internal constant CODE_LIMIT = 24_576;

    /// @notice Margin below which the log flags a contract (planning rule; DEC-131 left the reserve open).
    uint256 internal constant LOW_MARGIN = 1000;

    /// @notice Largest deployed code of an inlined library: the bare stub every library compiles to (85 bytes with
    ///         this compiler and metadata). A library above it has an external entry point, so it must be deployed,
    ///         linked and pinned, and belongs under `Kind.LinkedLibrary`.
    uint256 internal constant INLINED_STUB_MAX = 128;

    enum Kind {
        Contract,
        LinkedLibrary,
        InlinedLibrary
    }

    struct Entry {
        string id;
        Kind kind;
    }

    /// @dev Every top-level contract and library under `src/`, as `<path>:<name>`.
    function _entries() internal pure returns (Entry[] memory e) {
        e = new Entry[](26);
        uint256 i;
        // Contracts deployed on chain (the factory's roles, the protocol-level contracts and what they deploy).
        e[i++] = Entry("src/adapters/AaveV3Adapter.sol:AaveV3Adapter", Kind.Contract);
        e[i++] = Entry("src/adapters/AcrossBridgeAdapter.sol:AcrossBridgeAdapter", Kind.Contract);
        e[i++] = Entry("src/adapters/UniswapV4Adapter.sol:UniswapV4Adapter", Kind.Contract);
        e[i++] = Entry("src/core/CoreVault.sol:CoreVault", Kind.Contract);
        e[i++] = Entry("src/core/ManagerFeeVault.sol:ManagerFeeVault", Kind.Contract);
        e[i++] = Entry("src/core/ManagerRegistry.sol:ManagerRegistry", Kind.Contract);
        e[i++] = Entry("src/core/ShareToken.sol:ShareToken", Kind.Contract);
        e[i++] = Entry("src/core/TransitEscrow.sol:TransitEscrow", Kind.Contract);
        e[i++] = Entry("src/factory/Create3Deployer.sol:Create3Deployer", Kind.Contract);
        e[i++] = Entry("src/factory/FundFactory.sol:FundFactory", Kind.Contract);
        e[i++] = Entry("src/report/ChainlinkPriceSource.sol:ChainlinkPriceSource", Kind.Contract);
        e[i++] = Entry("src/report/ValueReportReceiver.sol:ValueReportReceiver", Kind.Contract);
        e[i++] = Entry("src/spoke/SpokeVault.sol:SpokeVault", Kind.Contract);
        // Linked libraries: deployed once per chain through the deterministic deployer (script/FactoryDeployment.sol).
        e[i++] = Entry("src/core/CoreVaultLogic.sol:CoreVaultLogic", Kind.LinkedLibrary);
        e[i++] = Entry("src/spoke/SpokeCrossChainLib.sol:SpokeCrossChainLib", Kind.LinkedLibrary);
        e[i++] = Entry("src/spoke/SpokeUnwindLib.sol:SpokeUnwindLib", Kind.LinkedLibrary);
        // Inlined libraries: internal functions only, compiled into the contracts that use them.
        e[i++] = Entry("src/factory/CodeStore.sol:CodeStore", Kind.InlinedLibrary);
        e[i++] = Entry("src/factory/Create3.sol:Create3", Kind.InlinedLibrary);
        e[i++] = Entry("src/libraries/BridgeFeeRule.sol:BridgeFeeRule", Kind.InlinedLibrary);
        e[i++] = Entry("src/libraries/IncomeAccumulator.sol:IncomeAccumulator", Kind.InlinedLibrary);
        e[i++] = Entry("src/libraries/ReportCodec.sol:ReportCodec", Kind.InlinedLibrary);
        e[i++] = Entry("src/libraries/ShareMath.sol:ShareMath", Kind.InlinedLibrary);
        e[i++] = Entry("src/libraries/TransitMessage.sol:TransitMessage", Kind.InlinedLibrary);
        e[i++] = Entry("src/mandate/Mandate.sol:MandateLib", Kind.InlinedLibrary);
        e[i++] = Entry("src/spoke/SpokeLedger.sol:SpokeLedger", Kind.InlinedLibrary);
        e[i++] = Entry("src/spoke/SpokeVaultTypes.sol:SpokeVaultTypes", Kind.InlinedLibrary);
        assert(i == e.length);
    }

    function test_DEC131_everyContractAndLinkedLibraryFitsTheSmallestCodeLimit() public view {
        Entry[] memory e = _entries();
        for (uint256 i; i < e.length; ++i) {
            if (e[i].kind == Kind.InlinedLibrary) continue;
            uint256 size = vm.getDeployedCode(e[i].id).length;
            assertGt(size, 0, string.concat(e[i].id, " has no deployed code"));
            assertLe(size, CODE_LIMIT, string.concat(e[i].id, " exceeds the 24,576-byte limit"));
            if (e[i].kind == Kind.LinkedLibrary) {
                assertGt(
                    size, INLINED_STUB_MAX, string.concat(e[i].id, " has no external entry point: list it as inlined")
                );
            }
            uint256 margin = CODE_LIMIT - size;
            console2.log(string.concat(e[i].id, " size / margin"), size, margin);
            if (margin < LOW_MARGIN) console2.log("WARNING: margin below 1,000 bytes", e[i].id);
        }
    }

    function test_DEC131_inlinedLibrariesHaveNoEntryPoint() public view {
        Entry[] memory e = _entries();
        for (uint256 i; i < e.length; ++i) {
            if (e[i].kind != Kind.InlinedLibrary) continue;
            uint256 size = vm.getDeployedCode(e[i].id).length;
            assertLe(size, INLINED_STUB_MAX, string.concat(e[i].id, " has an external entry point: list it as linked"));
        }
    }

    /// @dev Walks `src/` and reads every top-level declaration (forge fmt keeps them at column 0).
    function test_DEC131_everySourceDeclarationIsListed() public view {
        Entry[] memory e = _entries();
        bool[] memory seen = new bool[](e.length);
        string memory root = string.concat(vm.projectRoot(), "/");
        Vm.DirEntry[] memory files = vm.readDir("src", 8);
        for (uint256 f; f < files.length; ++f) {
            if (files[f].isDir || !_endsWith(bytes(files[f].path), ".sol")) continue;
            string memory path = vm.replace(files[f].path, root, "");
            string[] memory lines = vm.split(vm.readFile(files[f].path), "\n");
            for (uint256 l; l < lines.length; ++l) {
                string memory name = _declaredName(lines[l]);
                if (bytes(name).length == 0) continue;
                string memory id = string.concat(path, ":", name);
                uint256 at = _indexOf(e, id);
                assertTrue(at < e.length, string.concat(id, " is not listed in test/size/ContractSizes.t.sol"));
                seen[at] = true;
            }
        }
        for (uint256 i; i < e.length; ++i) {
            assertTrue(seen[i], string.concat(e[i].id, " is listed but no longer declared under src/"));
        }
    }

    /// @dev The name of a top-level `contract` or `library` declared on `line`, or "" for any other line.
    function _declaredName(string memory line) internal pure returns (string memory) {
        bytes memory b = bytes(line);
        uint256 start;
        if (_startsWith(b, "contract ")) start = 9;
        else if (_startsWith(b, "library ")) start = 8;
        else return "";
        uint256 end = start;
        while (end < b.length && b[end] != " " && b[end] != "{") ++end;
        bytes memory name = new bytes(end - start);
        for (uint256 i; i < name.length; ++i) {
            name[i] = b[start + i];
        }
        return string(name);
    }

    function _startsWith(bytes memory b, bytes memory prefix) internal pure returns (bool) {
        if (b.length < prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (b[i] != prefix[i]) return false;
        }
        return true;
    }

    function _endsWith(bytes memory b, bytes memory suffix) internal pure returns (bool) {
        if (b.length < suffix.length) return false;
        uint256 offset = b.length - suffix.length;
        for (uint256 i; i < suffix.length; ++i) {
            if (b[offset + i] != suffix[i]) return false;
        }
        return true;
    }

    function _indexOf(Entry[] memory e, string memory id) internal pure returns (uint256) {
        for (uint256 i; i < e.length; ++i) {
            if (keccak256(bytes(e[i].id)) == keccak256(bytes(id))) return i;
        }
        return type(uint256).max;
    }
}
