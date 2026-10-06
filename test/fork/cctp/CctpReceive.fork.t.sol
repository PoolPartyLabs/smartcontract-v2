pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CctpBridgeAdapter} from "../../../src/adapters/CctpBridgeAdapter.sol";
import {CctpReceiveConnector} from "../../../src/core/CctpReceiveConnector.sol";
import {CctpRoute, ICctpCoreVault} from "../../../src/interfaces/ICctpCoreVault.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {CctpTestMessage} from "../../mocks/cctp/CctpHarness.sol";

interface ICctpLiveTransmitter {
    function attesterManager() external view returns (address);
    function enableAttester(address attester) external;
    function setSignatureThreshold(uint256 threshold) external;
    function usedNonces(bytes32 nonce) external view returns (uint256);
    function version() external view returns (uint32);
    function localDomain() external view returns (uint32);
}

interface ICctpLiveMessenger {
    function remoteTokenMessengers(uint32 domain) external view returns (bytes32);
    function messageBodyVersion() external view returns (uint32);
}

/// @notice Local fork credit sink; tests production Circle verification/mint without Core/factory coupling.
contract ForkCctpCreditSink is ICctpCoreVault {
    address public connector;
    uint256 public principal;
    bool public rejectCredit;

    function configure(address connector_, bool reject_) external {
        connector = connector_;
        rejectCredit = reject_;
    }

    function creditCctp(uint256, bytes32, TransferKind, uint256 amount, uint256, uint256 fee) external {
        require(msg.sender == connector && !rejectCredit, "credit refused");
        principal += amount - fee;
    }

    function execute(address token, IBridgeAdapter.BridgeCall memory call, uint256 amount) external {
        IERC20(token).approve(call.target, amount);
        (bool success, bytes memory result) = call.target.call(call.data);
        if (!success) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        IERC20(token).approve(call.target, 0);
    }
}

/// @notice Arbitrum fork only: impersonate attesterManager locally and sign synthetic Solana burns.
/// @dev Never broadcasts or changes mainnet state; uses deployed Circle code and real native USDC (DEC-191).
contract CctpReceiveForkTest is Test {
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address internal constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    uint256 internal constant ATTESTER_KEY = 0xC1AC1E;
    uint256 internal constant AMOUNT = 1000e6;
    uint256 internal constant MAX_FEE = 140_000;
    uint256 internal constant FEE = 100_000;
    bytes32 internal constant ID = keccak256("fork-business-transit");
    bytes32 internal constant NONCE = keccak256("fork-circle-nonce");
    CctpRoute internal route;
    ForkCctpCreditSink internal core;
    CctpReceiveConnector internal connector;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("CCTP_ARBITRUM_FORK_BLOCK"));
        assertEq(ICctpLiveTransmitter(TRANSMITTER).localDomain(), 3);
        assertEq(ICctpLiveTransmitter(TRANSMITTER).version(), 1);
        assertEq(ICctpLiveMessenger(MESSENGER).messageBodyVersion(), 1);
        route = CctpRoute(
            keccak256("fork-fund"),
            777,
            keccak256("fund-ata"),
            keccak256("receive-pda"),
            ICctpLiveMessenger(MESSENGER).remoteTokenMessengers(5),
            bytes32(uint256(0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61)),
            keccak256("fund-solana-custody")
        );
        core = new ForkCctpCreditSink();
        connector = new CctpReceiveConnector(address(core), USDC, TRANSMITTER, MESSENGER, route);
        core.configure(address(connector), false);
        ICctpLiveTransmitter transmitter = ICctpLiveTransmitter(TRANSMITTER);
        vm.startPrank(transmitter.attesterManager());
        transmitter.enableAttester(vm.addr(ATTESTER_KEY));
        transmitter.setSignatureThreshold(1);
        vm.stopPrank();
    }

    function _message() internal view returns (bytes memory) {
        return CctpTestMessage.encode(
            route, address(core), address(connector), MESSENGER, ID, NONCE, TransferKind.Principal, AMOUNT, MAX_FEE, FEE
        );
    }

    function _attestation(bytes memory message) internal pure returns (bytes memory) {
        (uint8 signatureV, bytes32 signatureR, bytes32 signatureS) = vm.sign(ATTESTER_KEY, keccak256(message));
        return abi.encodePacked(signatureR, signatureS, signatureV);
    }

    function test_DEC191_liveMintPartialFeeAndReplay() public {
        bytes memory message = _message();
        bytes memory attestation = _attestation(message);
        uint256 beforeBalance = IERC20(USDC).balanceOf(address(core));
        connector.receiveCctpAndCredit(message, attestation);
        assertEq(IERC20(USDC).balanceOf(address(core)) - beforeBalance, AMOUNT - FEE);
        assertEq(core.principal(), AMOUNT - FEE);
        assertEq(ICctpLiveTransmitter(TRANSMITTER).usedNonces(NONCE), 1);
        vm.expectRevert(abi.encodeWithSelector(CctpReceiveConnector.AlreadyReceived.selector, ID));
        connector.receiveCctpAndCredit(message, attestation);
        assertEq(core.principal(), AMOUNT - FEE);
    }

    function test_DEC191_liveMintAndNonceRollBackOnFailedCreditThenRetry() public {
        bytes memory message = _message();
        bytes memory attestation = _attestation(message);
        core.configure(address(connector), true);
        uint256 beforeBalance = IERC20(USDC).balanceOf(address(core));
        vm.expectRevert(bytes("credit refused"));
        connector.receiveCctpAndCredit(message, attestation);
        assertEq(IERC20(USDC).balanceOf(address(core)), beforeBalance);
        assertEq(ICctpLiveTransmitter(TRANSMITTER).usedNonces(NONCE), 0);
        assertFalse(connector.received(ID));
        core.configure(address(connector), false);
        connector.receiveCctpAndCredit(message, attestation);
        assertEq(core.principal(), AMOUNT - FEE);
    }

    function test_DEC191_liveDelayedReceiptHasNoBusinessDeadline() public {
        bytes memory message = _message();
        bytes memory attestation = _attestation(message);
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 1_000_000);
        connector.receiveCctpAndCredit(message, attestation);
        assertEq(core.principal(), AMOUNT - FEE);
    }

    function test_DEC191_liveCircleRejectsInvalidSignature() public {
        bytes memory message = _message();
        bytes memory attestation = _attestation(message);
        attestation[0] = bytes1(uint8(attestation[0]) ^ 1);
        vm.expectRevert();
        connector.receiveCctpAndCredit(message, attestation);
        assertEq(core.principal(), 0);
        assertFalse(connector.received(ID));
    }

    function test_DEC191_liveBurnUsesFastHookAndExactNativeUsdcDebit() public {
        CctpBridgeAdapter adapter = new CctpBridgeAdapter(address(this), address(this), MESSENGER, USDC, route, 20_000);
        IBridgeAdapter.SendRequest memory request = IBridgeAdapter.SendRequest(
            USDC,
            address(0),
            AMOUNT,
            route.solanaChainId,
            route.mintRecipient,
            TransitMessage.encode(route.fundId, block.chainid, ID, TransferKind.Principal)
        );
        IBridgeAdapter.BridgeCall memory call = adapter.buildSend(request, address(this), abi.encode(uint256(14_000)));
        deal(USDC, address(core), AMOUNT);
        core.execute(USDC, call, AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(core)), 0);
        assertEq(IERC20(USDC).allowance(address(core), MESSENGER), 0);
        assertEq(call.amountToArrive, AMOUNT - MAX_FEE);
    }
}
