// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {CoreMockToken} from "./CoreMockTokens.sol";

/// @notice The hub Spoke Vault surface the Core Vault uses: `buildReport`, `collectedIncome`, `receiveFromCoreVault`,
///         `unwindForPayout`. Its Unallocated Balance is the USDC the Core Vault allocated; one synthetic position holds
///         `positionPrincipal` of a token; cumulative income counters are set by the test.
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
    /// @dev Basis points of the unwound amount lost to market costs (DEC-097).
    uint256 public unwindLossBps;
    UnwindMode public unwindMode;
    bool public buildReverts;
    uint256 public lastUnwindTarget;
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

    /// @notice Unwinds the USDC position (DEC-069, DEC-081): up to `usdcTarget`, minus `unwindLossBps` of market costs.
    function unwindForPayout(uint256 usdcTarget, bytes calldata) external returns (uint256 proceeds) {
        require(msg.sender == coreVault, "not core");
        lastUnwindTarget = usdcTarget;
        if (unwindMode == UnwindMode.Reverts) revert("unwind failed");
        uint256 unwound = usdcTarget < positionPrincipal ? usdcTarget : positionPrincipal;
        positionPrincipal -= unwound;
        proceeds = unwound - unwound * unwindLossBps / 10_000;
        if (proceeds == 0) return 0;
        CoreMockToken(usdc).mint(coreVault, proceeds);
        if (unwindMode == UnwindMode.Callback) ICoreVault(coreVault).returnToIdle(proceeds);
        if (unwindMode == UnwindMode.OverReports) return proceeds * 2;
    }
}
