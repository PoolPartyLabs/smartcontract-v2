// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

/// @title CodeStore
/// @notice Holds a fund contract's creation code on chain, split into data contracts, so the Fund Factory can read it
///         without embedding it.
/// @dev Why: a factory cannot embed the creation code of the contracts it deploys when that code does not fit next to
///      its own under the 24,576-byte runtime limit (EIP-170): the Spoke Vault's creation code is about 31 KB and the
///      Uniswap V4 adapter's about 18 KB. Each chunk is a data contract whose runtime is `0x00 ++ bytes` (the SSTORE2
///      layout of Solmate and Solady): the leading STOP makes it uncallable, and it has no SELFDESTRUCT, so the stored
///      bytes are immutable like every fund contract (DEC-022, DEC-058).
library CodeStore {
    /// @notice Largest chunk: runtime limit minus the leading STOP and the 1,000-byte reserve (DEC-131).
    uint256 internal constant MAX_CHUNK = 23_575;

    /// @notice Nothing to store.
    error EmptyCode();

    /// @notice A data contract could not be created.
    error ChunkWriteFailed(uint256 index);

    /// @notice A chunk address holds no stored bytes.
    error EmptyChunk(address chunk);

    /// @notice Stores `data` in as many data contracts as needed, in order.
    /// @dev Used by deployment scripts and tests; the Fund Factory only reads.
    function write(bytes memory data) internal returns (address[] memory chunks) {
        uint256 length = data.length;
        if (length == 0) revert EmptyCode();
        uint256 count = (length + MAX_CHUNK - 1) / MAX_CHUNK;
        chunks = new address[](count);
        for (uint256 i; i < count; ++i) {
            uint256 start = i * MAX_CHUNK;
            uint256 size = length - start < MAX_CHUNK ? length - start : MAX_CHUNK;
            bytes memory part = new bytes(size);
            assembly ("memory-safe") {
                mcopy(add(part, 0x20), add(add(data, 0x20), start), size)
            }
            // PUSH2 (size + 1); DUP1; PUSH1 0x0a; RETURNDATASIZE; CODECOPY; RETURNDATASIZE; RETURN; then STOP ++ data.
            // casting to 'uint16' is safe because size <= MAX_CHUNK, so size + 1 <= 24,576
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes memory initCode = abi.encodePacked(hex"61", uint16(size + 1), hex"80600a3d393df300", part);
            address chunk;
            assembly ("memory-safe") {
                chunk := create(0, add(initCode, 0x20), mload(initCode))
            }
            if (chunk == address(0)) revert ChunkWriteFailed(i);
            chunks[i] = chunk;
        }
    }

    /// @notice The bytes stored across `chunks`, concatenated in order.
    function read(address[] memory chunks) internal view returns (bytes memory data) {
        uint256 total;
        for (uint256 i; i < chunks.length; ++i) {
            uint256 size = chunks[i].code.length;
            if (size < 2) revert EmptyChunk(chunks[i]);
            total += size - 1;
        }
        data = new bytes(total);
        uint256 offset;
        for (uint256 i; i < chunks.length; ++i) {
            address chunk = chunks[i];
            uint256 size = chunk.code.length - 1;
            assembly ("memory-safe") {
                extcodecopy(chunk, add(add(data, 0x20), offset), 1, size)
            }
            offset += size;
        }
    }
}
