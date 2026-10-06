pragma solidity 0.8.28;

import {CoreVault} from "./CoreVault.sol";
import {CoreVaultConfig} from "./CoreVaultTypes.sol";
import {Mandate} from "../mandate/Mandate.sol";
import {TransferKind} from "../interfaces/FundTypes.sol";
import {CctpRoute, ICctpCoreVault} from "../interfaces/ICctpCoreVault.sol";
import {CoreVaultCctpLogic} from "./CoreVaultCctpLogic.sol";
import {CoreVaultTransitLogic} from "./CoreVaultTransitLogic.sol";
import {CctpBridgeAdapter} from "../adapters/CctpBridgeAdapter.sol";
import {CctpReceiveConnector} from "./CctpReceiveConnector.sol";

/// @notice New-Fund-only CCTP Core entry points; existing CoreVault deployments are unchanged (DEC-188).
/// @dev TODO(decision): T2a factory must commit every CctpRoute field and fee bound in the new Mandate hash.
///      This separate deployable version is an integration seam, not an authorized production factory path.
contract CoreVaultCctp is CoreVault, ICctpCoreVault {
    CctpBridgeAdapter public immutable cctpAdapter;
    CctpReceiveConnector public immutable cctpConnector;
    uint256 public immutable solanaSpokeIndex;
    mapping(bytes32 => CoreVaultCctpLogic.Receipt) public cctpReceipts;

    error InvalidCctpConfig();
    error NotCctpConnector();
    error CctpRecoveryRequiresReport();

    constructor(
        Mandate memory mandate,
        CoreVaultConfig memory config,
        CctpRoute memory route,
        uint256 spokeIndex,
        CctpBridgeAdapter adapter,
        CctpReceiveConnector connector
    ) CoreVault(mandate, config) {
        if (
            route.fundId != config.fundId || spokeIndex >= mandate.spokes.length
                || mandate.spokes[spokeIndex].chainId != route.solanaChainId || adapter.vault() != address(this)
                || adapter.usdc() != config.usdc || adapter.fundId() != route.fundId
                || adapter.solanaChainId() != route.solanaChainId || adapter.mintRecipient() != route.mintRecipient
                || adapter.destinationCaller() != route.destinationCaller || connector.core() != address(this)
                || connector.usdc() != config.usdc || connector.fundId() != route.fundId
                || connector.solanaChainId() != route.solanaChainId || connector.tokenMessenger() != adapter.target()
                || connector.remoteTokenMessenger() != route.remoteTokenMessenger
                || connector.remoteToken() != route.remoteToken
                || connector.remoteVaultAuthority() != route.remoteVaultAuthority
        ) revert InvalidCctpConfig();
        bool listed;
        for (uint256 index; index < mandate.bridgeAdapters.length; ++index) {
            if (
                mandate.bridgeAdapters[index].spokeChainId == route.solanaChainId
                    && mandate.bridgeAdapters[index].chainId == mandate.hubChainId
                    && mandate.bridgeAdapters[index].adapter == address(adapter)
            ) listed = true;
        }
        if (!listed) revert InvalidCctpConfig();
        solanaSpokeIndex = spokeIndex;
        cctpAdapter = adapter;
        cctpConnector = connector;
    }

    /// @notice DEC-191: fees fixed at send; no escrow, deadline, refund or native SOL funding.
    function sendToSolana(uint256 amount, bytes calldata feeData) external onlyManager nonReentrant returns (bytes32) {
        if (_s.fundState == FundState.Closed) revert FundNotOpen(_s.fundState);
        if (amount == 0) revert ZeroAmount();
        _topUpOperatingCash();
        return CoreVaultCctpLogic.send(_s, _wiring(), solanaSpokeIndex, cctpAdapter, amount, feeData);
    }

    function creditCctp(
        uint256 origin,
        bytes32 id,
        TransferKind kind,
        uint256 amount,
        uint256 maxFee,
        uint256 feeExecuted
    ) external nonReentrant {
        if (msg.sender != address(cctpConnector)) revert NotCctpConnector();
        if (_s.fundState == FundState.Closed) return;
        _requireUnledgered(usdc, amount - feeExecuted);
        CoreVaultCctpLogic.receiveReturn(_s, _wiring(), cctpReceipts[id], origin, id, kind, amount, maxFee, feeExecuted);
    }

    function onReportAccepted(uint256 spokeIndex) external override nonReentrant {
        if (msg.sender != reportReceiver) revert NotReportReceiver(msg.sender);
        CoreVaultTransitLogic.applyReport(_s, _wiring(), spokeIndex);
        if (_s.fundState != FundState.Closed && spokeIndex == solanaSpokeIndex) {
            CoreVaultCctpLogic.settleReport(_s, _wiring(), cctpReceipts, spokeIndex);
        }
    }

    /// @dev DEC-191: silence cannot retire a CCTP source claim; no timed unlisted recovery.
    function recoverUnlistedArrival(uint256 spokeIndex, bytes32 id) external override nonReentrant returns (uint256) {
        if (spokeIndex == solanaSpokeIndex) revert CctpRecoveryRequiresReport();
        return CoreVaultTransitLogic.recoverUnlistedArrival(_s, _wiring(), spokeIndex, id);
    }
}
