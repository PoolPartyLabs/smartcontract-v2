pragma solidity 0.8.28;

import {Mandate, MandateLib} from "./Mandate.sol";
import {SolanaMandateV6} from "./SolanaMandateV6.sol";
import {SolanaPdaV6} from "./SolanaPdaV6.sol";

/// @notice DEC-200 coordinator refinement: identity-free policy precedes native derivation.
library SolanaPolicyV6 {
    struct Commitment {
        bytes32 policyHash;
        uint16 spokeIndex;
        bytes32 fundPda;
        bytes32 usdcAta;
        bytes32 stockAta;
        bytes32 nvdaxAta;
        bytes32 wsolAta;
    }

    error InvalidPolicyCommitment();

    function hubPolicyHash(Mandate memory mandate_, uint16 index) public pure returns (bytes32) {
        if (index >= mandate_.spokes.length || mandate_.spokes[index].wormholeChainId != 1) {
            revert InvalidPolicyCommitment();
        }
        bytes32 emitter = mandate_.spokes[index].spokeVault;
        mandate_.spokes[index].spokeVault = 0;
        bytes32 result = MandateLib.hash(mandate_);
        mandate_.spokes[index].spokeVault = emitter;
        return result;
    }

    function nativePolicyHash(SolanaMandateV6.Config memory native) public pure returns (bytes32) {
        native = abi.decode(abi.encode(native), (SolanaMandateV6.Config));
        native.spoke = 0;
        native.transport.mintRecipient = 0;
        native.transport.destinationCaller = 0;
        native.transport.remoteVaultAuthority = 0;
        return SolanaMandateV6.hash(native);
    }

    function hash(bytes32 hubPolicy, bytes32 nativePolicy) public pure returns (bytes32) {
        return keccak256(abi.encode(keccak256("PoolParty/SolanaPolicy/v6"), hubPolicy, nativePolicy));
    }

    function validate(Mandate memory mandate_, SolanaMandateV6.Config memory native, Commitment memory commitment)
        public pure returns (bytes32 hubPolicy)
    {
        hubPolicy = hubPolicyHash(mandate_, commitment.spokeIndex);
        if (
            commitment.policyHash != hash(hubPolicy, nativePolicyHash(native)) || commitment.fundPda == 0
                || commitment.usdcAta != native.transport.mintRecipient || commitment.stockAta == 0
                || commitment.nvdaxAta == 0 || commitment.wsolAta == 0 || commitment.fundPda == native.spoke
        ) revert InvalidPolicyCommitment();
    }

    function validateIdentities(uint256 hubChain, address core, SolanaMandateV6.Config memory native, Commitment memory commitment)
        public pure
    {
        bytes32 fund = SolanaPdaV6.fund(hubChain, core, commitment.spokeIndex, commitment.policyHash, native.program);
        bytes32 vault = SolanaPdaV6.derive(abi.encodePacked("vault", fund), native.program);
        bytes32 token = 0x06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9;
        bytes32 token2022 = 0x06ddf6e1ee758fde18425dbce46ccddab61afc4d83b90d27febdf928d8a18bfc;
        if (
            fund != commitment.fundPda || native.spoke != SolanaPdaV6.derive(abi.encodePacked("emitter", fund), native.program)
                || native.transport.destinationCaller != vault || native.transport.remoteVaultAuthority != vault
                || commitment.usdcAta != SolanaPdaV6.ata(vault, native.usdcMint, token)
                || commitment.stockAta != SolanaPdaV6.ata(vault, 0x07e83582411fea1482f0994b80aa512a97c94f25df283bec5a67a381fc862b4a, token2022)
                || commitment.nvdaxAta != SolanaPdaV6.ata(vault, 0x07e8a50e140fda5791f4566a957fd3ae3f873e6a3466ffc13d79119dfa9ab50a, token2022)
                || commitment.wsolAta != SolanaPdaV6.ata(vault, 0x069b8857feab8184fb687f634618c035dac439dc1aeb3b5598a0f00000000001, token)
        ) revert InvalidPolicyCommitment();
    }

    function fullHash(bytes32 mandateHash, bytes32 nativeHash, Commitment memory commitment)
        public pure returns (bytes32)
    {
        return keccak256(abi.encode(uint256(6), mandateHash, nativeHash, commitment));
    }

    function bootstrapHash(
        bytes32 typehash, uint256 hubChain, address core, bytes32 mandateHash,
        SolanaMandateV6.Config memory native, Commitment memory commitment,
        bytes32 fundId, uint256 nonce, uint256 expiry
    ) public pure returns (bytes32) {
        bytes32[17] memory words;
        words[0] = typehash;
        words[1] = bytes32(hubChain);
        words[2] = bytes32(uint256(uint160(core)));
        words[3] = mandateHash;
        words[4] = commitment.policyHash;
        words[5] = bytes32(uint256(commitment.spokeIndex));
        words[6] = native.program;
        words[7] = commitment.fundPda;
        words[8] = native.managerKey;
        words[9] = commitment.usdcAta;
        words[10] = commitment.stockAta;
        words[11] = commitment.nvdaxAta;
        words[12] = commitment.wsolAta;
        words[13] = SolanaMandateV6.hash(native);
        words[14] = fundId;
        words[15] = bytes32(nonce);
        words[16] = bytes32(expiry);
        return keccak256(abi.encode(words));
    }
}
