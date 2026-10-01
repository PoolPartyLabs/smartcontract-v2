// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {VaaLib, VaaBody, VaaEnvelope} from "wormhole-sdk/libraries/VaaLib.sol";
import {toUniversalAddress} from "wormhole-sdk/Utils.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {EndToEndScenario} from "../../fork/e2e/EndToEnd.t.sol";

/// @notice Current Across relay data as the live SpokePools take it (bytes32 addresses, uint256 deposit id).
struct LiveRelayData {
    bytes32 depositor;
    bytes32 recipient;
    bytes32 exclusiveRelayer;
    bytes32 inputToken;
    bytes32 outputToken;
    uint256 inputAmount;
    uint256 outputAmount;
    uint256 originChainId;
    uint256 depositId;
    uint32 fillDeadline;
    uint32 exclusivityDeadline;
    bytes message;
}

/// @notice Across V3 relayer refund leaf (SpokePoolInterface.RelayerRefundLeaf); an expired deposit is refunded to its
///         depositor through such a leaf of a root bundle the HubPool relays to the SpokePool.
struct RelayerRefundLeaf {
    uint256 amountToReturn;
    uint256 chainId;
    uint256[] refundAmounts;
    uint32 leafId;
    address l2TokenAddress;
    address[] refundAddresses;
}

/// @notice Entry points of the live SpokePool implementations (selectors checked in their bytecode on 2026-09-30:
///         Arbitrum implementation 0xcfcda843..., Robinhood implementation 0x1771c470...).
interface ILiveSpokePool {
    function fillRelay(LiveRelayData calldata relayData, uint256 repaymentChainId, bytes32 repaymentAddress) external;
    function relayRootBundle(bytes32 relayerRefundRoot, bytes32 slowRelayRoot) external;
    function executeRelayerRefundLeaf(uint32 rootBundleId, RelayerRefundLeaf calldata leaf, bytes32[] calldata proof)
        external
        payable;
    function crossDomainAdmin() external view returns (address);
    function chainId() external view returns (uint256);
    function getCurrentTime() external view returns (uint256);
    function fillStatuses(bytes32 relayHash) external view returns (uint256);
}

/// @notice A relayer contract that fills several relays in one transaction (the manager's own relayer in the
///         exclusivity and window-flush scenarios). Deployed on the destination fork; its address is named as the
///         exclusive relayer on the origin fork.
contract BatchRelayer {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function fillAll(address pool, address token, LiveRelayData[] calldata relays, uint256 repaymentChainId) external {
        require(msg.sender == owner, "owner");
        IERC20(token).approve(pool, type(uint256).max);
        for (uint256 i; i < relays.length; ++i) {
            ILiveSpokePool(pool).fillRelay(relays[i], repaymentChainId, bytes32(uint256(uint160(address(this)))));
        }
        IERC20(token).approve(pool, 0);
    }
}

/// @notice Integration review base (slug integration-xchain): the project's end-to-end fork scenario (one fund created
///         by the real FundFactory on an Arbitrum fork and a Robinhood fork) plus the pieces the project's scenario
///         simulates, done for real here:
///         - fills go through the live SpokePool `fillRelay` with the relay data of the live `FundsDeposited` event
///           (the SpokePool transfers the output token and calls the vault's handler itself);
///         - reports are published through the real Robinhood Wormhole Core and delivered through the real Arbitrum
///           Core, which verifies a 13-of-19 guardian signature set (WormholeOverride, same guardian-set size as
///           mainnet);
///         - an expired deposit is refunded through the live SpokePool's `executeRelayerRefundLeaf`, after the
///           cross-domain admin relays a root bundle (the Across refund path; only its timing is off-chain).
abstract contract XChainBase is EndToEndScenario {
    using AdvancedWormholeOverride for ICoreBridge;

    /// @dev Finalized Wormhole VAA latency from Robinhood (docs/DECISIONS.md measured facts: about 925 to 1,190 s).
    uint256 internal constant FINALITY = 1000;

    /// @dev Arbitrum One's per-transaction gas cap (ArbGasInfo.getGasAccountingParams, read on 2026-09-30).
    uint256 internal constant MAX_TX_GAS = 32_000_000;

    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("strangerRelayer");

    uint256 internal freshIdNonce;

    // -----------------------------------------------------------------------------------------------------------------
    // Across: live deposits, fills and refunds
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev Every `FundsDeposited` the SpokePool `pool` emitted in `logs`, as live relay data.
    function _relaysFrom(Vm.Log[] memory logs, address pool, uint256 originChainId)
        internal
        pure
        returns (LiveRelayData[] memory relays)
    {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == pool && logs[i].topics[0] == IAcrossSpokePool.FundsDeposited.selector) ++n;
        }
        relays = new LiveRelayData[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != pool || logs[i].topics[0] != IAcrossSpokePool.FundsDeposited.selector) continue;
            DepositData memory d = abi.decode(bytes.concat(abi.encode(uint256(0x20)), logs[i].data), (DepositData));
            LiveRelayData memory r = relays[n++];
            r.depositor = logs[i].topics[3];
            r.recipient = d.recipient;
            r.exclusiveRelayer = d.exclusiveRelayer;
            r.inputToken = d.inputToken;
            r.outputToken = d.outputToken;
            r.inputAmount = d.inputAmount;
            r.outputAmount = d.outputAmount;
            r.originChainId = originChainId;
            r.depositId = uint256(logs[i].topics[2]);
            r.fillDeadline = d.fillDeadline;
            r.exclusivityDeadline = d.exclusivityDeadline;
            r.message = d.message;
        }
    }

    function _one(LiveRelayData[] memory relays) internal pure returns (LiveRelayData memory) {
        require(relays.length == 1, "expected one deposit");
        return relays[0];
    }

    /// @dev Manager: `sendToSpoke` through the live Arbitrum SpokePool; returns the transit id and its relay data.
    function _sendToSpoke(uint256 amount, BridgeQuote memory quote)
        internal
        returns (bytes32 id, LiveRelayData memory relay)
    {
        _onArbitrum();
        vm.recordLogs();
        vm.prank(manager);
        id = core.sendToSpoke(0, amount, 0, quote);
        relay = _one(_relaysFrom(vm.getRecordedLogs(), ARB_ACROSS_SPOKE_POOL, ARBITRUM));
    }

    /// @dev Manager: `sendToHub` through the live Robinhood SpokePool; returns the transit id and its relay data.
    function _sendToHub(uint256 amount, TransferKind kind, BridgeQuote memory quote)
        internal
        returns (bytes32 id, LiveRelayData memory relay)
    {
        _onRobinhood();
        vm.recordLogs();
        vm.prank(manager);
        id = spokeVault.sendToHub(amount, kind, 0, quote);
        relay = _one(_relaysFrom(vm.getRecordedLogs(), RH_ACROSS_SPOKE_POOL, ROBINHOOD));
    }

    function _quote(uint256 outputAmount) internal view returns (BridgeQuote memory) {
        return BridgeQuote(outputAmount, uint32(block.timestamp), 0, address(0));
    }

    function _exclusiveQuote(uint256 outputAmount, address relayer_) internal view returns (BridgeQuote memory) {
        return BridgeQuote(outputAmount, uint32(block.timestamp), 21_600, relayer_);
    }

    /// @dev A relayer fills `r` on the selected fork's live SpokePool `pool`, paying `r.outputAmount` of `token`.
    function _fill(address pool, address token, LiveRelayData memory r, address relayer_) internal {
        deal(token, relayer_, IERC20(token).balanceOf(relayer_) + r.outputAmount);
        vm.startPrank(relayer_);
        IERC20(token).approve(pool, r.outputAmount);
        ILiveSpokePool(pool).fillRelay(r, r.originChainId, bytes32(uint256(uint160(relayer_))));
        IERC20(token).approve(pool, 0);
        vm.stopPrank();
    }

    function _fillOnRobinhood(LiveRelayData memory r, address relayer_) internal {
        _onRobinhood();
        _fill(RH_ACROSS_SPOKE_POOL, RH_USDG, r, relayer_);
    }

    function _fillOnArbitrum(LiveRelayData memory r, address relayer_) internal {
        _onArbitrum();
        _fill(ARB_ACROSS_SPOKE_POOL, ARB_USDC, r, relayer_);
    }

    /// @dev Anyone: a relay that no Robinhood deposit backs, filled on the live Arbitrum SpokePool to the Core Vault
    ///      (the relayer pays `amount` and is never repaid). Its message names `transitId` as a Robinhood send home.
    function _fabricatedFillOnArbitrum(bytes32 id, uint256 amount, TransferKind kind, address relayer_)
        internal
        returns (LiveRelayData memory r)
    {
        _onArbitrum();
        r.depositor = bytes32(uint256(uint160(relayer_)));
        r.recipient = bytes32(uint256(uint160(address(core))));
        r.inputToken = bytes32(uint256(uint160(RH_USDG)));
        r.outputToken = bytes32(uint256(uint160(ARB_USDC)));
        r.inputAmount = amount;
        r.outputAmount = amount;
        r.originChainId = ROBINHOOD;
        r.depositId = uint256(keccak256(abi.encode("integration-xchain fabricated relay", ++freshIdNonce)));
        r.fillDeadline = uint32(block.timestamp + 1 hours);
        r.message = TransitMessage.encode(fundId, ROBINHOOD, id, kind);
        _fill(ARB_ACROSS_SPOKE_POOL, ARB_USDC, r, relayer_);
    }

    /// @dev The id the Robinhood Spoke Vault gives its `nonce`-th send home (`SpokeCrossChainLib.sendToHub`).
    function _sendHomeId(uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(fundId, ROBINHOOD, nonce));
    }

    /// @dev The Across refund of an expired deposit, on the selected fork's live SpokePool: the cross-domain admin (the
    ///      HubPool, L1-to-L2 aliased) relays a root bundle whose relayer-refund leaf pays `amount` of `token` to
    ///      `depositor`, and anyone executes the leaf. Only the timing of this step is off-chain (docs/DECISIONS.md:
    ///      45 to 80 min after `fillDeadline` from Arbitrum, 55 to 90 min from Robinhood).
    function _acrossRefund(address pool, address token, address depositor, uint256 amount) internal {
        RelayerRefundLeaf memory leaf;
        leaf.chainId = block.chainid;
        leaf.refundAmounts = new uint256[](1);
        leaf.refundAmounts[0] = amount;
        leaf.l2TokenAddress = token;
        leaf.refundAddresses = new address[](1);
        leaf.refundAddresses[0] = depositor;
        bytes32 root = keccak256(abi.encode(leaf));
        vm.recordLogs();
        _relayRootBundleAsAdmin(pool, root);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint32 rootBundleId;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            // RelayedRootBundle(uint32 indexed rootBundleId, bytes32 indexed relayerRefundRoot, bytes32 indexed slowRelayRoot)
            if (logs[i].emitter == pool && logs[i].topics.length == 4 && logs[i].topics[2] == root) {
                rootBundleId = uint32(uint256(logs[i].topics[1]));
                found = true;
            }
        }
        require(found, "no RelayedRootBundle");
        vm.prank(keeper);
        ILiveSpokePool(pool).executeRelayerRefundLeaf(rootBundleId, leaf, new bytes32[](0));
    }

    /// @dev The HubPool's admin call `relayRootBundle` as it reaches each live pool:
    ///      - Arbitrum One (`Arbitrum_SpokePool`): from the L1-to-L2 alias of the cross-domain admin (the HubPool);
    ///      - Robinhood Chain (`Universal_SpokePool`, reverts `AdminCallNotValidated` otherwise): inside
    ///        `executeMessage`, which sets a private validation flag after a light-client proof of the HubPool's storage
    ///        and clears it after the call. The proof is off-chain data, so the flag is set here the way `executeMessage`
    ///        sets it (located by recording the pool's storage reads), then cleared.
    function _relayRootBundleAsAdmin(address pool, bytes32 root) internal {
        address admin = ILiveSpokePool(pool).crossDomainAdmin();
        address aliased = address(uint160(admin) + uint160(0x1111000000000000000000000000000000001111));
        vm.prank(aliased);
        try ILiveSpokePool(pool).relayRootBundle(root, bytes32(0)) {
            return;
        } catch {}
        vm.record();
        try ILiveSpokePool(pool).relayRootBundle(root, bytes32(0)) {} catch {}
        (bytes32[] memory reads,) = vm.accesses(pool);
        require(reads.length != 0, "no reads");
        bytes32 slot = reads[reads.length - 1];
        bytes32 original = vm.load(pool, slot);
        for (uint256 k; k < 32; ++k) {
            vm.store(pool, slot, original | bytes32(uint256(1) << (8 * k)));
            try ILiveSpokePool(pool).relayRootBundle(root, bytes32(0)) {
                vm.store(pool, slot, original);
                return;
            } catch {}
        }
        revert("admin call not reproduced");
    }

    function _freshId() internal returns (bytes32) {
        return keccak256(abi.encode("integration-xchain fresh id", ++freshIdNonce));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Reports: published on the real Robinhood Core, delivered through the real Arbitrum Core
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev Anyone: `report()` on Robinhood; returns the payload the real Core logged and its Wormhole sequence.
    function _publish() internal returns (bytes memory payload, uint64 whSeq) {
        _onRobinhood();
        vm.recordLogs();
        (, whSeq) = spokeVault.report();
        VaaBody[] memory published = ICoreBridge(RH_WORMHOLE_CORE).fetchPublishedMessages(vm.getRecordedLogs());
        require(published.length == 1, "one message");
        payload = published[0].payload;
    }

    /// @dev Measured variant of `_publish` with the spoke, its adapters and the Core cold.
    function _publishMeasured() internal returns (bytes memory payload, uint64 whSeq, uint256 gasUsed) {
        _onRobinhood();
        vm.cool(address(spokeVault));
        vm.cool(spokeUniswap);
        vm.cool(RH_WORMHOLE_CORE);
        vm.cool(RH_V4_STATE_VIEW);
        vm.cool(RH_V4_POOL_MANAGER);
        vm.recordLogs();
        uint256 g = gasleft();
        (, whSeq) = spokeVault.report();
        gasUsed = g - gasleft();
        VaaBody[] memory published = ICoreBridge(RH_WORMHOLE_CORE).fetchPublishedMessages(vm.getRecordedLogs());
        payload = published[0].payload;
    }

    function _ensureOverride() internal {
        ICoreBridge arbitrumCore = ICoreBridge(ARB_WORMHOLE_CORE);
        if (arbitrumCore.getGuardianPrivateKeys().length == 0) arbitrumCore.setUpOverride();
    }

    /// @dev The VAA a 13-of-19 guardian quorum signs for a message of the fund's Spoke Vault (on the Arbitrum fork).
    function _vaa(bytes memory payload, uint64 whSeq) internal returns (bytes memory) {
        _onArbitrum();
        _ensureOverride();
        VaaEnvelope memory e = VaaEnvelope(
            uint32(block.timestamp), 0, WORMHOLE_ROBINHOOD, toUniversalAddress(address(spokeVault)), whSeq, 1
        );
        return VaaLib.encode(ICoreBridge(ARB_WORMHOLE_CORE).sign(VaaBody(e, payload)));
    }

    /// @dev Anyone: delivers on Arbitrum; returns the execution gas of `deliver` (storage cooled, like a new tx).
    function _deliver(bytes memory payload, uint64 whSeq) internal returns (uint256 gasUsed) {
        bytes memory vaa = _vaa(payload, whSeq);
        _coolHub();
        vm.prank(keeper);
        uint256 g = gasleft();
        receiver.deliver(vaa);
        gasUsed = g - gasleft();
    }

    /// @dev `deliver` inside a transaction capped at `MAX_TX_GAS` (intrinsic cost taken out first).
    function _deliverFitsOneTx(bytes memory payload, uint64 whSeq) internal returns (bool ok, uint256 intrinsic) {
        bytes memory vaa = _vaa(payload, whSeq);
        intrinsic = _intrinsic(abi.encodeCall(IValueReportReceiver.deliver, (vaa)));
        _coolHub();
        vm.prank(keeper);
        (ok,) = address(receiver).call{gas: MAX_TX_GAS - intrinsic}(abi.encodeCall(IValueReportReceiver.deliver, (vaa)));
    }

    function _coolHub() internal {
        vm.cool(address(receiver));
        vm.cool(address(core));
        vm.cool(ARB_WORMHOLE_CORE);
        // The Core is a proxy: cool its implementation too (EIP-1967 slot).
        address impl = address(
            uint160(
                uint256(vm.load(ARB_WORMHOLE_CORE, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))
            )
        );
        if (impl != address(0)) vm.cool(impl);
        vm.cool(hubDeployment.coreVaultLogic);
    }

    /// @dev Base cost plus EIP-2028 calldata cost of a transaction carrying `data`.
    function _intrinsic(bytes memory data) internal pure returns (uint256 gas) {
        gas = 21_000;
        for (uint256 i; i < data.length; ++i) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    /// @dev Keeper: publish now, then deliver `FINALITY` seconds later (the finalized VAA latency).
    function _report() internal returns (uint256 deliverGas) {
        (bytes memory payload, uint64 whSeq) = _publish();
        _onArbitrum();
        _advance(FINALITY);
        deliverGas = _deliver(payload, whSeq);
    }

    function _latest() internal view returns (ReportCodec.Report memory r) {
        (r,,) = receiver.latestReport(0);
    }

    function _capUsed() internal view returns (uint256) {
        (uint256 spokeValue, uint256 inFlightSent, uint256 inFlightToHub,) = core.spokeCapUsage(0);
        return spokeValue + inFlightSent + inFlightToHub;
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Fund creation with a chosen plan per chain (the project's phase 1, split so the spoke can come later or differ)
    // -----------------------------------------------------------------------------------------------------------------

    address internal predictedSpokeVault;

    /// @dev Phase 1 on Arbitrum only: protocol, Mandate from `plan`, `createFund`. The Robinhood Spoke Vault is only
    ///      predicted.
    function _createHub(FundPlan memory plan) internal {
        _onArbitrum();
        hubDeployment = _deployProtocol(recipient, guardian, registryOwner);
        FundFactory factory = hubDeployment.factory;
        creationNumber = factory.nextCreationNumber();
        IFundFactory.FundAddresses memory predicted = factory.predictAddresses(creationNumber, manager, _chainIds());
        fundId = predicted.fundId;
        Mandate memory m = _buildMandate(factory, fundId, plan);
        mandateHash = MandateLib.hash(m);
        IFundFactory.HubParams memory p =
            _hubParams(creationNumber, plan, _coreVaultCreationCode(hubDeployment.coreVaultLogic));
        vm.prank(manager);
        IFundFactory.FundAddresses memory a = factory.createFund(m, p);
        core = ICoreVault(a.coreVault);
        shareToken = a.shareToken;
        managerFeeVault = a.managerFeeVault;
        receiver = IValueReportReceiver(a.valueReportReceiver);
        hubSpoke = ISpokeVault(a.chains[0].spokeVault);
        hubUniswap = a.chains[0].uniswapV4Adapter;
        hubAave = a.chains[0].aaveV3Adapter;
        hubAcross = a.chains[0].acrossBridgeAdapter;
        predictedSpokeVault = predicted.chains[1].spokeVault;
        spokeVault = ISpokeVault(predictedSpokeVault);
    }

    /// @dev The protocol on Robinhood, deployed once (the factory lands at the hub factory's address, DEC-054).
    function _robinhoodFactory() internal returns (FundFactory factory) {
        _onRobinhood();
        factory = hubDeployment.factory;
        if (address(factory).code.length == 0) {
            Deployment memory rd = _deployProtocol(recipient, guardian, registryOwner);
            require(address(rd.factory) == address(factory), "one factory address on both chains");
        }
    }

    /// @dev Phase 1 on Robinhood: protocol and `createSpoke` from the Mandate `plan` builds (with its own hash as the
    ///      `mandateHash` argument, which is all `createSpoke` compares). Returns the spoke's Mandate hash.
    function _createSpokeFrom(FundPlan memory plan) internal returns (bytes32 spokeMandateHash) {
        FundFactory factory = _robinhoodFactory();
        Mandate memory m = _buildMandate(factory, fundId, plan);
        spokeMandateHash = MandateLib.hash(m);
        vm.prank(manager);
        IFundFactory.ChainAddresses memory s =
            factory.createSpoke(creationNumber, m, _spokeParams(spokeMandateHash, plan));
        require(s.spokeVault == predictedSpokeVault, "at the address the hub names");
        spokeVault = ISpokeVault(s.spokeVault);
        spokeUniswap = s.uniswapV4Adapter;
        spokeAcross = s.acrossBridgeAdapter;
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Actors
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev A deposit on Arbitrum with fresh prices.
    function _depositAs(address who, uint256 amount) internal returns (uint256 shares) {
        _onArbitrum();
        _refreshEthUsdFeed();
        deal(ARB_USDC, who, IERC20(ARB_USDC).balanceOf(who) + amount);
        vm.startPrank(who);
        IERC20(ARB_USDC).approve(address(core), amount);
        (shares,) = core.deposit(amount, 0);
        vm.stopPrank();
    }

    function _log(string memory label, uint256 value) internal pure {
        console2.log(label, value);
    }
}
