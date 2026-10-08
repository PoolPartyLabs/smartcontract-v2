// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Eip1271Depositor
/// @notice Test stand-in for a contract depositor that CAN speed up an Across deposit: it answers EIP-1271
///         `isValidSignature` for digests its owner approved. The production TransitEscrow deliberately has no
///         EIP-1271 (DEC-066, QA6); this contract exists only to measure what adding one would take (LC-159).
contract Eip1271Depositor {
    bytes4 internal constant EIP1271_MAGIC = 0x1626ba7e;

    error NotOwner();
    error CallFailed(bytes data);

    address public immutable owner;
    mapping(bytes32 digest => bool) public approved;

    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Approves one speed-up digest (the Across EIP-712 `UpdateDepositDetails` hash).
    function approveDigest(bytes32 digest) external {
        if (msg.sender != owner) revert NotOwner();
        approved[digest] = true;
    }

    /// @notice Approves `spender` for `amount` of `token` and calls `target` with `data` (the deposit).
    function execute(address token, address target, uint256 amount, bytes calldata data) external {
        if (msg.sender != owner) revert NotOwner();
        IERC20(token).approve(target, amount);
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) revert CallFailed(ret);
    }

    /// @notice EIP-1271: valid exactly for approved digests, whatever the signature bytes.
    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return approved[digest] ? EIP1271_MAGIC : bytes4(0xffffffff);
    }
}
