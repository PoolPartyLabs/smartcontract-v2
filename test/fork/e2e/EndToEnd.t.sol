// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {VaaLib, VaaBody, VaaEnvelope} from "wormhole-sdk/libraries/VaaLib.sol";
import {toUniversalAddress} from "wormhole-sdk/Utils.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {IManagerRegistry} from "../../../src/interfaces/IManagerRegistry.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {IChainlinkAggregatorV3} from "../../../src/interfaces/external/IChainlinkAggregatorV3.sol";
import {Transit, TransitState, TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {EndToEndBase} from "./EndToEndBase.sol";

/// @notice End-to-end fork scenario (docs/ARCHITECTURE.md §7): one fund driven across the pinned Arbitrum One and
///         Robinhood Chain forks against the live protocols (Across SpokePools, Uniswap V4 pools, the Aave V3 Pool, the
///         Wormhole Cores, the Chainlink ETH / USD feed) and the Fund Factory deployed through the deterministic
///         deployer on both chains. Each phase asserts its rules and cites the decision that governs them.
contract EndToEndForkTest is EndToEndBase {
    using AdvancedWormholeOverride for ICoreBridge;

    uint256 internal constant ANA_BELOW_MINIMUM = MIN_FIRST_DEPOSIT - 1;
    uint256 internal constant HUB_ALLOCATION = 5000e6;
    uint256 internal constant AAVE_SUPPLY = 2000e6;
    uint256 internal constant HUB_V4_USDC = 3000e6;
    uint256 internal constant SPOKE_V4_USDG = 3000e6;
    uint256 internal constant AAVE_ACCRUAL_TIME = 1 hours;
    uint256 internal constant BRUNO_DEPOSIT = 11_000e6;
    uint256 internal constant ANA_PAYOUT = 3000e6;
    uint256 internal constant BRUNO_ABOVE_FREE_IDLE = 1000e6;
    uint256 internal constant DONATION = 1234e6;

    uint256 internal spokeSwapMinWeth;
    VaaEnvelope internal publishedEnvelope;
    bytes internal publishedPayload;

    /// @notice DEC-054 end to end: create, deposit, allocate, bridge, fill, report, deliver, deposit again, collect,
    ///         pay out (Standard, then Instant with an unwind) and the value-base invariants at the end.
    function test_DEC054_forkEndToEndOneFundAcrossArbitrumAndRobinhood() public {
        _createForks();
        _phase1CreateFund();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Phase 1: factories on both forks, predicted addresses, the Mandate, createFund and createSpoke
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-053, DEC-054: the Mandate names every hub and spoke address before any exists; the factory lands at one
    ///      address on both chains and puts each contract at its prediction.
    function _phase1CreateFund() internal {
        _onArbitrum();
        hubDeployment = _deployProtocol(recipient, guardian, registryOwner);
        FundFactory factory = hubDeployment.factory;
        creationNumber = factory.nextCreationNumber();
        IFundFactory.FundAddresses memory predicted = factory.predictAddresses(creationNumber, manager, _chainIds());
        fundId = predicted.fundId;
        Mandate memory m = _buildMandate(factory, fundId, _plan());
        mandateHash = MandateLib.hash(m);
        _assertMandate(m, predicted);

        IFundFactory.HubParams memory p =
            _hubParams(creationNumber, _plan(), _coreVaultCreationCode(hubDeployment.coreVaultLogic));
        vm.prank(manager);
        IFundFactory.FundAddresses memory a = factory.createFund(m, p);
        assertEq(a.coreVault, predicted.coreVault, "DEC-054: Core Vault at its prediction");
        assertEq(a.chains[0].spokeVault, predicted.chains[0].spokeVault, "DEC-054: hub Spoke Vault at its prediction");
        core = ICoreVault(a.coreVault);
        shareToken = a.shareToken;
        managerFeeVault = a.managerFeeVault;
        receiver = IValueReportReceiver(a.valueReportReceiver);
        hubSpoke = ISpokeVault(a.chains[0].spokeVault);
        hubUniswap = a.chains[0].uniswapV4Adapter;
        hubAave = a.chains[0].aaveV3Adapter;
        hubAcross = a.chains[0].acrossBridgeAdapter;
        assertEq(core.mandateHash(), mandateHash, "DEC-053: the Mandate is written once at creation");
        assertEq(core.flowFeeBps(), FLOW_FEE_BPS, "DEC-106: default flow fee");

        _createSpoke(m, predicted);
    }

    /// @dev DEC-031, DEC-037, DEC-069, DEC-086, DEC-088, DEC-095, DEC-102, DEC-107, DEC-108, QA19, ruling 2026-09-29.
    function _assertMandate(Mandate memory m, IFundFactory.FundAddresses memory predicted) internal pure {
        address hubUni = predicted.chains[0].uniswapV4Adapter;
        address hubAaveAdapter = predicted.chains[0].aaveV3Adapter;
        assertEq(m.hubChainId, ARBITRUM, "DEC-011: Arbitrum One is the Hub Chain");
        assertEq(m.spokes.length, 1);
        assertEq(m.spokes[0].chainId, ROBINHOOD);
        assertEq(m.spokes[0].wormholeChainId, WORMHOLE_ROBINHOOD, "DEC-086: Wormhole chain 72");
        assertEq(
            m.spokes[0].spokeVault,
            toUniversalAddress(predicted.chains[1].spokeVault),
            "DEC-054: the predicted Robinhood Spoke Vault"
        );
        assertEq(m.spokes[0].spokeToken, RH_USDG, "DEC-031: Across delivers USDG on Robinhood");
        assertEq(m.spokes[0].maxReportAge, 1588, "ruling 2026-09-29: 1,587 s plus one block");
        assertEq(m.spokes[0].spokeCap, 4000e6, "DEC-037, DEC-095: 40% of the first deposit, in USDC");
        assertEq(m.pools[0].poolKey, ARB_WETH_USDC_POOL_ID, "DEC-030: hub WETH/USDC 0.05%");
        assertEq(m.pools[1].poolKey, bytes32(uint256(uint160(ARB_USDC))), "DEC-018, DEC-028: Aave USDC on the hub");
        assertEq(m.pools[2].poolKey, RH_WETH_USDG_POOL_ID, "DEC-030: spoke WETH/USDG 0.05%");
        assertEq(m.unwindOrder.length, 2, "feedback question 2: automatic unwind on hub positions only");
        assertEq(m.unwindOrder[0].adapter, hubUni, "DEC-069: hub Uniswap V4 first");
        assertEq(m.unwindOrder[1].adapter, hubAaveAdapter, "DEC-069: then Aave");
        assertEq(m.bridgeAdapters.length, 2, "DEC-088: Across on both sides");
        assertEq(m.bridgeAdapters[0].adapter, predicted.chains[0].acrossBridgeAdapter);
        assertEq(m.bridgeAdapters[1].adapter, predicted.chains[1].acrossBridgeAdapter);
        assertEq(m.payoutFeeBps, 200, "DEC-102: Payout Fee 2%");
        assertEq(m.standardPayoutTerm, 72 hours, "DEC-060: 72 h term");
        assertEq(m.minFirstDeposit, 100e6, "DEC-061: 100 USDC minimum first deposit");
        assertEq(m.performanceFeeBps, 2000, "DEC-107: performance fee 20%");
        assertEq(m.managementFeeBps, 0, "DEC-108: management fee 0");
        assertEq(m.maxBridgeFeeBps, BRIDGE_FEE * 10_000 / BRIDGE_AMOUNT, "QA19: from the quote used (1.60 on 4,000)");
    }

    /// @dev DEC-054: same operator and salt give the same factory address on Robinhood; the Spoke Vault lands at the
    ///      address the hub's Mandate already names.
    function _createSpoke(Mandate memory m, IFundFactory.FundAddresses memory predicted) internal {
        _onRobinhood();
        Deployment memory rd = _deployProtocol(recipient, guardian, registryOwner);
        assertEq(address(rd.factory), address(hubDeployment.factory), "DEC-054: one factory address on both chains");
        vm.prank(manager);
        IFundFactory.ChainAddresses memory s =
            rd.factory.createSpoke(creationNumber, m, _spokeParams(mandateHash, _plan()));
        assertEq(s.spokeVault, predicted.chains[1].spokeVault, "DEC-054: Spoke Vault at its prediction");
        assertEq(toUniversalAddress(s.spokeVault), m.spokes[0].spokeVault);
        spokeVault = ISpokeVault(s.spokeVault);
        spokeUniswap = s.uniswapV4Adapter;
        spokeAcross = s.acrossBridgeAdapter;
        assertEq(spokeVault.mandateHash(), mandateHash, "FF-OQ-1: the spoke's Mandate is the hub's");
        assertEq(spokeVault.coreVault(), address(core));
        assertEq(spokeVault.fundId(), fundId);
        assertEq(spokeVault.baseToken(), RH_USDG);
    }
}
