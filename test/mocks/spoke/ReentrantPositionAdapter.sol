// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AdapterGuard} from "../../../src/adapters/AdapterGuard.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";

/// @notice Single-token position adapter that, inside `closePosition`, after it has already transferred the principal
///         back to the vault and before it returns, runs every queued call against the vault and records the
///         outcome. Models a Mandate adapter (pinned, immutable) that tries to re-enter the vault while the ledger is
///         not yet credited.
contract ReentrantPositionAdapter is AdapterGuard, IAdapter {
    using SafeERC20 for IERC20;

    bytes32 public constant POOL = keccak256("reentrant pool");

    address public vault;
    address public immutable token;
    mapping(bytes32 => uint256) public principal;
    bytes32[] internal _keys;
    uint256 internal _nonce;
    bytes[] internal _reentryCalls;
    uint256 public reentriesAttempted;
    uint256 public reentriesSucceeded;

    constructor(address guardian_, address token_) AdapterGuard(guardian_) {
        token = token_;
    }

    function setVault(address vault_) external {
        vault = vault_;
    }

    function queueReentry(bytes calldata data) external {
        _reentryCalls.push(data);
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    function isExactValue() external pure returns (bool) {
        return false;
    }

    function poolTokens(bytes32 poolKey) external view returns (address token0, address token1) {
        if (poolKey != POOL) revert UnknownPool(poolKey);
        return (token, address(0));
    }

    function openPosition(bytes32 poolKey, bytes calldata)
        external
        onlyVault
        returns (bytes32 positionKey, uint256 used0, uint256 used1)
    {
        _requireEntryAllowed();
        if (poolKey != POOL) revert UnknownPool(poolKey);
        used0 = IERC20(token).balanceOf(address(this));
        positionKey = keccak256(abi.encode(address(this), ++_nonce));
        principal[positionKey] = used0;
        _keys.push(positionKey);
        return (positionKey, used0, used1);
    }

    function closePosition(bytes32 positionKey, bytes calldata) external onlyVault returns (Amounts memory a) {
        uint256 p = principal[positionKey];
        if (p == 0) revert UnknownPosition(positionKey);
        principal[positionKey] = 0;
        for (uint256 i; i < _keys.length; ++i) {
            if (_keys[i] == positionKey) {
                _keys[i] = _keys[_keys.length - 1];
                _keys.pop();
                break;
            }
        }
        IERC20(token).safeTransfer(vault, p);
        for (uint256 i; i < _reentryCalls.length; ++i) {
            ++reentriesAttempted;
            (bool ok,) = vault.call(_reentryCalls[i]);
            if (ok) ++reentriesSucceeded;
        }
        a.principal0 = p;
    }

    function increasePosition(bytes32, bytes calldata) external pure returns (uint256, uint256, uint256, uint256) {
        revert UnsupportedOperation();
    }

    function decreasePosition(bytes32, bytes calldata) external pure returns (Amounts memory) {
        revert UnsupportedOperation();
    }

    function collectIncome(bytes32) external pure returns (Amounts memory) {
        revert UnsupportedOperation();
    }

    function positionValue(bytes32 positionKey) external view returns (PositionValue memory v) {
        uint256 p = principal[positionKey];
        if (p == 0) revert UnknownPosition(positionKey);
        v.poolKey = POOL;
        v.poolId = keccak256(abi.encode(POOL));
        v.liquidity = uint128(p);
        v.token0 = token;
        v.principal0 = p;
    }

    function cumulativeIncome(address) external pure returns (uint256) {
        return 0;
    }

    function unwindExitParams(bytes32, uint256, uint256) external pure returns (bool, bytes memory) {
        return (true, "");
    }

    function positionKeys() external view returns (bytes32[] memory) {
        return _keys;
    }
}
