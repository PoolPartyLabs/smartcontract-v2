pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SolanaV6Deployment} from "../../../script/SolanaV6Deployment.sol";
import {FundFactoryV6} from "../../../src/factory/FundFactoryV6.sol";
import {CoreVaultV6} from "../../../src/core/CoreVaultV6.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {Mandate, TokenConfig, AdapterConfig, PoolConfig, SpokeConfig, BridgeAdapterConfig} from "../../../src/mandate/Mandate.sol";
import {SolanaMandateV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {SolanaPolicyV6} from "../../../src/mandate/SolanaPolicyV6.sol";
import {SolanaPdaV6} from "../../../src/mandate/SolanaPdaV6.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice DEC-188/190/195/200/202: actual wallet consent, fork-only creation, never broadcast.
contract SolanaThreeChainCreationForkTest is Test, SolanaV6Deployment {
    V6Deployment private hub;
    uint256 private managerKey;
    address private manager;
    uint256 private creationNumber;
    bytes32 private id;
    address private core;
    bytes private nativeBytes;
    bytes private mandateBytes;
    SolanaPolicyV6.Commitment private commitment;

    function testActualManagerCreatesAllThreeChains() public {
        managerKey = vm.envUint("PRIVATE_KEY");
        manager = vm.addr(managerKey);
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        vm.startPrank(manager);
        hub = _deployV6(vm.envAddress("PROTOCOL_RECIPIENT"), vm.envAddress("ADAPTER_GUARDIAN"), vm.envAddress("API_SIGNER"), vm.envAddress("API_SIGNER"),
            uint64(vm.envUint("SOLANA_STOCK_SESSION_OPEN")), uint64(vm.envUint("SOLANA_STOCK_SESSION_CLOSE")), 3600);
        vm.stopPrank();
        creationNumber = hub.factory.nextCreationNumber();
        id = hub.factory.fundIdOf(42161, creationNumber, manager);
        core = hub.factory.addressOf(id, "CoreVault", 42161);
        SolanaMandateV6.Config memory nativeConfig = abi.decode(vm.parseBytes(vm.readFile("cache/sol-t11/native-config.hex")), (SolanaMandateV6.Config));
        Mandate memory mandateConfig = _mandate(hub.factory, id, manager, nativeConfig);
        commitment = _seal(mandateConfig, nativeConfig, core);
        nativeBytes = abi.encode(nativeConfig);
        mandateBytes = abi.encode(mandateConfig);
        _createHub();
        _createRobinhood();
    }

    function _createHub() private {
        Mandate memory mandateConfig = abi.decode(mandateBytes, (Mandate));
        SolanaMandateV6.Config memory nativeConfig = abi.decode(nativeBytes, (SolanaMandateV6.Config));
        SolanaPolicyV6.Commitment memory commitmentConfig = commitment;
        FundFactoryV6.Binding memory binding;
        binding.nonce = hub.factory.bindingNonce(manager);
        binding.expiry = block.timestamp + 1 hours;
        bytes32 domain = keccak256(abi.encode(keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"), keccak256("PoolParty Solana Fund"), keccak256("6"), uint256(42161), address(hub.factory)));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domain, SolanaPolicyV6.bootstrapHash(hub.factory.BOOTSTRAP_TYPEHASH(), 42161, core, keccak256(abi.encode(mandateConfig)), nativeConfig, commitmentConfig, id, binding.nonce, binding.expiry)));
        (uint8 recovery, bytes32 signatureR, bytes32 signatureS) = vm.sign(managerKey, digest);
        binding.signature = abi.encodePacked(signatureR, signatureS, recovery);
        IFundFactory.HubParams memory params;
        params.creationNumber = creationNumber;
        params.seedAmount = 50e6;
        params.coreVaultCreationCode = hub.coreCode;
        bytes memory calldata_ = abi.encodeCall(hub.factory.createFundV6Committed, (mandateConfig, params, nativeConfig, commitmentConfig, binding));
        _writePlan(calldata_, digest);
        deal(ARB_USDC, manager, 50e6);
        vm.startPrank(manager);
        IERC20(ARB_USDC).approve(address(hub.factory), 50e6);
        IFundFactory.FundAddresses memory result = hub.factory.createFundV6Committed(mandateConfig, params, nativeConfig, commitmentConfig, binding);
        vm.stopPrank();
        assertEq(result.coreVault, core);
        assertEq(CoreVaultV6(core).nativeMandateHash(), SolanaMandateV6.hash(nativeConfig));
        assertEq(IERC20(ARB_USDC).balanceOf(core), 49e6);
        vm.writeFile("cache/sol-t11/hub-created", "PASS");
    }

    function _spokeParams() private view returns (IFundFactory.SpokeParams memory spokeParams) {
        Mandate memory mandateConfig = abi.decode(mandateBytes, (Mandate));
        spokeParams.mandateHash = keccak256(abi.encode(mandateConfig));
        spokeParams.uniswapV4Pools = new PoolKey[](1);
        spokeParams.uniswapV4Pools[0] = PoolKey(Currency.wrap(RH_WETH), Currency.wrap(RH_USDG), 500, 10, IHooks(address(0)));
    }

    function _writePlan(bytes memory calldata_, bytes32 digest) private {
        string memory output = "creation";
        vm.serializeAddress(output, "factory", address(hub.factory));
        vm.serializeAddress(output, "core", core);
        vm.serializeBytes32(output, "fundId", id);
        vm.serializeBytes32(output, "bindingDigest", digest);
        vm.serializeBytes(output, "calldata", calldata_);
        vm.serializeBytes(output, "approveCalldata", abi.encodeCall(IERC20.approve, (address(hub.factory), uint256(50e6))));
        Mandate memory mandateConfig = abi.decode(mandateBytes, (Mandate));
        vm.serializeBytes(output, "robinhoodCalldata", abi.encodeCall(hub.factory.createSpoke, (creationNumber, mandateConfig, _spokeParams())));
        vm.writeJson(vm.serializeUint(output, "seedAmount", 50e6), "cache/sol-t11/creation.json");
    }

    function _createRobinhood() private {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));
        vm.startPrank(manager);
        V6Deployment memory spoke = _deployV6(vm.envAddress("PROTOCOL_RECIPIENT"), vm.envAddress("ADAPTER_GUARDIAN"), vm.envAddress("API_SIGNER"), vm.envAddress("API_SIGNER"), 1791379800, 1791403200, 3600);
        vm.stopPrank();
        assertEq(address(spoke.factory), address(hub.factory));
        Mandate memory mandateConfig = abi.decode(mandateBytes, (Mandate));
        IFundFactory.SpokeParams memory spokeParams = _spokeParams();
        vm.prank(manager);
        IFundFactory.ChainAddresses memory deployed = spoke.factory.createSpoke(creationNumber, mandateConfig, spokeParams);
        assertEq(deployed.spokeVault, address(uint160(uint256(mandateConfig.spokes[0].spokeVault))));
        vm.writeFile("cache/sol-t11/robinhood-created", "PASS");
    }

    function _mandate(FundFactoryV6 factory, bytes32 id, address manager, SolanaMandateV6.Config memory native) private view returns (Mandate memory result) {
        result.manager = manager;
        result.hubChainId = 42161;
        result.hubWormholeChainId = 23;
        result.usdc = ARB_USDC;
        result.tokens = new TokenConfig[](native.assets.length + 3);
        result.tokens[0] = TokenConfig(42161, ARB_USDC);
        result.tokens[1] = TokenConfig(4663, RH_USDG);
        result.tokens[2] = TokenConfig(4663, RH_WETH);
        for (uint256 index; index < native.assets.length; ++index) result.tokens[index + 3] = TokenConfig(1, native.assets[index].accountingId);
        address aave = factory.addressOf(id, "AaveV3Adapter", 42161);
        address robinhood = factory.addressOf(id, "UniswapV4Adapter", 4663);
        result.adapters = new AdapterConfig[](3);
        result.adapters[0] = AdapterConfig(42161, aave);
        result.adapters[1] = AdapterConfig(4663, robinhood);
        result.adapters[2] = AdapterConfig(1, address(uint160(uint256(native.program))));
        result.pools = new PoolConfig[](native.venues.length + 2);
        result.pools[0] = PoolConfig(42161, aave, bytes32(uint256(uint160(ARB_USDC))));
        result.pools[1] = PoolConfig(4663, robinhood, 0xfcfae8fa0bd6da961bcf5d990f27690932deac4f093e99bf3e871691c6586593);
        for (uint256 index; index < native.venues.length; ++index) result.pools[index + 2] = PoolConfig(1, result.adapters[2].adapter, native.venues[index].pool == 0 ? native.venues[index].reserve : native.venues[index].pool);
        result.swapAdapters = new AdapterConfig[](3);
        result.swapAdapters[0] = AdapterConfig(42161, factory.addressOf(id, "UniswapV3SwapAdapter", 42161));
        result.swapAdapters[1] = AdapterConfig(4663, factory.addressOf(id, "UniswapV3SwapAdapter", 4663));
        // TODO(decision): canonical EVM role aliases for one multi-instruction native program.
        result.swapAdapters[2] = AdapterConfig(1, address(uint160(uint256(keccak256(abi.encode("PoolParty/SolanaSwap/v6", native.program))))));
        result.spokes = new SpokeConfig[](2);
        result.spokes[0] = SpokeConfig(4663, 72, bytes32(uint256(uint160(factory.addressOf(id, "SpokeVault", 4663)))), RH_USDG, 50e6, 1600);
        result.spokes[1] = SpokeConfig(1, 1, 0, SolanaMandateV6.accountingId(native.usdcMint), 50e6, 1600);
        result.bridgeAdapters = new BridgeAdapterConfig[](4);
        result.bridgeAdapters[0] = BridgeAdapterConfig(4663, 42161, factory.addressOf(id, "AcrossBridgeAdapter", 42161));
        result.bridgeAdapters[1] = BridgeAdapterConfig(4663, 4663, factory.addressOf(id, "AcrossBridgeAdapter", 4663));
        result.bridgeAdapters[2] = BridgeAdapterConfig(1, 42161, factory.addressOf(id, "CctpBridgeAdapter", 42161));
        result.bridgeAdapters[3] = BridgeAdapterConfig(1, 1, address(uint160(uint256(keccak256(abi.encode("PoolParty/SolanaCctp/v6", native.program))))));
        result.managementFeeBps = 500;
        result.performanceFeeBps = 1000;
        result.payoutFeeBps = 200;
        result.minFirstDeposit = 50e6;
    }

    function _seal(Mandate memory mandate_, SolanaMandateV6.Config memory native, address core) private pure returns (SolanaPolicyV6.Commitment memory result) {
        result.spokeIndex = 1;
        result.policyHash = SolanaPolicyV6.hash(SolanaPolicyV6.hubPolicyHash(mandate_, 1), SolanaPolicyV6.nativePolicyHash(native));
        result.fundPda = SolanaPdaV6.fund(42161, core, 1, result.policyHash, native.program);
        bytes32 vault = SolanaPdaV6.derive(abi.encodePacked("vault", result.fundPda), native.program);
        native.spoke = SolanaPdaV6.derive(abi.encodePacked("emitter", result.fundPda), native.program);
        result.usdcAta = SolanaPdaV6.ata(vault, native.usdcMint, 0x06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9);
        result.stockAta = SolanaPdaV6.ata(vault, 0x07e83582411fea1482f0994b80aa512a97c94f25df283bec5a67a381fc862b4a, 0x06ddf6e1ee758fde18425dbce46ccddab61afc4d83b90d27febdf928d8a18bfc);
        result.nvdaxAta = SolanaPdaV6.ata(vault, 0x07e8a50e140fda5791f4566a957fd3ae3f873e6a3466ffc13d79119dfa9ab50a, 0x06ddf6e1ee758fde18425dbce46ccddab61afc4d83b90d27febdf928d8a18bfc);
        result.wsolAta = SolanaPdaV6.ata(vault, 0x069b8857feab8184fb687f634618c035dac439dc1aeb3b5598a0f00000000001, 0x06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9);
        native.transport.mintRecipient = result.usdcAta;
        native.transport.destinationCaller = vault;
        native.transport.remoteVaultAuthority = vault;
        mandate_.spokes[1].spokeVault = native.spoke;
    }
}
