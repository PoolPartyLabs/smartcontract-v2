// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ISpokeVaultUnwind} from "../../../src/interfaces/ISpokeVaultUnwind.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {CoreMockToken} from "./CoreMockTokens.sol";

/// @notice The hub Spoke Vault surface the Core Vault uses: `buildReport`, `collectedIncome`, `receiveFromCoreVault`,
///         `unallocatedBalance`, `unwindForPayout`. Its Unallocated Balance is the USDC the Core Vault allocated; one
///         synthetic USDC position holds `positionPrincipal`; cumulative income counters are set by the test.
/// @dev The proportional unwind (DEC-137) in miniature: the whole Unallocated USDC is paid into Idle (D-11) and, when
///      the fraction is non-zero, `fracNum / fracDen` of the position is unwound as one sale losing `unwindLossBps`
///      against its value (DEC-118), whose Market Cost is the requester's by mode (Instant all, Standard the excess over
///      1%, DEC-141). The position delivers once per request id (DEC-151) unless `excludePosition` leaves it out
///      (DEC-148).
///         `unwindForPayout`, `collectIncomeAll`. Its Unallocated Balance is the USDC the Core Vault allocated; one
///         synthetic position holds `positionPrincipal` of a token; cumulative income counters are set by the test.
/// @dev Hub income (WP-10): `earn` advances a token's monotonic counter (what the Core Vault recognizes at every mint
///      and burn) and the income a collection will find; `collectIncomeAll` takes it all, sells every non-USDC token at
///      the rate the test set (`setSaleRate`; none set: the sale fails and the token stays) and pays the Core Vault the
///      USDC obtained.
contract MockHubSpokeVault {
    enum UnwindMode {
        Callback, // transfers USDC and calls ICoreVault.returnToIdle
        Plain, // transfers USDC and only returns the amount
        Reverts,
        OverReports // returns more than it transferred
    }

    address public coreVault;
    address public immutable usdc;
    uint256 public unallocatedUsdc;
    address public positionToken;
    uint256 public positionPrincipal;
    uint256 public positionIncome;
    /// @dev Basis points of the unwound amount lost to the sale (fee plus price impact, DEC-118).
    uint256 public unwindLossBps;
    UnwindMode public unwindMode;
    bool public buildReverts;
    /// @dev When set, the position's step fails and it is left out (DEC-148).
    bool public excludePosition;
    /// @dev The last unwind request and how many unwinds ran.
    ISpokeVaultUnwind.UnwindRequest public lastRequest;
    uint256 public unwindCalls;
    uint256 public closureCost;
    mapping(bytes32 requestId => bool) public delivered;
    /// @dev When set, `receiveFromCoreVault` calls back `returnToIdle`: a hub callback outside a payout's unwind.
    bool public returnOnReceive;

    address[] internal _incomeTokens;
    mapping(address => uint256) public cumulativeIncome;
    mapping(address => uint256) public collectedIncome;
    mapping(address => uint256) public collectable;
    mapping(address => uint256) public saleRate;
    mapping(address => uint256) public saleUnit;
    bool public collectReverts;
    uint16 public lastMaxLossBps;
    uint256 public collections;

    constructor(address usdc_) {
        usdc = usdc_;
        positionToken = usdc_;
    }

    function setCoreVault(address core) external {
        coreVault = core;
    }

    function setPosition(address token, uint256 principal) external {
        positionToken = token;
        positionPrincipal = principal;
    }

    /// @notice Simulates opening a USDC position from Unallocated Balance.
    function moveToPosition(uint256 amount) external {
        unallocatedUsdc -= amount;
        positionToken = usdc;
        positionPrincipal += amount;
    }

    function setPositionIncome(uint256 income) external {
        positionIncome = income;
    }

    function setUnwindMode(UnwindMode mode) external {
        unwindMode = mode;
    }

    function setUnwindLossBps(uint256 bps) external {
        unwindLossBps = bps;
    }

    function setExcludePosition(bool on) external {
        excludePosition = on;
    }

    function setBuildReverts(bool r) external {
        buildReverts = r;
    }

    function setReturnOnReceive(bool on) external {
        returnOnReceive = on;
    }

    function setCumulativeIncome(address token, uint256 amount) external {
        _track(token);
        cumulativeIncome[token] = amount;
    }

    /// @notice Income in the hub positions: the counter grows by `amount` and a collection will find it.
    function earn(address token, uint256 amount) external {
        _track(token);
        cumulativeIncome[token] += amount;
        collectable[token] += amount;
    }

    /// @notice USDC (6 decimals) per whole `token` a collection's sale obtains; 0 makes the sale fail.
    function setSaleRate(address token, uint256 usdcPerUnit, uint256 unit) external {
        saleRate[token] = usdcPerUnit;
        saleUnit[token] = unit;
    }

    /// @notice ISpokeVaultIncome.collectIncomeAll: takes every token's collectable income, sells it at the set rate and
    ///         pays the USDC to the Core Vault.
    function collectIncomeAll(uint16 maxLossBps)
        external
        returns (address[] memory tokens, uint256[] memory sold, uint256[] memory obtained)
    {
        require(msg.sender == coreVault, "not core");
        require(!collectReverts, "collect reverts");
        lastMaxLossBps = maxLossBps;
        ++collections;
        tokens = _incomeTokens;
        sold = new uint256[](tokens.length);
        obtained = new uint256[](tokens.length);
        uint256 total;
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 amount = collectable[token];
            if (amount == 0) continue;
            if (token == usdc) {
                (sold[i], obtained[i]) = (amount, amount);
            } else if (saleRate[token] != 0) {
                (sold[i], obtained[i]) = (amount, amount * saleRate[token] / saleUnit[token]);
            } else {
                continue;
            }
            collectable[token] = 0;
            total += obtained[i];
        }
        if (total != 0) CoreMockToken(usdc).mint(coreVault, total);
    }

    function setCollectReverts(bool r) external {
        collectReverts = r;
    }

    function _track(address token) internal {
        for (uint256 i; i < _incomeTokens.length; ++i) {
            if (_incomeTokens[i] == token) return;
        }
        _incomeTokens.push(token);
    }

    /// @notice Simulates `returnToCoreVault`: transfers Unallocated USDC and calls `returnToIdle`.
    function returnToCore(uint256 amount) external {
        unallocatedUsdc -= amount;
        IERC20(usdc).transfer(coreVault, amount);
        ICoreVault(coreVault).returnToIdle(amount);
    }

    function receiveFromCoreVault(uint256 amount) external {
        require(msg.sender == coreVault, "not core");
        unallocatedUsdc += amount;
        if (returnOnReceive) ICoreVault(coreVault).returnToIdle(amount);
    }

    function buildReport() external view returns (ReportCodec.Report memory r) {
        require(!buildReverts, "build reverts");
        r.unallocated = new ReportCodec.TokenAmount[](1);
        r.unallocated[0] = ReportCodec.TokenAmount(usdc, unallocatedUsdc);
        if (positionPrincipal != 0 || positionIncome != 0) {
            r.positions = new ReportCodec.PositionReport[](1);
            r.positions[0].token0 = positionToken;
            r.positions[0].principal0 = positionPrincipal;
            r.positions[0].income0 = positionIncome;
        }
        r.cumulativeIncome = new ReportCodec.TokenAmount[](_incomeTokens.length);
        for (uint256 i; i < _incomeTokens.length; ++i) {
            r.cumulativeIncome[i] = ReportCodec.TokenAmount(_incomeTokens[i], cumulativeIncome[_incomeTokens[i]]);
        }
        r.timestamp = uint64(block.timestamp);
        r.blockNumber = uint64(block.number);
    }

    function unallocatedBalance(address token) external view returns (uint256) {
        return token == usdc ? unallocatedUsdc : 0;
    }

    /// @notice The proportional unwind in miniature (see the contract notes).
    function unwindForPayout(ISpokeVaultUnwind.UnwindRequest calldata r)
        external
        returns (ISpokeVaultUnwind.UnwindResult memory res)
    {
        require(msg.sender == coreVault, "not core");
        lastRequest = r;
        ++unwindCalls;
        if (unwindMode == UnwindMode.Reverts) revert("unwind failed");
        uint256 sold;
        if (r.fracNum != 0 && !delivered[r.requestId] && positionPrincipal != 0) {
            if (excludePosition) {
                res.excluded = 1;
            } else {
                sold = Math.mulDiv(positionPrincipal, r.fracNum, r.fracDen, Math.Rounding.Ceil);
                if (sold > positionPrincipal) sold = positionPrincipal;
                positionPrincipal -= sold;
                res.spotOut = sold;
                res.marketCost = sold * unwindLossBps / 10_000;
                uint256 absorbed = r.mode == ICoreVaultPayouts.PayoutMode.Instant ? 0 : sold / 100;
                res.leaverCost = res.marketCost > absorbed ? res.marketCost - absorbed : 0;
                res.delivered = 1;
                delivered[r.requestId] = true;
            }
        }
        res.proceeds = unallocatedUsdc + sold - res.marketCost;
        unallocatedUsdc = 0;
        if (res.proceeds == 0) return res;
        CoreMockToken(usdc).mint(coreVault, sold - res.marketCost);
        // The pulled Unallocated USDC was transferred by the Core Vault's allocation and is held here.
        if (res.proceeds > sold - res.marketCost) {
            IERC20(usdc).transfer(coreVault, res.proceeds - (sold - res.marketCost));
        }
        if (unwindMode == UnwindMode.Callback) ICoreVault(coreVault).returnToIdle(res.proceeds);
        if (unwindMode == UnwindMode.OverReports) res.proceeds *= 2;
    }
}
