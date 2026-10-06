pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoreMockToken} from "../core/CoreMockTokens.sol";
import {CctpRoute} from "../../../src/interfaces/ICctpCoreVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {CctpMessage} from "../../../src/libraries/CctpMessage.sol";

/// @notice Local-only protocol double; never verifies a real attestation (DEC-191 test harness).
contract MockCctpV2 {
    address public immutable token;
    uint256 public adjustment;
    bool public rejectReceive;
    bool public returnFalse;
    bytes public lastHook;
    uint256 public lastMaxFee;
    bytes32 public lastRecipient;
    bytes32 public lastCaller;
    mapping(bytes32 => bool) public used;

    constructor(address token_) {
        token = token_;
    }

    function configure(uint256 adjustment_, bool reject_, bool false_) external {
        adjustment = adjustment_;
        rejectReceive = reject_;
        returnFalse = false_;
    }

    function depositForBurnWithHook(
        uint256 amount,
        uint32 domain,
        bytes32 recipient,
        address burnToken,
        bytes32 caller,
        uint256 maxFee,
        uint32 finality,
        bytes calldata hook
    ) external {
        require(domain == 5 && finality == 1000 && burnToken == token, "wrong burn route");
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        lastHook = hook;
        lastMaxFee = maxFee;
        lastRecipient = recipient;
        lastCaller = caller;
    }

    function receiveMessage(bytes calldata message, bytes calldata) external returns (bool) {
        require(!rejectReceive, "invalid attestation");
        CctpMessage.Receipt memory receipt = CctpMessage.decode(message);
        require(receipt.destinationCaller == bytes32(uint256(uint160(msg.sender))), "caller");
        require(!used[receipt.nonce], "nonce used");
        used[receipt.nonce] = true;
        CoreMockToken(token)
            .mint(address(uint160(uint256(receipt.mintRecipient))), receipt.amount - receipt.feeExecuted - adjustment);
        return !returnFalse;
    }
}

library CctpTestMessage {
    function encode(
        CctpRoute memory route,
        address core,
        address connector,
        address messenger,
        bytes32 id,
        bytes32 nonce,
        TransferKind kind,
        uint256 amount,
        uint256 maxFee,
        uint256 fee
    ) internal pure returns (bytes memory) {
        bytes memory hook = TransitMessage.encode(route.fundId, route.solanaChainId, id, kind);
        bytes memory header = _header(route.remoteTokenMessenger, connector, messenger, nonce);
        bytes memory body = _body(route, core, amount, maxFee, fee);
        return bytes.concat(header, body, hook);
    }

    function _header(bytes32 remote, address connector, address messenger, bytes32 nonce)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            uint32(1),
            uint32(5),
            uint32(3),
            nonce,
            remote,
            bytes32(uint256(uint160(messenger))),
            bytes32(uint256(uint160(connector))),
            uint32(1000),
            uint32(1000)
        );
    }

    function _body(CctpRoute memory route, address core, uint256 amount, uint256 maxFee, uint256 fee)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            uint32(1),
            route.remoteToken,
            bytes32(uint256(uint160(core))),
            amount,
            route.remoteVaultAuthority,
            maxFee,
            fee,
            uint256(0)
        );
    }
}
