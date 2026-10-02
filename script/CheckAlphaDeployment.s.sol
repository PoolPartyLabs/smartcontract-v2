pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {CreateFund} from "./CreateFund.s.sol";
import {FundFactory} from "../src/factory/FundFactory.sol";
import {IFundFactory} from "../src/interfaces/IFundFactory.sol";
import {Mandate, MandateLib} from "../src/mandate/Mandate.sol";
import {CoreVault} from "../src/core/CoreVault.sol";
import {ChainlinkPriceSource} from "../src/report/ChainlinkPriceSource.sol";

contract CheckAlphaDeployment is CreateFund {
    error CheckFailed(string field, address target);

    function _code(string memory role, address target) internal view {
        if (target.code.length == 0) revert WiringHasNoCode(role, target);
    }

    function run() external override {
        FundFactory factory = FundFactory(vm.envAddress("FUND_FACTORY"));
        address manager = vm.envAddress("MANAGER");
        uint256 number = vm.envUint("CREATION_NUMBER");
        bytes32 expectedHash = vm.envBytes32("MANDATE_HASH");
        _code("factory", address(factory));
        address create3 = vm.computeCreate2Address(
            CREATE3_DEPLOYER_SALT, keccak256(vm.getCode("Create3Deployer.sol:Create3Deployer")), DETERMINISTIC_DEPLOYER
        );
        (bool predicted, bytes memory result) = create3.staticcall(
            abi.encodeWithSignature("addressOf(address,bytes32)", vm.envAddress("DEPLOYER_ADDRESS"), FACTORY_SALT)
        );
        if (!predicted || abi.decode(result, (address)) != address(factory)) {
            revert CheckFailed("predicted factory address", address(factory));
        }
        IFundFactory.ProtocolWiring memory wiring = factory.wiring();
        _checkWiring(wiring);
        _bytes32Getter(
            wiring.wormholeCore,
            "chainId()",
            bytes32(uint256(block.chainid == ARBITRUM ? WORMHOLE_ARBITRUM : WORMHOLE_ROBINHOOD))
        );
        Deployment memory libraries = _libraryAddresses(block.chainid == ARBITRUM);
        _checkFactory(factory, wiring, libraries);
        bytes32 fundId = factory.fundIdOf(ARBITRUM, number, manager);
        Mandate memory mandate = _buildMandate(factory, fundId, _plan(manager));
        if (MandateLib.hash(mandate) != expectedHash) revert CheckFailed("Mandate inputs", address(factory));
        address core = factory.addressOf(fundId, "CoreVault", ARBITRUM);
        _checkChain(factory, fundId, core, manager, expectedHash, wiring, libraries);
        if (block.chainid == ARBITRUM) {
            _checkCore(factory, number, core, mandate, expectedHash, wiring, libraries);
        }
        console.log("ALPHA CHECK PASS chain", block.chainid);
        console.log("FundFactory", address(factory));
        console.log("Core Vault (hub)", core);
        console.logBytes32(fundId);
        console.logBytes32(expectedHash);
    }

    function _checkFactory(FundFactory factory, IFundFactory.ProtocolWiring memory wiring, Deployment memory libraries)
        internal
        view
    {
        IFundFactory.ProtocolWiring memory expected = _chainWiring(block.chainid);
        expected.protocolRecipient = vm.envAddress("PROTOCOL_RECIPIENT");
        expected.guardian = vm.envAddress("ADAPTER_GUARDIAN");
        expected.apiSigner = vm.envAddress("API_SIGNER");
        expected.spokeCrossChainLib = libraries.spokeCrossChainLib;
        if (block.chainid == ARBITRUM) {
            expected.managerRegistry = wiring.managerRegistry;
            expected.priceSource = wiring.priceSource;
            expected.coreVaultLogic = libraries.coreVaultLogic;
            expected.coreVaultCreationCodeHash = keccak256(_coreVaultCreationCode(libraries));
            _addressGetter(wiring.managerRegistry, "owner()", vm.envOr("REGISTRY_OWNER", expected.apiSigner));
            _checkPrices(wiring.priceSource);
        }
        if (keccak256(abi.encode(wiring)) != keccak256(abi.encode(expected))) {
            revert CheckFailed("factory wiring", address(factory));
        }
        _code("TransitEscrow implementation", factory.transitEscrowImplementation());
        _code(
            "Create3Deployer",
            vm.computeCreate2Address(
                CREATE3_DEPLOYER_SALT,
                keccak256(vm.getCode("Create3Deployer.sol:Create3Deployer")),
                DETERMINISTIC_DEPLOYER
            )
        );
        if (factory.creationCodeHash("SpokeVault") != keccak256(_spokeVaultCreationCode(libraries))) {
            revert CheckFailed("Spoke Vault creation code / links", address(factory));
        }
        _stores(factory, "SpokeVault");
        string[5] memory roles =
            ["UniswapV4Adapter", "AcrossBridgeAdapter", "UniswapV3SwapAdapter", "AaveV3Adapter", "ValueReportReceiver"];
        for (uint256 index; index < roles.length; ++index) {
            if (block.chainid != ARBITRUM && index >= 3) continue;
            if (
                factory.creationCodeHash(bytes32(bytes(roles[index])))
                    != keccak256(vm.getCode(string.concat(roles[index], ".sol:", roles[index])))
            ) {
                revert CheckFailed("stored creation code", address(factory));
            }
            _stores(factory, bytes32(bytes(roles[index])));
        }
        _code("SpokeCrossChainLib", libraries.spokeCrossChainLib);
        _code("SpokeUnwindLib", libraries.spokeUnwindLib);
        _code("SpokeIncomeLib", libraries.spokeIncomeLib);
        if (block.chainid == ARBITRUM) {
            _code("CoreVaultLogic", libraries.coreVaultLogic);
            _code("CoreVaultTransitLogic", libraries.coreVaultTransitLogic);
            _code("CoreVaultIncomeLogic", libraries.coreVaultIncomeLogic);
            _code("CoreVaultPayoutLogic", libraries.coreVaultPayoutLogic);
            _link(libraries.coreVaultLogic, libraries.coreVaultIncomeLogic);
            _link(libraries.coreVaultPayoutLogic, libraries.coreVaultLogic);
            _link(libraries.coreVaultPayoutLogic, libraries.coreVaultIncomeLogic);
            _link(libraries.coreVaultTransitLogic, libraries.coreVaultLogic);
            _link(libraries.coreVaultTransitLogic, libraries.coreVaultIncomeLogic);
            _link(libraries.coreVaultTransitLogic, libraries.coreVaultPayoutLogic);
        }
    }

    function _stores(FundFactory factory, bytes32 role) private view {
        bytes32 slot = keccak256(abi.encode(role, uint256(4)));
        uint256 count = uint256(vm.load(address(factory), slot));
        if (count == 0 || count > 2) revert CheckFailed("CodeStore count", address(factory));
        uint256 start = uint256(keccak256(abi.encode(slot)));
        bytes memory creationCode;
        for (uint256 index; index < count; ++index) {
            address store = address(uint160(uint256(vm.load(address(factory), bytes32(start + index)))));
            _code("CodeStore", store);
            bytes memory runtime = store.code;
            if (runtime[0] != 0) revert CheckFailed("CodeStore prefix", store);
            bytes memory chunk = new bytes(runtime.length - 1);
            for (uint256 offset; offset < chunk.length; ++offset) {
                chunk[offset] = runtime[offset + 1];
            }
            creationCode = bytes.concat(creationCode, chunk);
            console.log("CodeStore", store);
        }
        if (keccak256(creationCode) != factory.creationCodeHash(role)) {
            revert CheckFailed("CodeStore hash", address(factory));
        }
    }

    function _checkChain(
        FundFactory factory,
        bytes32 fundId,
        address core,
        address manager,
        bytes32 hash,
        IFundFactory.ProtocolWiring memory wiring,
        Deployment memory libraries
    ) internal view {
        address vault = factory.addressOf(fundId, "SpokeVault", block.chainid);
        _bytes32Getter(vault, "fundId()", fundId);
        _bytes32Getter(vault, "mandateHash()", hash);
        _addressGetter(vault, "manager()", manager);
        _addressGetter(vault, "coreVault()", core);
        _addressGetter(vault, "baseToken()", wiring.baseToken);
        _addressGetter(vault, "wormholeCore()", block.chainid == ARBITRUM ? address(0) : wiring.wormholeCore);
        _addressGetter(vault, "acrossSpokePool()", wiring.acrossSpokePool);
        _addressGetter(vault, "transitEscrowImplementation()", factory.transitEscrowImplementation());
        _link(vault, libraries.spokeCrossChainLib);
        _link(vault, libraries.spokeUnwindLib);
        _link(vault, libraries.spokeIncomeLib);
        address adapter = _adapter(factory, fundId, "UniswapV4Adapter", vault, wiring.guardian);
        _addressGetter(adapter, "poolManager()", wiring.uniswapV4PoolManager);
        _addressGetter(adapter, "positionManager()", wiring.uniswapV4PositionManager);
        _addressGetter(adapter, "stateView()", wiring.uniswapV4StateView);
        _addressGetter(adapter, "permit2()", wiring.permit2);
        adapter =
            _adapter(factory, fundId, "AcrossBridgeAdapter", block.chainid == ARBITRUM ? core : vault, wiring.guardian);
        _addressGetter(adapter, "spokePool()", wiring.acrossSpokePool);
        adapter = _adapter(factory, fundId, "UniswapV3SwapAdapter", vault, wiring.guardian);
        _addressGetter(adapter, "v3Factory()", wiring.uniswapV3Factory);
        _addressGetter(adapter, "swapRouter()", wiring.uniswapV3SwapRouter02);
        _addressGetter(adapter, "quoterV2()", wiring.uniswapV3QuoterV2);
        _addressGetter(adapter, "routeSigner()", wiring.apiSigner);
        if (block.chainid == ARBITRUM && vm.envOr("HUB_AAVE_ASSET", ARB_USDC) != address(0)) {
            adapter = _adapter(factory, fundId, "AaveV3Adapter", vault, wiring.guardian);
            _addressGetter(adapter, "pool()", wiring.aaveV3Pool);
        }
        console.log("Spoke Vault", vault);
    }

    function _checkCore(
        FundFactory factory,
        uint256 number,
        address core,
        Mandate memory mandate,
        bytes32 hash,
        IFundFactory.ProtocolWiring memory wiring,
        Deployment memory libraries
    ) internal view {
        if (factory.fundByNumber(number) != core || !factory.isFund(core)) {
            revert CheckFailed("fund registry", core);
        }
        _bytes32Getter(core, "mandateHash()", hash);
        if (MandateLib.hash(CoreVault(core).mandate()) != MandateLib.hash(mandate)) {
            revert CheckFailed("stored Mandate", core);
        }
        _addressGetter(core, "factory()", address(factory));
        _addressGetter(core, "manager()", mandate.manager);
        _addressGetter(core, "usdc()", wiring.baseToken);
        _addressGetter(core, "shareToken()", vm.computeCreateAddress(core, 1));
        _addressGetter(core, "managerFeeVault()", vm.computeCreateAddress(core, 2));
        _addressGetter(core, "managerRegistry()", wiring.managerRegistry);
        _addressGetter(core, "priceSource()", wiring.priceSource);
        _addressGetter(core, "protocolRecipient()", wiring.protocolRecipient);
        _addressGetter(core, "wormholeCore()", wiring.wormholeCore);
        _addressGetter(core, "acrossSpokePool()", wiring.acrossSpokePool);
        _addressGetter(core, "hubSpokeVault()", factory.addressOf(CoreVault(core).fundId(), "SpokeVault", ARBITRUM));
        _addressGetter(CoreVault(core).shareToken(), "coreVault()", core);
        _addressGetter(CoreVault(core).managerFeeVault(), "fund()", core);
        _addressGetter(CoreVault(core).managerFeeVault(), "manager()", mandate.manager);
        address receiver = factory.addressOf(CoreVault(core).fundId(), "ValueReportReceiver", ARBITRUM);
        _addressGetter(core, "reportReceiver()", receiver);
        _addressGetter(receiver, "coreVault()", core);
        _addressGetter(receiver, "coreBridge()", wiring.wormholeCore);
        _bytes32Getter(receiver, "fundId()", CoreVault(core).fundId());
        _link(core, libraries.coreVaultLogic);
        _link(core, libraries.coreVaultTransitLogic);
        _link(core, libraries.coreVaultIncomeLogic);
        _link(core, libraries.coreVaultPayoutLogic);
    }

    function _checkPrices(address source) internal view {
        ChainlinkPriceSource prices = ChainlinkPriceSource(source);
        _code("ETH/USD feed", ARB_ETH_USD_FEED);
        if (
            prices.aggregatorOf(ARB_WETH) != ARB_ETH_USD_FEED || prices.aggregatorOf(RH_WETH) != ARB_ETH_USD_FEED
                || !prices.isFixed(ARB_USDC) || !prices.isFixed(RH_USDG)
        ) revert CheckFailed("price configuration", source);
        if (
            prices.maxPriceAge(ARB_WETH) != ETH_USD_MAX_PRICE_AGE
                || prices.maxPriceAge(RH_WETH) != ETH_USD_MAX_PRICE_AGE
        ) {
            revert CheckFailed("price maximum age", source);
        }
    }

    function _adapter(FundFactory factory, bytes32 fundId, bytes32 role, address vault, address guardian)
        internal
        view
        returns (address adapter)
    {
        adapter = factory.addressOf(fundId, role, block.chainid);
        _addressGetter(adapter, "vault()", vault);
        _addressGetter(adapter, "guardian()", guardian);
    }

    function _addressGetter(address target, string memory signature, address expected) internal view {
        _bytes32Getter(target, signature, bytes32(uint256(uint160(expected))));
    }

    function _bytes32Getter(address target, string memory signature, bytes32 expected) internal view {
        _code(signature, target);
        (bool success, bytes memory result) = target.staticcall(abi.encodeWithSignature(signature));
        if (!success || result.length != 32 || abi.decode(result, (bytes32)) != expected) {
            revert CheckFailed(signature, target);
        }
    }

    function _link(address target, address libraryAddress) internal view {
        _code("linked library", libraryAddress);
        if (!vm.contains(vm.toString(target.code), vm.replace(vm.toLowercase(vm.toString(libraryAddress)), "0x", ""))) {
            revert CheckFailed("runtime library link", target);
        }
    }
}
