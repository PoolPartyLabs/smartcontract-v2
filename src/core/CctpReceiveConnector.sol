pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ICctpCoreVault, CctpRoute} from "../interfaces/ICctpCoreVault.sol";
import {IMessageTransmitterV2} from "../interfaces/external/ICctpV2.sol";
import {CctpMessage} from "../libraries/CctpMessage.sol";

/// @notice Permissionless keeper/manual receive with atomic Core custody and credit (DEC-191).
/// @dev No approvals or custody. Circle authenticates signatures; this wrapper authenticates the Fund route.
contract CctpReceiveConnector is ReentrancyGuardTransient {
    address public immutable core;
    address public immutable usdc;
    address public immutable messageTransmitter;
    address public immutable tokenMessenger;
    bytes32 public immutable fundId;
    uint256 public immutable solanaChainId;
    bytes32 public immutable remoteTokenMessenger;
    bytes32 public immutable remoteToken;
    bytes32 public immutable remoteVaultAuthority;
    mapping(bytes32 transitId => bool) public received;

    error InvalidRoute();
    error AlreadyReceived(bytes32 transitId);
    error MintMismatch(uint256 expected, uint256 actual);
    error ReceiveFailed();

    event CctpCredited(bytes32 indexed transitId, bytes32 indexed nonce, uint256 minted, uint256 feeExecuted);

    constructor(address core_, address usdc_, address transmitter_, address messenger_, CctpRoute memory route) {
        if (
            core_ == address(0) || usdc_ == address(0) || transmitter_ == address(0) || messenger_ == address(0)
                || route.fundId == bytes32(0) || route.solanaChainId == 0 || route.solanaChainId == block.chainid
                || route.remoteTokenMessenger == bytes32(0) || route.remoteToken == bytes32(0)
                || route.remoteVaultAuthority == bytes32(0)
        ) revert InvalidRoute();
        core = core_;
        usdc = usdc_;
        messageTransmitter = transmitter_;
        tokenMessenger = messenger_;
        fundId = route.fundId;
        solanaChainId = route.solanaChainId;
        remoteTokenMessenger = route.remoteTokenMessenger;
        remoteToken = route.remoteToken;
        remoteVaultAuthority = route.remoteVaultAuthority;
    }

    /// @notice API and Manager UI use exactly this same unrestricted entry (DEC-191).
    /// @dev A replay reverts before minting; a failed credit rolls back Circle's nonce and mint.
    function receiveCctpAndCredit(bytes calldata message, bytes calldata attestation) external nonReentrant {
        CctpMessage.Receipt memory receipt = CctpMessage.decode(message);
        if (
            receipt.sender != remoteTokenMessenger || receipt.recipient != _address(tokenMessenger)
                || receipt.destinationCaller != _address(address(this)) || receipt.burnToken != remoteToken
                || receipt.mintRecipient != _address(core) || receipt.messageSender != remoteVaultAuthority
                || receipt.fundId != fundId || receipt.originChainId != solanaChainId
        ) revert InvalidRoute();
        if (received[receipt.transitId]) revert AlreadyReceived(receipt.transitId);
        received[receipt.transitId] = true;
        uint256 beforeBalance = IERC20(usdc).balanceOf(core);
        if (!IMessageTransmitterV2(messageTransmitter).receiveMessage(message, attestation)) revert ReceiveFailed();
        uint256 afterBalance = IERC20(usdc).balanceOf(core);
        uint256 minted = afterBalance >= beforeBalance ? afterBalance - beforeBalance : 0;
        uint256 expected = receipt.amount - receipt.feeExecuted;
        if (minted != expected) revert MintMismatch(expected, minted);
        ICctpCoreVault(core)
            .creditCctp(
                receipt.originChainId,
                receipt.transitId,
                receipt.kind,
                receipt.amount,
                receipt.maxFee,
                receipt.feeExecuted
            );
        emit CctpCredited(receipt.transitId, receipt.nonce, minted, receipt.feeExecuted);
    }

    function _address(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
