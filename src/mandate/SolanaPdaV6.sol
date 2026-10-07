pragma solidity 0.8.28;

/// @notice DEC-200: canonical Solana SHA-256 seed derivation and Ed25519 decompression check.
library SolanaPdaV6 {
    uint256 private constant PRIME = (uint256(1) << 255) - 19;
    uint256 private constant D = 37095705934669439343138083508754565189542113879843219016388785533085940283555;

    function littleEndian(uint256 value, uint256 length) internal pure returns (bytes memory encoded) {
        encoded = new bytes(length);
        for (uint256 index; index < length; ++index) encoded[index] = bytes1(uint8(value >> (index * 8)));
    }

    function onCurve(bytes32 compressed) internal pure returns (bool) {
        uint256 ordinate;
        for (uint256 index; index < 32; ++index) ordinate |= uint256(uint8(compressed[index])) << (8 * index);
        ordinate = (ordinate & ((uint256(1) << 255) - 1)) % PRIME;
        uint256 squared = mulmod(ordinate, ordinate, PRIME);
        uint256 numerator = addmod(squared, PRIME - 1, PRIME);
        uint256 denominator = addmod(mulmod(D, squared, PRIME), 1, PRIME);
        if (denominator == 0) return false;
        uint256 base = mulmod(numerator, denominator, PRIME);
        uint256 exponent = (PRIME - 1) / 2;
        uint256 result = 1;
        while (exponent != 0) {
            if (exponent & 1 != 0) result = mulmod(result, base, PRIME);
            base = mulmod(base, base, PRIME);
            exponent >>= 1;
        }
        return numerator == 0 || result == 1;
    }

    function derive(bytes memory seeds, bytes32 program) public pure returns (bytes32 address_) {
        for (uint256 bump = 256; bump != 0;) {
            --bump;
            address_ = sha256(abi.encodePacked(seeds, bytes1(uint8(bump)), program, "ProgramDerivedAddress"));
            if (!onCurve(address_)) return address_;
        }
        revert("No Solana PDA bump");
    }

    function fund(uint256 hubChain, address core, uint16 index, bytes32 policyHash, bytes32 program)
        public pure returns (bytes32)
    {
        return derive(abi.encodePacked("fund", littleEndian(hubChain, 8), core, littleEndian(index, 2), policyHash), program);
    }

    function ata(bytes32 vault, bytes32 mint, bytes32 tokenProgram) public pure returns (bytes32) {
        return derive(abi.encodePacked(vault, tokenProgram, mint),
            0x8c97258f4e2489f1bb3d1029148e0d830b5a1399daff1084048e7bd8dbe9f859);
    }
}
