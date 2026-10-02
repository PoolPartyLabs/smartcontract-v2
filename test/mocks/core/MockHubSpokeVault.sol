// SPDX-License-Identifier: MIT
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
    mapping(bytes32 requestId => bool) public delivered;
    /// @dev When set, `receiveFromCoreVault` calls back `returnToIdle`: a hub callback outside a payout's unwind.
    bool public returnOnReceive;

    address[] internal _incomeTokens;
    mapping(address => uint256) public cumulativeIncome;
    mapping(address => uint256) public collectedIncome;

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
        bool known;
        for (uint256 i; i < _incomeTokens.length; ++i) {
            if (_incomeTokens[i] == token) known = true;
        }
        if (!known) _incomeTokens.push(token);
        cumulativeIncome[token] = amount;
    }

    /// @notice Simulates collected income forwarded to the Core Vault: mints and calls `receiveCollectedIncome`.
    function forwardIncome(address token, uint256 amount) external {
        CoreMockToken(token).mint(coreVault, amount);
        ICoreVault(coreVault).receiveCollectedIncome(token, amount);
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
