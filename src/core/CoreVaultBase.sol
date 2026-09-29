// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {Transit, ExpensePayer} from "../interfaces/FundTypes.sol";
import {Mandate, MandateLib, SpokeConfig, BridgeAdapterConfig} from "../mandate/Mandate.sol";
import {ShareMath} from "../libraries/ShareMath.sol";
import {IncomeAccumulator} from "../libraries/IncomeAccumulator.sol";
import {ShareToken} from "./ShareToken.sol";
import {CoreVaultConfig, CoreVaultWiring, CoreVaultState} from "./CoreVaultTypes.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";
import {ICoreVaultExtensions} from "./ICoreVaultExtensions.sol";

/// @title CoreVaultBase
/// @notice Wiring, storage, value-base views and Operating Cash of the Core Vault. See ICoreVault.
/// @dev Split out of CoreVault only to keep each source file reviewable; the abstract layers compile into one
///      contract, and the heavy report logic lives in the linked external library CoreVaultLogic. Events and errors
///      beyond the frozen ICoreVault (including the library's) are declared in ICoreVaultExtensions.
abstract contract CoreVaultBase is ICoreVault, ICoreVaultExtensions, ReentrancyGuardTransient {
    using IncomeAccumulator for IncomeAccumulator.State;

    /// @dev Kind tag of the Operating Cash top-up expense (DEC-041, DEC-096).
    bytes32 internal constant OPERATING_CASH_TOP_UP = keccak256("OPERATING_CASH_TOP_UP");

    // ---------------------------------------------------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------------------------------------------------

    bytes32 public immutable fundId;
    bytes32 public immutable mandateHash;
    address public immutable manager;
    address public immutable usdc;
    address public immutable shareToken;
    address public immutable hubSpokeVault;
    address public immutable reportReceiver;
    address public immutable managerRegistry;
    address public immutable priceSource;
    address public immutable acrossSpokePool;
    address public immutable protocolRecipient;
    address public immutable excessRecipient;
    address public immutable escrowImplementation;
    uint16 public immutable flowFeeBps;
    uint16 public immutable payoutFeeBps;
    uint32 public immutable standardPayoutTerm;
    /// @dev DEC-011: the Hub Chain of the Mandate; the constructor requires `block.chainid` to equal it.
    uint256 internal immutable _hubChainId;
    uint256 internal immutable _minFirstDeposit;
    uint16 internal immutable _maxBridgeFeeBps;

    /// @dev Every mutable value of the Core Vault (see CoreVaultState).
    CoreVaultState internal _s;

    /// @dev Set while the Core Vault waits on `ISpokeVault.unwindForPayout`, so the hub Spoke Vault may call back
    ///      `returnToIdle` and `receiveCollectedIncome` from inside a payout.
    bool internal transient _unwinding;

    // ---------------------------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev No `msg.sender` assumption: a factory may deploy at a CREATE2 address (DEC-053, DEC-054). The manager comes
    ///      from the Mandate only.
    constructor(Mandate memory m, CoreVaultConfig memory c) {
        MandateLib.validate(m);
        if (
            c.usdc == address(0) || c.hubSpokeVault == address(0) || c.reportReceiver == address(0)
                || c.managerRegistry == address(0) || c.priceSource == address(0) || c.acrossSpokePool == address(0)
                || c.protocolRecipient == address(0) || c.excessRecipient == address(0)
                || c.escrowImplementation == address(0) || c.fundId == bytes32(0)
        ) revert ZeroAddress();
        if (c.usdc != m.usdc) revert UsdcMismatch(c.usdc, m.usdc);
        if (block.chainid != m.hubChainId) revert NotOnHubChain(block.chainid, m.hubChainId);
        // DEC-106, DEC-110: flow fee capped at 1% as a core constant.
        if (c.flowFeeBps > ShareMath.MAX_FLOW_FEE_BPS) revert FlowFeeAboveCap(c.flowFeeBps);

        fundId = c.fundId;
        mandateHash = MandateLib.hash(m);
        manager = m.manager;
        usdc = c.usdc;
        hubSpokeVault = c.hubSpokeVault;
        reportReceiver = c.reportReceiver;
        managerRegistry = c.managerRegistry;
        priceSource = c.priceSource;
        acrossSpokePool = c.acrossSpokePool;
        protocolRecipient = c.protocolRecipient;
        excessRecipient = c.excessRecipient;
        escrowImplementation = c.escrowImplementation;
        flowFeeBps = c.flowFeeBps;
        payoutFeeBps = m.payoutFeeBps;
        standardPayoutTerm = m.standardPayoutTerm;
        _hubChainId = m.hubChainId;
        _minFirstDeposit = m.minFirstDeposit;
        _maxBridgeFeeBps = m.maxBridgeFeeBps;

        _s.performanceFeeBps = m.performanceFeeBps;
        _s.managementFeeBps = m.managementFeeBps;
        (_s.operatingCashFloor, _s.operatingCashTopUp) = MandateLib.operatingCashFor(m, m.hubChainId);
        _copyMandate(m);
        _pinBridgeAdapters(m);

        // Q60: closed list of income tokens; USDC always, then the hub pool tokens the factory derived.
        _s.income.registerToken(c.usdc);
        for (uint256 i; i < c.incomeTokens.length; ++i) {
            if (c.incomeTokens[i] != c.usdc) _s.income.registerToken(c.incomeTokens[i]);
        }

        // Q59 OPEN: name and symbol are factory strings; the Core Vault deploys and owns its Share token.
        shareToken = address(new ShareToken(c.shareName, c.shareSymbol, address(this)));
    }

    /// @dev DEC-053: the Mandate is stored once, element by element (value-only structs).
    function _copyMandate(Mandate memory m) private {
        Mandate storage stored = _s.mandate;
        stored.manager = m.manager;
        stored.hubChainId = m.hubChainId;
        stored.usdc = m.usdc;
        for (uint256 i; i < m.adapters.length; ++i) {
            stored.adapters.push(m.adapters[i]);
        }
        for (uint256 i; i < m.pools.length; ++i) {
            stored.pools.push(m.pools[i]);
        }
        for (uint256 i; i < m.unwindOrder.length; ++i) {
            stored.unwindOrder.push(m.unwindOrder[i]);
        }
        for (uint256 i; i < m.spokes.length; ++i) {
            stored.spokes.push(m.spokes[i]);
        }
        for (uint256 i; i < m.bridgeAdapters.length; ++i) {
            stored.bridgeAdapters.push(m.bridgeAdapters[i]);
        }
        for (uint256 i; i < m.operatingCash.length; ++i) {
            stored.operatingCash.push(m.operatingCash[i]);
        }
        stored.payoutFeeBps = m.payoutFeeBps;
        stored.standardPayoutTerm = m.standardPayoutTerm;
        stored.minFirstDeposit = m.minFirstDeposit;
        stored.performanceFeeBps = m.performanceFeeBps;
        stored.managementFeeBps = m.managementFeeBps;
        stored.maxBridgeFeeBps = m.maxBridgeFeeBps;
    }

    /// @dev IBridgeAdapter custody rule 2: pin each hub-side bridge adapter's protocol target (and its codehash, Q17-4
    ///      reading O2) at creation. The bridge adapters are deployed before the Core Vault.
    function _pinBridgeAdapters(Mandate memory m) private {
        for (uint256 i; i < m.bridgeAdapters.length; ++i) {
            BridgeAdapterConfig memory b = m.bridgeAdapters[i];
            if (b.chainId != m.hubChainId || _s.bridgeTarget[b.adapter] != address(0)) continue;
            address target = IBridgeAdapter(b.adapter).target();
            if (target == address(0)) revert BridgeTargetUnset(b.adapter);
            _s.bridgeTarget[b.adapter] = target;
            _s.bridgeCodehash[b.adapter] = b.adapter.codehash;
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------------------------------------------------------

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager(msg.sender);
        _;
    }

    /// @dev The hub Spoke Vault callbacks move no value out and make only static calls, so they do not take the guard;
    ///      they revert while any guarded entry is in progress, except during a payout's automatic unwind.
    modifier onlyHubSpokeVaultCallback() {
        if (msg.sender != hubSpokeVault) revert NotHubSpokeVault(msg.sender);
        if (_reentrancyGuardEntered() && !_unwinding) revert ReentrancyGuardReentrantCall();
        _;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    function mandate() external view returns (Mandate memory) {
        return _s.mandate;
    }

    /// @inheritdoc ICoreVault
    function idle() external view returns (uint256) {
        return _s.idle;
    }

    /// @inheritdoc ICoreVault
    function payoutReserve() external view returns (uint256) {
        return _s.payoutReserve;
    }

    /// @inheritdoc ICoreVault
    function freeIdle() public view returns (uint256) {
        return _s.idle - _s.payoutReserve;
    }

    /// @inheritdoc ICoreVault
    function operatingCash() external view returns (uint256) {
        return _s.operatingCash;
    }

    /// @inheritdoc ICoreVault
    function operatingCashFloor() external view returns (uint256) {
        return _s.operatingCashFloor;
    }

    /// @inheritdoc ICoreVault
    function operatingCashTopUp() external view returns (uint256) {
        return _s.operatingCashTopUp;
    }

    /// @notice Spoke-to-hub arrivals held apart (pending plus strays); outside every base and never swept (DEC-080,
    ///         OQ-01).
    function unmatchedArrivals() external view returns (uint256) {
        return _s.unmatchedArrivals;
    }

    /// @inheritdoc ICoreVault
    function transit(bytes32 transitId) external view returns (Transit memory) {
        return _s.transits[transitId];
    }

    /// @inheritdoc ICoreVault
    function payoutRequest(address shareholder) external view returns (PayoutRequest memory) {
        return _s.requests[shareholder];
    }

    /// @inheritdoc ICoreVault
    function shareAssets() public view returns (uint256 assets) {
        (assets,) = CoreVaultLogic.shareAssets(_s, _wiring());
    }

    /// @inheritdoc ICoreVault
    function sharePrice() external view returns (uint256) {
        return ShareMath.sharePrice(shareAssets(), _totalShares());
    }

    /// @inheritdoc ICoreVault
    function inFlightValue() external view returns (uint256 value) {
        (, value) = CoreVaultLogic.shareAssets(_s, _wiring());
    }

    /// @inheritdoc ICoreVault
    function grossAssets() external view returns (uint256) {
        return CoreVaultLogic.grossAssets(_s, _wiring());
    }

    /// @inheritdoc ICoreVault
    /// @dev DEC-066 B1: `inFlightSent` also counts the spoke's pending return leg (see CoreVaultLogic.spokeCapUsage).
    function spokeCapUsage(uint256 spokeIndex)
        public
        view
        returns (uint256 spokeValue, uint256 inFlightSent, uint256 spokeCap)
    {
        return CoreVaultLogic.spokeCapUsage(_s, _wiring(), spokeIndex);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Operating Cash (DEC-041, DEC-096, DEC-100, DEC-102)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    /// @dev DEC-096: the manager may adjust floor and top-up on a live fund; DEC-100: no protocol cap on the floor.
    function setOperatingCashParameters(uint256 floor, uint256 topUp) external onlyManager {
        _s.operatingCashFloor = floor;
        _s.operatingCashTopUp = topUp;
        emit OperatingCashParametersSet(floor, topUp);
    }

    /// @notice DEC-096, DEC-100, DEC-041: when hub Operating Cash is below its floor, the value-moving operation that
    ///         calls this tops it up by `operatingCashTopUp` from Free Idle (never the Payout Reserve, DEC-072). The
    ///         top-up is an Operating Expense paid by Share Assets (accepted effect on Share Price, DEC-100).
    function _topUpOperatingCash() internal {
        uint256 cash = _s.operatingCash;
        uint256 floor = _s.operatingCashFloor;
        if (cash >= floor) return;
        uint256 amount = _s.operatingCashTopUp;
        uint256 free = freeIdle();
        if (amount > free) amount = free;
        emit OperatingCashInsufficient(cash, floor, amount);
        if (amount == 0) return;
        _s.idle -= amount;
        _s.operatingCash = cash + amount;
        emit OperatingCashToppedUp(amount, cash + amount);
        emit OperatingExpensePaid(_hubChainId, address(0), OPERATING_CASH_TOP_UP, amount, ExpensePayer.ShareAssets);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _wiring() internal view returns (CoreVaultWiring memory) {
        return CoreVaultWiring({
            fundId: fundId,
            manager: manager,
            usdc: usdc,
            shareToken: shareToken,
            hubSpokeVault: hubSpokeVault,
            reportReceiver: reportReceiver,
            managerRegistry: managerRegistry,
            priceSource: priceSource,
            escrowImplementation: escrowImplementation,
            hubChainId: _hubChainId,
            maxBridgeFeeBps: _maxBridgeFeeBps
        });
    }

    /// @notice Every amount of `token` the Core Vault's ledger holds.
    /// @dev DEC-080, DEC-096, DEC-101: Idle, Operating Cash and unmatched arrivals (USDC only) plus the collected income
    ///      of the token. Owed fees and Attributed Income are claims paid out of the collected balance, so they are
    ///      inside it and are not added a second time.
    function _ledger(address token) internal view returns (uint256 amount) {
        amount = _s.collectedIncome[token];
        if (token == usdc) amount += _s.idle + _s.operatingCash + _s.unmatchedArrivals;
    }

    /// @notice Balance of `token` above the ledger: donations, dust, or value transferred just before a credit call.
    function _unledgered(address token) internal view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 ledger = _ledger(token);
        return balance > ledger ? balance - ledger : 0;
    }

    /// @notice DEC-080: a credit call must be backed by tokens already above the ledger.
    function _requireUnledgered(address token, uint256 amount) internal view {
        uint256 unledgered = _unledgered(token);
        if (unledgered < amount) revert UnbackedCredit(token, amount, unledgered);
    }

    function _totalShares() internal view returns (uint256) {
        return IERC20(shareToken).totalSupply();
    }

    function _sharesOf(address holder) internal view returns (uint256) {
        return IERC20(shareToken).balanceOf(holder);
    }

    function _spoke(uint256 spokeIndex) internal view returns (SpokeConfig memory) {
        if (spokeIndex >= _s.mandate.spokes.length) revert UnknownSpoke(spokeIndex);
        return _s.mandate.spokes[spokeIndex];
    }
}
