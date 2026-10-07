pragma solidity 0.8.28;

import {Mandate, SpokeConfig} from "../mandate/Mandate.sol";
import {SolanaMandateV6} from "../mandate/SolanaMandateV6.sol";
import {CctpRoute} from "../interfaces/ICctpCoreVault.sol";
import {CctpBridgeAdapter} from "../adapters/CctpBridgeAdapter.sol";
import {CctpReceiveConnector} from "../core/CctpReceiveConnector.sol";
import {Create3} from "./Create3.sol";
import {CoreVaultConfig} from "../core/CoreVaultTypes.sol";
import {CodeStore} from "./CodeStore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ShareMath} from "../libraries/ShareMath.sol";
import {ICoreVaultLifecycle} from "../interfaces/ICoreVaultLifecycle.sol";

/// @notice DEC-188, DEC-191, DEC-199: linked deployment keeps immutable CCTP wiring outside factory runtime.
library SolanaDeploymentV6 {
    using SafeERC20 for IERC20;
    address internal constant MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address internal constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    bytes32 internal constant ADAPTER_ROLE = "CctpBridgeAdapter";
    bytes32 internal constant CONNECTOR_ROLE = "CctpReceiveConnector";

    error InvalidSolanaBinding();

    function seed(address core, address token, uint256 amount, uint16 feeBps) public {
        (, uint256 principal, uint256 fee) = ShareMath.previewDeposit(amount, feeBps, ShareMath.INITIAL_SHARE_PRICE);
        IERC20(token).safeTransferFrom(msg.sender, address(this), principal + fee);
        IERC20(token).forceApprove(core, principal + fee);
        ICoreVaultLifecycle(core).seed(amount);
    }

    function deployReports(
        SolanaMandateV6.Config memory native,
        bytes32 fundId,
        address core,
        address bridge,
        SpokeConfig[] memory spokes,
        address[] memory registryCode,
        address[] memory receiverCode
    ) public {
        address registry = Create3.deploy(
            keccak256(abi.encode(fundId, bytes32("SolanaRegistryV6"), block.chainid)),
            abi.encodePacked(CodeStore.read(registryCode), abi.encode(native))
        );
        Create3.deploy(
            keccak256(abi.encode(fundId, bytes32("ValueReportReceiver"), block.chainid)),
            abi.encodePacked(CodeStore.read(receiverCode), abi.encode(bridge, core, fundId, spokes, registry))
        );
    }

    function bindingHash(
        SolanaMandateV6.Config memory native,
        address fund,
        uint256 nonce,
        uint256 expiry,
        bytes32 typehash
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                typehash,
                native.managerKey,
                fund,
                native.spoke,
                native.chainId,
                SolanaMandateV6.hash(native),
                nonce,
                expiry
            )
        );
    }

    function deployCore(Mandate memory mandate, CoreVaultConfig memory config, address registry, bytes memory code)
        public
        returns (address)
    {
        bytes32 id = config.fundId;
        address adapter = Create3.addressOf(address(this), keccak256(abi.encode(id, ADAPTER_ROLE, block.chainid)));
        address connector = Create3.addressOf(address(this), keccak256(abi.encode(id, CONNECTOR_ROLE, block.chainid)));
        return Create3.deploy(
            keccak256(abi.encode(id, bytes32("CoreVault"), block.chainid)),
            abi.encodePacked(code, abi.encode(mandate, config, registry, adapter, connector))
        );
    }

    function store(SolanaMandateV6.Config storage pending, SolanaMandateV6.Config memory native) public {
        pending.program = native.program;
        pending.spoke = native.spoke;
        pending.usdcMint = native.usdcMint;
        pending.managerKey = native.managerKey;
        pending.chainId = native.chainId;
        pending.transport = native.transport;
        pending.swapPolicyHash = native.swapPolicyHash;
        for (uint256 index; index < native.assets.length; ++index) {
            pending.assets.push(native.assets[index]);
        }
        for (uint256 index; index < native.venues.length; ++index) {
            pending.venues.push(native.venues[index]);
        }
    }

    function clear(SolanaMandateV6.Config storage pending) public {
        delete pending.program;
        delete pending.spoke;
        delete pending.usdcMint;
        delete pending.managerKey;
        delete pending.chainId;
        delete pending.transport;
        delete pending.swapPolicyHash;
        delete pending.assets;
        delete pending.venues;
    }

    function route(SolanaMandateV6.Config memory native, bytes32 fundId) internal pure returns (CctpRoute memory) {
        return CctpRoute(
            fundId,
            native.chainId,
            native.transport.mintRecipient,
            native.transport.destinationCaller,
            native.transport.remoteTokenMessenger,
            native.usdcMint,
            native.transport.remoteVaultAuthority
        );
    }

    function spokeIndex(Mandate memory mandate) internal pure returns (uint256) {
        for (uint256 index; index < mandate.spokes.length; ++index) {
            if (mandate.spokes[index].wormholeChainId == 1) return index;
        }
        revert InvalidSolanaBinding();
    }

    function deploy(SolanaMandateV6.Config memory native, bytes32 fundId, address core, address guardian)
        public
        returns (address adapter, address connector)
    {
        CctpRoute memory configured = route(native, fundId);
        adapter = Create3.deploy(
            keccak256(abi.encode(fundId, ADAPTER_ROLE, block.chainid)),
            abi.encodePacked(
                type(CctpBridgeAdapter).creationCode,
                abi.encode(guardian, core, MESSENGER, native.transport.hubUsdc, configured, uint256(50_000))
            )
        );
        connector = Create3.deploy(
            keccak256(abi.encode(fundId, CONNECTOR_ROLE, block.chainid)),
            abi.encodePacked(
                type(CctpReceiveConnector).creationCode,
                abi.encode(core, native.transport.hubUsdc, TRANSMITTER, MESSENGER, configured)
            )
        );
    }

    function validate(Mandate memory mandate, SolanaMandateV6.Config memory native) public view {
        SolanaMandateV6.Transport memory transport = native.transport;
        if (
            mandate.hubChainId != 42_161 || native.chainId != 1 || transport.hubUsdc != mandate.usdc
                || transport.tokenMessenger != MESSENGER || transport.messageTransmitter != TRANSMITTER
                || transport.destinationDomain != 5 || transport.fastFeeCeiling != 50_000
                || transport.mintRecipient == 0 || transport.destinationCaller == 0
                || transport.remoteVaultAuthority == 0 || transport.remoteTokenMessenger == 0
        ) revert InvalidSolanaBinding();
        (bool valid, bytes memory remote) =
            MESSENGER.staticcall(abi.encodeWithSignature("remoteTokenMessengers(uint32)", uint32(5)));
        if (!valid || remote.length != 32 || abi.decode(remote, (bytes32)) != transport.remoteTokenMessenger) {
            revert InvalidSolanaBinding();
        }
        uint256 count;
        for (uint256 index; index < mandate.spokes.length; ++index) {
            SpokeConfig memory spoke = mandate.spokes[index];
            if (spoke.maxReportAge != mandate.spokes[0].maxReportAge) revert InvalidSolanaBinding();
            if (spoke.wormholeChainId != 1) continue;
            ++count;
            if (
                spoke.chainId != native.chainId || spoke.spokeVault != native.spoke
                    || spoke.spokeToken != SolanaMandateV6.accountingId(native.usdcMint)
            ) revert InvalidSolanaBinding();
        }
        if (count != 1) revert InvalidSolanaBinding();
        uint256 tokens;
        for (uint256 index; index < mandate.tokens.length; ++index) {
            bool found;
            for (uint256 asset; asset < native.assets.length; ++asset) {
                if (mandate.tokens[index].token == native.assets[asset].accountingId) found = true;
            }
            if (mandate.tokens[index].chainId != native.chainId) {
                if (found) revert InvalidSolanaBinding();
            } else {
                ++tokens;
                if (!found) revert InvalidSolanaBinding();
            }
        }
        if (tokens != native.assets.length) revert InvalidSolanaBinding();
    }
}
