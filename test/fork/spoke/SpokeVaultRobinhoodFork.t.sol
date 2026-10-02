// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreBridge, CoreBridgeVM} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {WormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {VaaLib, Vaa, VaaBody} from "wormhole-sdk/libraries/VaaLib.sol";
import {toUniversalAddress} from "wormhole-sdk/Utils.sol";

import {SpokeVaultForkBase} from "./SpokeVaultForkBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {Transit, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockBridgeAdapter} from "../../mocks/spoke/MockBridgeAdapter.sol";
import {MockSwapAdapter} from "../../mocks/swap/MockSwapAdapter.sol";

/// @notice Spoke role on a pinned Robinhood Chain fork: real USDG, the real Wormhole Core Bridge (report publication,
///         parsed with `WormholeOverride.fetchPublishedMessages`, then signed and verified with an overridden guardian
///         set) and the real Across SpokePool (send home through a bridge call built for it).
contract SpokeVaultRobinhoodForkTest is SpokeVaultForkBase {
    using WormholeOverride for ICoreBridge;

    ICoreBridge internal constant CORE = ICoreBridge(RH_WORMHOLE_CORE);
    bytes32 internal constant ARRIVAL = keccak256("hub transit 1");

    address internal coreVault = makeAddr("coreVaultOnArbitrum");
    MockPositionAdapter internal spokeUni;
    MockBridgeAdapter internal spokeBridge;
    SpokeVault internal vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));
        assertEq(block.chainid, ROBINHOOD);

        spokeUni = new MockPositionAdapter(guardian, false);
        spokeUni.addPool(SPOKE_POOL, RH_WETH, RH_USDG);
        spokeBridge = new MockBridgeAdapter(guardian, RH_SPOKE_POOL);
        ForkAdapters memory a = ForkAdapters({
            hubUni: makeAddr("hubUni"),
            hubAave: makeAddr("hubAave"),
            spokeUni: address(spokeUni),
            hubBridge: makeAddr("hubBridge"),
            spokeBridge: address(spokeBridge),
            spokeVault: makeAddr("spokeVaultInMandate"),
            hubSwap: makeAddr("hubSwap"),
            spokeSwap: address(new MockSwapAdapter())
        });
        vault = new SpokeVault(
            _mandate(a),
            FUND_ID,
            ROBINHOOD,
            coreVault,
            RH_USDG,
            RH_SPOKE_POOL,
            RH_WORMHOLE_CORE,
            address(new TransitEscrow()),
            excessRecipient
        );
        spokeUni.setVault(address(vault));
        spokeBridge.setVault(address(vault));
    }

    function test_DEC093_forkRobinhood_reportPublishedFinalizedThroughWormholeCore() public {
        _arrive(1000e6);

        vm.recordLogs();
        (uint64 sequence, uint64 wormholeSequence) = vault.report();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        VaaBody[] memory published = CORE.fetchPublishedMessages(logs);
        assertEq(published.length, 1);
        VaaBody memory pm = published[0];
        assertEq(pm.envelope.emitterChainId, WH_ROBINHOOD);
        assertEq(pm.envelope.emitterAddress, toUniversalAddress(address(vault)), "the Spoke Vault is the emitter");
        assertEq(pm.envelope.sequence, wormholeSequence);
        assertEq(pm.envelope.consistencyLevel, 1, "finalized (DEC-093)");

        ReportCodec.Report memory r = ReportCodec.decode(pm.payload);
        assertEq(sequence, 1);
        assertEq(r.sequence, 1);
        assertEq(r.fundId, FUND_ID);
        assertEq(r.spokeChainId, ROBINHOOD);
        assertEq(r.timestamp, block.timestamp);
        assertEq(r.unallocated[0].token, RH_USDG);
        // DEC-096: the arrival topped Operating Cash up by 10 USDG (floor 5, top-up 10), outside Share Assets.
        assertEq(r.unallocated[0].amount, 1000e6 - 10e6);
        assertEq(r.cumulativeReceived, 1000e6);
        assertEq(r.arrivedTransits.length, 1);
        assertEq(r.arrivedTransits[0].transitId, ARRIVAL);
        assertEq(r.arrivedTransits[0].amount, 1000e6);

        // The payload a guardian quorum signs verifies against the real Core Bridge (guardian set overridden).
        CORE.setUpOverride();
        bytes memory encoded = VaaLib.encode(CORE.sign(pm));
        (CoreBridgeVM memory parsed, bool valid, string memory reason) = CORE.parseAndVerifyVM(encoded);
        assertTrue(valid, reason);
        assertEq(parsed.emitterAddress, toUniversalAddress(address(vault)));
        assertEq(parsed.payload, pm.payload);

        (uint64 sequence2, uint64 wormholeSequence2) = vault.report();
        assertEq(sequence2, 2);
        assertEq(wormholeSequence2, wormholeSequence + 1);
    }

    function test_DEC087_forkRobinhood_sendHomeThroughAcrossSpokePool() public {
        vm.prank(manager);
        vault.setOperatingCashParameters(0, 0);
        _arrive(1000e6);

        uint32 depositId = IAcrossSpokePool(RH_SPOKE_POOL).numberOfDeposits();
        // DEC-162: the bridge adapter (a mock here) fixes the amount to arrive; the manager passes no bridge parameter.
        spokeBridge.setFee(1e6);
        vm.recordLogs();
        vm.prank(manager);
        bytes32 id = vault.sendToHub(500e6, TransferKind.Principal, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Transit memory t = vault.hubBoundTransit(id);
        assertEq(t.bridgeRef, bytes32(uint256(depositId)));
        assertEq(IERC20(RH_USDG).balanceOf(address(vault)), 500e6);
        assertEq(IERC20(RH_USDG).allowance(address(vault), RH_SPOKE_POOL), 0);

        bool seen;
        bytes32 topic = IAcrossSpokePool.FundsDeposited.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != RH_SPOKE_POOL || logs[i].topics[0] != topic) continue;
            seen = true;
            assertEq(uint256(logs[i].topics[1]), ARBITRUM, "destination");
            assertEq(uint256(logs[i].topics[2]), depositId);
            assertEq(logs[i].topics[3], toUniversalAddress(t.escrow), "the per-send escrow is the depositor");
            _checkDeposit(logs[i].data, t, id);
        }
        assertTrue(seen, "FundsDeposited emitted");

        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.inFlightToHub.length, 1);
        assertEq(r.inFlightToHub[0].amount, 499e6);
        assertEq(r.cumulativeSentHome, 500e6);
    }

    /// @notice Non-indexed fields of `FundsDeposited`, in event order.
    struct DepositData {
        bytes32 inputToken;
        bytes32 outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes32 recipient;
        bytes32 exclusiveRelayer;
        bytes message;
    }

    function _checkDeposit(bytes memory data, Transit memory t, bytes32 id) internal view {
        // The event's data is the tuple encoding; as a struct it needs its offset word first.
        DepositData memory d = abi.decode(bytes.concat(abi.encode(uint256(0x20)), data), (DepositData));
        assertEq(d.inputToken, toUniversalAddress(RH_USDG));
        assertEq(d.outputToken, toUniversalAddress(ARB_USDC));
        assertEq(d.inputAmount, 500e6);
        assertEq(d.outputAmount, 499e6);
        assertEq(d.fillDeadline, t.fillDeadline);
        assertEq(d.recipient, toUniversalAddress(coreVault), "recipient fixed to the Core Vault");
        (bytes32 fund, uint256 origin, bytes32 transitId,) = TransitMessage.decode(d.message);
        assertEq(fund, FUND_ID);
        assertEq(origin, ROBINHOOD);
        assertEq(transitId, id);
    }

    /// @dev Across fill as the fork suites simulate it: the output token is dealt to the recipient and the SpokePool
    ///      calls the handler (docs/INTEGRATIONS.md).
    function _arrive(uint256 amount) internal {
        deal(RH_USDG, address(vault), IERC20(RH_USDG).balanceOf(address(vault)) + amount);
        vm.prank(RH_SPOKE_POOL);
        vault.handleV3AcrossMessage(
            RH_USDG,
            amount,
            makeAddr("relayer"),
            TransitMessage.encode(FUND_ID, ARBITRUM, ARRIVAL, TransferKind.Principal)
        );
    }
}
