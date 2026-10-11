// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {SolanaV6Deployment} from "./SolanaV6Deployment.sol";
import {FundFactoryV6} from "../src/factory/FundFactoryV6.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFundFactory} from "../src/interfaces/IFundFactory.sol";
import {
    Mandate,
    TokenConfig,
    AdapterConfig,
    PoolConfig,
    SpokeConfig,
    BridgeAdapterConfig
} from "../src/mandate/Mandate.sol";
import {SolanaMandateV6} from "../src/mandate/SolanaMandateV6.sol";
import {SolanaPolicyV6} from "../src/mandate/SolanaPolicyV6.sol";
import {SolanaPdaV6} from "../src/mandate/SolanaPdaV6.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice DEC-188/190/195/200/202, C2: the one reviewed three-chain creation shape (Hub Mandate, native seal, Manager
///         binding digest, Robinhood spoke, plan file) shared by the fork rehearsal
///         (`SolanaThreeChainCreation.fork.t.sol`) and the deploy-day builder (`BuildSolanaFundV6Plan.s.sol`), so the
///         plan signed on deploy day is the plan the rehearsal proves.
abstract contract SolanaFundV6Plan is SolanaV6Deployment {
    uint256 internal constant SEED_AMOUNT = 50e6;
    string internal constant CORE_VAULT_CCTP_LOGIC_ID = "src/core/CoreVaultCctpLogic.sol:CoreVaultCctpLogic";

    /// @dev Hub Mandate: Aave on Arbitrum, Uniswap v4 on Robinhood, every native venue as a pool, 50 USDC minimums.
    function _mandate(FundFactoryV6 factory, bytes32 id, address manager, SolanaMandateV6.Config memory native)
        internal
        view
        returns (Mandate memory result)
    {
        result.manager = manager;
        result.hubChainId = 42_161;
        result.hubWormholeChainId = 23;
        result.usdc = ARB_USDC;
        result.tokens = new TokenConfig[](native.assets.length + 3);
        result.tokens[0] = TokenConfig(42_161, ARB_USDC);
        result.tokens[1] = TokenConfig(4663, RH_USDG);
        result.tokens[2] = TokenConfig(4663, RH_WETH);
        for (uint256 index; index < native.assets.length; ++index) {
            result.tokens[index + 3] = TokenConfig(1, native.assets[index].accountingId);
        }
        address aave = factory.addressOf(id, "AaveV3Adapter", 42_161);
        address robinhood = factory.addressOf(id, "UniswapV4Adapter", 4663);
        result.adapters = new AdapterConfig[](3);
        result.adapters[0] = AdapterConfig(42_161, aave);
        result.adapters[1] = AdapterConfig(4663, robinhood);
        result.adapters[2] = AdapterConfig(1, address(uint160(uint256(native.program))));
        result.pools = new PoolConfig[](native.venues.length + 2);
        result.pools[0] = PoolConfig(42_161, aave, bytes32(uint256(uint160(ARB_USDC))));
        result.pools[1] =
            PoolConfig(4663, robinhood, 0xfcfae8fa0bd6da961bcf5d990f27690932deac4f093e99bf3e871691c6586593);
        for (uint256 index; index < native.venues.length; ++index) {
            result.pools[index + 2] = PoolConfig(
                1,
                result.adapters[2].adapter,
                native.venues[index].pool == 0 ? native.venues[index].reserve : native.venues[index].pool
            );
        }
        result.swapAdapters = new AdapterConfig[](3);
        result.swapAdapters[0] = AdapterConfig(42_161, factory.addressOf(id, "UniswapV3SwapAdapter", 42_161));
        result.swapAdapters[1] = AdapterConfig(4663, factory.addressOf(id, "UniswapV3SwapAdapter", 4663));
        // TODO(decision): canonical EVM role aliases for one multi-instruction native program.
        result.swapAdapters[2] = AdapterConfig(
            1, address(uint160(uint256(keccak256(abi.encode("PoolParty/SolanaSwap/v6", native.program)))))
        );
        result.spokes = new SpokeConfig[](2);
        result.spokes[0] = SpokeConfig(
            4663, 72, bytes32(uint256(uint160(factory.addressOf(id, "SpokeVault", 4663)))), RH_USDG, 50e6, 1600
        );
        result.spokes[1] = SpokeConfig(1, 1, 0, SolanaMandateV6.accountingId(native.usdcMint), 50e6, 1600);
        result.bridgeAdapters = new BridgeAdapterConfig[](4);
        result.bridgeAdapters[0] =
            BridgeAdapterConfig(4663, 42_161, factory.addressOf(id, "AcrossBridgeAdapter", 42_161));
        result.bridgeAdapters[1] = BridgeAdapterConfig(4663, 4663, factory.addressOf(id, "AcrossBridgeAdapter", 4663));
        result.bridgeAdapters[2] = BridgeAdapterConfig(1, 42_161, factory.addressOf(id, "CctpBridgeAdapter", 42_161));
        result.bridgeAdapters[3] = BridgeAdapterConfig(
            1, 1, address(uint160(uint256(keccak256(abi.encode("PoolParty/SolanaCctp/v6", native.program)))))
        );
        result.managementFeeBps = 500;
        result.performanceFeeBps = 1000;
        result.payoutFeeBps = 200;
        result.minFirstDeposit = 50e6;
    }

    /// @dev Native seal: policy hash, Fund PDA, vault ATAs and the transport/spoke fields derived from them.
    function _seal(Mandate memory mandate_, SolanaMandateV6.Config memory native, address core)
        internal
        pure
        returns (SolanaPolicyV6.Commitment memory result)
    {
        result.spokeIndex = 1;
        result.policyHash =
            SolanaPolicyV6.hash(SolanaPolicyV6.hubPolicyHash(mandate_, 1), SolanaPolicyV6.nativePolicyHash(native));
        result.fundPda = SolanaPdaV6.fund(42_161, core, 1, result.policyHash, native.program);
        bytes32 vault = SolanaPdaV6.derive(abi.encodePacked("vault", result.fundPda), native.program);
        native.spoke = SolanaPdaV6.derive(abi.encodePacked("emitter", result.fundPda), native.program);
        result.usdcAta =
            SolanaPdaV6.ata(vault, native.usdcMint, 0x06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9);
        result.stockAta = SolanaPdaV6.ata(
            vault,
            0x07e83582411fea1482f0994b80aa512a97c94f25df283bec5a67a381fc862b4a,
            0x06ddf6e1ee758fde18425dbce46ccddab61afc4d83b90d27febdf928d8a18bfc
        );
        result.nvdaxAta = SolanaPdaV6.ata(
            vault,
            0x07e8a50e140fda5791f4566a957fd3ae3f873e6a3466ffc13d79119dfa9ab50a,
            0x06ddf6e1ee758fde18425dbce46ccddab61afc4d83b90d27febdf928d8a18bfc
        );
        result.wsolAta = SolanaPdaV6.ata(
            vault,
            0x069b8857feab8184fb687f634618c035dac439dc1aeb3b5598a0f00000000001,
            0x06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9
        );
        native.transport.mintRecipient = result.usdcAta;
        native.transport.destinationCaller = vault;
        native.transport.remoteVaultAuthority = vault;
        mandate_.spokes[1].spokeVault = native.spoke;
    }

    /// @dev The SolanaBootstrap EIP-712 digest the Manager signs (FundFactoryV6 domain, version 6).
    function _bootstrapDigest(
        FundFactoryV6 factory,
        address core,
        Mandate memory mandate_,
        SolanaMandateV6.Config memory native,
        SolanaPolicyV6.Commitment memory commitment,
        bytes32 id,
        uint256 nonce,
        uint256 expiry
    ) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PoolParty Solana Fund"),
                keccak256("6"),
                uint256(42_161),
                address(factory)
            )
        );
        return keccak256(
            abi.encodePacked(
                hex"1901",
                domain,
                SolanaPolicyV6.bootstrapHash(
                    factory.BOOTSTRAP_TYPEHASH(),
                    42_161,
                    core,
                    keccak256(abi.encode(mandate_)),
                    native,
                    commitment,
                    id,
                    nonce,
                    expiry
                )
            )
        );
    }

    function _spokeParams(Mandate memory mandate_) internal pure returns (IFundFactory.SpokeParams memory spokeParams) {
        spokeParams.mandateHash = keccak256(abi.encode(mandate_));
        spokeParams.uniswapV4Pools = new PoolKey[](1);
        spokeParams.uniswapV4Pools[0] =
            PoolKey(Currency.wrap(RH_WETH), Currency.wrap(RH_USDG), 500, 10, IHooks(address(0)));
    }

    /// @dev The CoreVaultV6 creation code linked to the deterministic Hub libraries, computed without deploying anything
    ///      (what `_deployV6` links and pins by hash in the factory wiring).
    function _v6CoreCode() internal returns (bytes memory) {
        Deployment memory d = _libraryAddresses(true);
        address cctpLogic = vm.computeCreate2Address(
            LIBRARY_SALT,
            keccak256(_linkedToCoreVaultLibraries("out/CoreVaultCctpLogic.sol/CoreVaultCctpLogic.json", d)),
            DETERMINISTIC_DEPLOYER
        );
        (string[] memory existingIds, address[] memory existingLibraries) = _coreVaultLinks(d);
        string[] memory ids = new string[](7);
        address[] memory libraries = new address[](7);
        for (uint256 index; index < 6; ++index) {
            ids[index] = existingIds[index];
            libraries[index] = existingLibraries[index];
        }
        ids[6] = CORE_VAULT_CCTP_LOGIC_ID;
        libraries[6] = cctpLogic;
        return _linked("out/CoreVaultV6.sol/CoreVaultV6.json", ids, libraries);
    }

    /// @dev Plan schema read by `solana/scripts/three-chain-creation.ts` (export/accept-local/broadcast).
    function _writePlan(
        string memory path,
        FundFactoryV6 factory,
        address core,
        bytes32 id,
        bytes32 digest,
        bytes memory creationCalldata,
        bytes memory robinhoodCalldata
    ) internal {
        string memory output = "creation";
        vm.serializeAddress(output, "factory", address(factory));
        vm.serializeAddress(output, "core", core);
        vm.serializeBytes32(output, "fundId", id);
        vm.serializeBytes32(output, "bindingDigest", digest);
        vm.serializeBytes(output, "calldata", creationCalldata);
        vm.serializeBytes(output, "approveCalldata", abi.encodeCall(IERC20.approve, (address(factory), SEED_AMOUNT)));
        vm.serializeBytes(output, "robinhoodCalldata", robinhoodCalldata);
        vm.writeJson(vm.serializeUint(output, "seedAmount", SEED_AMOUNT), path);
    }
}
