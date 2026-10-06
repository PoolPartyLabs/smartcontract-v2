pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AdapterGuard} from "./AdapterGuard.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {CctpRoute} from "../interfaces/ICctpCoreVault.sol";
import {ITokenMessengerV2} from "../interfaces/external/ICctpV2.sol";
import {TransferKind} from "../interfaces/FundTypes.sol";
import {TransitMessage} from "../libraries/TransitMessage.sol";

/// @title CctpBridgeAdapter
/// @notice Builds a custody-preserving native USDC burn to the Fund's Solana ATA.
/// @dev DEC-188: new Funds only. DEC-191: Fast, in-flight at amount minus maxFee, no refund or expiry.
///      DEC-087, DEC-162: Core approves/calls the immutable target; the adapter holds no funds.
contract CctpBridgeAdapter is AdapterGuard, IBridgeAdapter {
    bytes32 public constant PROTOCOL_ID = keccak256("CCTP_V2");
    uint32 public constant SOLANA_DOMAIN = 5;
    uint32 public constant FAST_FINALITY = 1000;
    uint256 public constant FEE_SCALE = 100_000_000;

    address public immutable vault;
    address public immutable target;
    address public immutable usdc;
    bytes32 public immutable fundId;
    uint256 public immutable solanaChainId;
    bytes32 public immutable mintRecipient;
    bytes32 public immutable destinationCaller;
    uint256 public immutable maxFeeBps;

    error InvalidRoute();
    error InvalidFee();
    error InvalidRequest();
    error NoExpiry();

    /// @param maxFeeBps_ Immutable bound in 1/10,000 bps: Circle's 1.4 bps is 14,000.
    /// @dev TODO(decision): founder must choose the deployment's numeric fee bound; no default is invented.
    constructor(
        address guardian_,
        address vault_,
        address messenger_,
        address usdc_,
        CctpRoute memory route,
        uint256 maxFeeBps_
    ) AdapterGuard(guardian_) {
        if (
            vault_ == address(0) || messenger_ == address(0) || usdc_ == address(0) || route.fundId == bytes32(0)
                || route.solanaChainId == 0 || route.solanaChainId == block.chainid || route.mintRecipient == bytes32(0)
                || route.destinationCaller == bytes32(0)
        ) revert InvalidRoute();
        if (maxFeeBps_ == 0 || maxFeeBps_ >= FEE_SCALE) revert InvalidFee();
        vault = vault_;
        target = messenger_;
        usdc = usdc_;
        fundId = route.fundId;
        solanaChainId = route.solanaChainId;
        mintRecipient = route.mintRecipient;
        destinationCaller = route.destinationCaller;
        maxFeeBps = maxFeeBps_;
    }

    function protocolId() external pure returns (bytes32) {
        return PROTOCOL_ID;
    }

    /// @notice DEC-191: zero means no business deadline, not immediate expiry.
    function fillDeadlineSeconds() external pure returns (uint32) {
        return 0;
    }

    /// @notice bridgeData is abi.encode(feeBps), with bps scaled by 10,000; fixed at send (DEC-191).
    /// @dev The authorized sender supplies Circle's API fee, bounded by the creation-time ceiling.
    function quoteSend(address inputToken, uint256 destinationChainId, uint256 inputAmount, bytes calldata bridgeData)
        public
        view
        returns (uint256 amountToArrive, uint256 rateWad)
    {
        if (
            inputToken != usdc || destinationChainId != solanaChainId || inputAmount == 0
                || inputAmount > type(uint64).max
        ) revert InvalidRequest();
        if (bridgeData.length != 32) revert InvalidFee();
        uint256 feeBps = abi.decode(bridgeData, (uint256));
        if (feeBps > maxFeeBps) revert InvalidFee();
        uint256 maxFee = Math.mulDiv(inputAmount, feeBps, FEE_SCALE, Math.Rounding.Ceil);
        if (maxFee >= inputAmount) revert InvalidFee();
        return (inputAmount - maxFee, Math.mulDiv(feeBps, 1e18, FEE_SCALE));
    }

    /// @dev outputToken is zero: no truncated Solana mint is accepted in the EVM-address field (DEC-188).
    function buildSend(SendRequest calldata req, address depositor, bytes calldata bridgeData)
        external
        view
        returns (BridgeCall memory call)
    {
        if (msg.sender != vault) revert NotVault(msg.sender);
        if (
            depositor != vault || req.recipient != mintRecipient || req.outputToken != address(0)
                || req.message.length != 160
        ) revert InvalidRequest();
        (bytes32 messageFund, uint256 origin, bytes32 id, TransferKind kind) = TransitMessage.decode(req.message);
        if (messageFund != fundId || origin != block.chainid || id == bytes32(0) || kind != TransferKind.Principal) {
            revert InvalidRequest();
        }
        (uint256 net,) = quoteSend(req.inputToken, req.destinationChainId, req.inputAmount, bridgeData);
        call.target = target;
        call.transitRef = id;
        call.amountToArrive = net;
        call.data = _burnData(req.inputAmount, req.inputAmount - net, req.message);
    }

    function _burnData(uint256 amount, uint256 maxFee, bytes calldata hook) private view returns (bytes memory) {
        return abi.encodeCall(
            ITokenMessengerV2.depositForBurnWithHook,
            (amount, SOLANA_DOMAIN, mintRecipient, usdc, destinationCaller, maxFee, FAST_FINALITY, hook)
        );
    }

    /// @dev DEC-191: a delayed burn never steps a fee rule or becomes refundable.
    function noteExpiry(bytes32) external view {
        if (msg.sender != vault) revert NotVault(msg.sender);
        revert NoExpiry();
    }

    function feeState(uint256) external pure returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }
}
