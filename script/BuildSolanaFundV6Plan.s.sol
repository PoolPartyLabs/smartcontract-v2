// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SolanaFundV6Plan} from "./SolanaFundV6Plan.sol";
import {FundFactoryV6} from "../src/factory/FundFactoryV6.sol";
import {IFundFactory} from "../src/interfaces/IFundFactory.sol";
import {Mandate} from "../src/mandate/Mandate.sol";
import {SolanaMandateV6} from "../src/mandate/SolanaMandateV6.sol";
import {SolanaPolicyV6} from "../src/mandate/SolanaPolicyV6.sol";

/// @notice C2 (S6/S8 input): builds the deploy-day creation plan against the LIVE pinned FundFactoryV6 on Arbitrum —
///         it deploys nothing and has no broadcast cheatcode, so it can never send. It reads the native config written by
///         `three-chain-creation.ts prepare` (asset set = PP_CREATION_ASSETS, DF-1), derives the Hub Mandate with the
///         same code the fork rehearsal proves (`SolanaFundV6Plan`), signs the SolanaBootstrap binding with the EVM
///         Manager key (parameter `DEPLOYER_PRIVATE_KEY`, never printed) and writes:
///           cache/sol-t11/mainnet-plan.json            plan for S6/S7/S8 (copy it out of the repo, record its SHA-256)
///           cache/sol-t11/mainnet-creation-calldata.hex SOLANA_V6_CREATION_CALLDATA_FILE for `fund-v6`
///         Run: forge script script/BuildSolanaFundV6Plan.s.sol --fork-url arbitrum --fork-block-number <head-100>
/// @dev The binding expires `PP_BINDING_TTL_SECONDS` (default 4 h, 15 min .. 24 h) after the pinned block, recorded as
///      the plan's `bindingExpiry` (unix): S6 and the S8 native initializer (binding.rs `now <= expiry`) must both land
///      before it; otherwise rebuild. Another Fund
///      created on the factory first moves `nextCreationNumber` (S6 reverts `CreationNumberTaken`): rebuild.
contract BuildSolanaFundV6Plan is Script, SolanaFundV6Plan {
    error NotArbitrum(uint256 chainId);
    error FactoryNotLive(address factory);
    error ManagerMismatch(address signer, address expected);
    error InvalidBindingTtl(uint256 ttl);
    error CoreCodeNotPinned(bytes32 computed, bytes32 pinned);

    string internal constant PLAN_PATH = "cache/sol-t11/mainnet-plan.json";
    string internal constant CALLDATA_PATH = "cache/sol-t11/mainnet-creation-calldata.hex";

    FundFactoryV6 private factory;
    address private manager;
    uint256 private creationNumber;
    bytes32 private id;
    address private core;
    bytes private mandateBytes;
    bytes private nativeBytes;
    SolanaPolicyV6.Commitment private commitment;

    function run() external {
        if (block.chainid != ARBITRUM) revert NotArbitrum(block.chainid);
        // C1: the reviewed manifest pin, never a factory deployed here.
        factory = FundFactoryV6(
            vm.parseJsonAddress(vm.readFile("script/solana-v6-addresses.json"), ".arbitrum.approvedFactory")
        );
        if (address(factory).code.length == 0) revert FactoryNotLive(address(factory));
        uint256 managerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        manager = vm.addr(managerKey);
        address expected = vm.envAddress("EVM_MANAGER_ADDRESS");
        if (manager != expected) revert ManagerMismatch(manager, expected);
        uint256 ttl = vm.envOr("PP_BINDING_TTL_SECONDS", uint256(4 hours));
        if (ttl < 15 minutes || ttl > 1 days) revert InvalidBindingTtl(ttl);
        _prepare();
        (bytes memory creationCalldata, bytes32 digest, uint256 expiry) = _sign(managerKey, ttl);
        Mandate memory mandateConfig = abi.decode(mandateBytes, (Mandate));
        bytes memory robinhoodCalldata =
            abi.encodeCall(factory.createSpoke, (creationNumber, mandateConfig, _spokeParams(mandateConfig)));
        // The S8 deadline travels in the plan the operator copies out (same "creation" object `_writePlan` serializes).
        vm.serializeUint("creation", "bindingExpiry", expiry);
        _writePlan(PLAN_PATH, factory, core, id, digest, creationCalldata, robinhoodCalldata);
        vm.writeFile(CALLDATA_PATH, vm.toString(creationCalldata));
        console.log("factory (live, pinned)", address(factory));
        console.log("manager", manager);
        console.log("creationNumber", creationNumber);
        console.log("core", core);
        console.log("bindingNonce", factory.bindingNonce(manager));
        console.log("bindingExpiry (unix)", expiry);
        console.log("native assets", abi.decode(nativeBytes, (SolanaMandateV6.Config)).assets.length);
        console.log("creation calldata bytes", creationCalldata.length);
        console.logBytes32(commitment.fundPda);
        console.log("plan", PLAN_PATH);
        console.log("calldata", CALLDATA_PATH);
    }

    function _prepare() private {
        creationNumber = factory.nextCreationNumber();
        id = factory.fundIdOf(ARBITRUM, creationNumber, manager);
        core = factory.addressOf(id, "CoreVault", ARBITRUM);
        SolanaMandateV6.Config memory nativeConfig =
            abi.decode(vm.parseBytes(vm.readFile("cache/sol-t11/native-config.hex")), (SolanaMandateV6.Config));
        Mandate memory mandateConfig = _mandate(factory, id, manager, nativeConfig);
        commitment = _seal(mandateConfig, nativeConfig, core);
        nativeBytes = abi.encode(nativeConfig);
        mandateBytes = abi.encode(mandateConfig);
    }

    function _sign(uint256 managerKey, uint256 ttl)
        private
        returns (bytes memory creationCalldata, bytes32 digest, uint256 expiry)
    {
        Mandate memory mandateConfig = abi.decode(mandateBytes, (Mandate));
        SolanaMandateV6.Config memory nativeConfig = abi.decode(nativeBytes, (SolanaMandateV6.Config));
        FundFactoryV6.Binding memory binding;
        binding.nonce = factory.bindingNonce(manager);
        expiry = block.timestamp + ttl;
        binding.expiry = expiry;
        digest = _bootstrapDigest(factory, core, mandateConfig, nativeConfig, commitment, id, binding.nonce, expiry);
        (uint8 recovery, bytes32 signatureR, bytes32 signatureS) = vm.sign(managerKey, digest);
        binding.signature = abi.encodePacked(signatureR, signatureS, recovery);
        IFundFactory.HubParams memory params;
        params.creationNumber = creationNumber;
        params.seedAmount = SEED_AMOUNT;
        params.coreVaultCreationCode = _v6CoreCode();
        // The linked Core creation code must be the one the live factory pins, or creation reverts on-chain.
        bytes32 pinned = factory.wiring().coreVaultCreationCodeHash;
        if (keccak256(params.coreVaultCreationCode) != pinned) {
            revert CoreCodeNotPinned(keccak256(params.coreVaultCreationCode), pinned);
        }
        creationCalldata =
            abi.encodeCall(factory.createFundV6Committed, (mandateConfig, params, nativeConfig, commitment, binding));
    }
}
