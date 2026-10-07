pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SolanaV6Deployment} from "./SolanaV6Deployment.sol";

/// @notice DEC-188/198: rehearse the v6 factory on each EVM chain without broadcasting.
/// @dev DEC-191/199: CCTP adapter/connector and receiver are per-Fund, created by createFundV6.
contract DeploySolanaV6 is Script, SolanaV6Deployment {
    function run() external returns (V6Deployment memory result) {
        address recipient = vm.envAddress("PROTOCOL_RECIPIENT");
        address guardian = vm.envAddress("ADAPTER_GUARDIAN");
        address signer = vm.envAddress("API_SIGNER");
        address owner = vm.envAddress("REGISTRY_OWNER");
        uint256 rawOpen = vm.envUint("SOLANA_STOCK_SESSION_OPEN");
        uint256 rawClose = vm.envUint("SOLANA_STOCK_SESSION_CLOSE");
        uint256 rawMaxAge = vm.envUint("SOLANA_PRICE_MAX_AGE");
        if (rawOpen > type(uint64).max || rawClose > type(uint64).max || rawMaxAge > type(uint32).max) {
            revert InvalidDeploymentConfiguration();
        }
        uint64 open = uint64(rawOpen);
        uint64 close = uint64(rawClose);
        uint32 maxAge = uint32(rawMaxAge);
        vm.startBroadcast();
        result = _deployV6(recipient, guardian, owner, signer, open, close, maxAge);
        vm.stopBroadcast();
        console.log("chain id", block.chainid);
        console.log("FundFactoryV6", address(result.factory));
        console.log("ManagerRegistry", result.common.managerRegistry);
        console.log("SolanaPriceSourceV6", result.common.priceSource);
        console.log("CoreVaultCctpLogic", result.cctpLogic);
        console.logBytes32(keccak256(result.coreCode));
    }
}
