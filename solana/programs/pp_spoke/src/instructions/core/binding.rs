use super::guards::CoreError;
use crate::state::{Asset, Venue};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{keccak, secp256k1_recover::secp256k1_recover};

pub const TYPE: &str = "ManagerSolanaBinding(bytes32 solanaKey,address fund,bytes32 spoke,uint256 spokeChainId,bytes32 nativeMandateHash,uint256 nonce,uint256 expiry)";
const DOMAIN: &str =
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
const HALF_ORDER: [u8; 32] = [
    0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0x5d, 0x57, 0x6e, 0x73, 0x57, 0xa4, 0x50, 0x1d, 0xdf, 0xe9, 0x2f, 0x46, 0x68, 0x1b, 0x20, 0xa0,
];

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct InitializePayload {
    pub hub_core: [u8; 20],
    pub spoke_index: u16,
    pub fund_id: [u8; 32],
    pub mandate_hash: [u8; 32],
    pub manager_evm: [u8; 20],
    pub factory: [u8; 20],
    pub hub_chain_id: u64,
    pub spoke_chain_id: u64,
    pub native_mandate_hash: [u8; 32],
    pub nonce: [u8; 32],
    pub expiry: u64,
    pub signature: [u8; 65],
    pub assets: Vec<Asset>,
    pub venues: Vec<Venue>,
}

pub fn word(value: u128) -> [u8; 32] {
    let mut result = [0u8; 32];
    result[16..].copy_from_slice(&value.to_be_bytes());
    result
}

pub fn address_word(address: &[u8; 20]) -> [u8; 32] {
    let mut result = [0u8; 32];
    result[12..].copy_from_slice(address);
    result
}

pub fn hash_words(words: &[[u8; 32]]) -> [u8; 32] {
    keccak::hash(&words.concat()).to_bytes()
}

/// DEC-190: exact T2a v6 domain/type, full-width key/emitter and OZ low-s semantics.
pub fn binding_digest(payload: &InitializePayload, manager: &Pubkey, emitter: &Pubkey) -> [u8; 32] {
    let domain = hash_words(&[
        keccak::hash(DOMAIN.as_bytes()).to_bytes(),
        keccak::hash(b"PoolParty Solana Fund").to_bytes(),
        keccak::hash(b"6").to_bytes(),
        word(u128::from(payload.hub_chain_id)),
        address_word(&payload.factory),
    ]);
    let message = hash_words(&[
        keccak::hash(TYPE.as_bytes()).to_bytes(),
        manager.to_bytes(),
        address_word(&payload.hub_core),
        emitter.to_bytes(),
        word(u128::from(payload.spoke_chain_id)),
        payload.native_mandate_hash,
        payload.nonce,
        word(u128::from(payload.expiry)),
    ]);
    keccak::hashv(&[b"\x19\x01", &domain, &message]).to_bytes()
}

pub fn verify_binding(
    payload: &InitializePayload,
    manager: &Pubkey,
    emitter: &Pubkey,
    now: i64,
) -> Result<[u8; 32]> {
    require!(
        now >= 0 && now as u64 <= payload.expiry,
        CoreError::BindingExpired
    );
    require!(payload.manager_evm != [0; 20], CoreError::InvalidBinding);
    let signature = &payload.signature;
    let scalar: [u8; 32] = signature[32..64].try_into().unwrap();
    require!(
        scalar != [0; 32] && scalar <= HALF_ORDER,
        CoreError::InvalidBinding
    );
    require!(
        signature[64] == 27 || signature[64] == 28,
        CoreError::InvalidBinding
    );
    let digest = binding_digest(payload, manager, emitter);
    let recovered = secp256k1_recover(&digest, signature[64] - 27, &signature[..64])
        .map_err(|_| error!(CoreError::InvalidBinding))?;
    let public_hash = keccak::hash(&recovered.to_bytes()).to_bytes();
    require!(
        public_hash[12..] == payload.manager_evm,
        CoreError::InvalidBinding
    );
    Ok(digest)
}

/// DEC-053, DEC-190: canonical abi.encode(uint256(6), Config), not Borsh.
pub fn native_mandate_hash(
    manager: &Pubkey,
    emitter: &Pubkey,
    chain: u64,
    assets: &[Asset],
    venues: &[Venue],
) -> [u8; 32] {
    let mut words = vec![
        word(6),
        word(64),
        crate::ID.to_bytes(),
        emitter.to_bytes(),
        super::custody::USDC.to_bytes(),
        manager.to_bytes(),
        word(u128::from(chain)),
        word(224),
        word(224 + 32 + (assets.len() as u128) * 96),
        word(assets.len() as u128),
    ];
    for asset in assets {
        words.extend([
            asset.mint.to_bytes(),
            address_word(&asset.accounting_id),
            word(u128::from(asset.stock)),
        ]);
    }
    words.push(word(venues.len() as u128));
    for venue in venues {
        words.extend([
            venue.program.to_bytes(),
            venue.pool.to_bytes(),
            venue.reserve.to_bytes(),
            venue.token0.to_bytes(),
            venue.token1.to_bytes(),
        ]);
    }
    hash_words(&words)
}

pub fn accounting_alias(mint: &Pubkey) -> [u8; 20] {
    let mut encoded = vec![word(96), word(1), mint.to_bytes(), word(24)];
    let mut namespace = [0; 32];
    namespace[..24].copy_from_slice(b"PoolParty/SolanaAsset/v6");
    encoded.push(namespace);
    hash_words(&encoded)[12..].try_into().unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixed_hex<const SIZE: usize>(input: &str) -> [u8; SIZE] {
        std::array::from_fn(|index| {
            u8::from_str_radix(&input[index * 2..index * 2 + 2], 16).unwrap()
        })
    }

    fn fixture() -> (InitializePayload, Pubkey, Pubkey) {
        let payload = InitializePayload {
            hub_core: [2; 20], spoke_index: 0, fund_id: word(1), mandate_hash: word(2),
            manager_evm: fixed_hex("6c3dfc98120ec46f07e9c6b1ff69f33a001bf7d3"), factory: [3; 20],
            hub_chain_id: 42161, spoke_chain_id: 1, native_mandate_hash: word(7), nonce: word(9),
            expiry: 2_000_000_000,
            signature: fixed_hex("67f384b05c9b8f7b208e872b0ebb9f7c2a83f2b1a4820e9d3e8246abb15bf3994fa5587a8e452afa7010de273152237875c920a270f1c9fccbe4602722d2e3bd1c"),
            assets: vec![], venues: vec![],
        };
        (
            payload,
            Pubkey::new_from_array([4; 32]),
            Pubkey::new_from_array(fixed_hex(
                "07f093b39a102fb41eb5f221512e72f5af084d7db72b1a5158313f7db556efbd",
            )),
        )
    }

    #[test]
    fn independent_eip712_signature_recovers_expected_manager() {
        let (payload, manager, emitter) = fixture();
        let expected =
            fixed_hex("7f0d0fe3056003fb4654f099f5bf8831906d1f6837fd70f880e0980f6d924dc4");
        assert_eq!(binding_digest(&payload, &manager, &emitter), expected);
        assert_eq!(
            verify_binding(&payload, &manager, &emitter, 2_000_000_000).unwrap(),
            expected
        );
    }

    #[test]
    fn wrong_signer_expiry_domain_fund_nonce_and_malleability_fail() {
        let (payload, manager, emitter) = fixture();
        assert!(verify_binding(&payload, &Pubkey::new_unique(), &emitter, 1).is_err());
        assert!(verify_binding(&payload, &manager, &Pubkey::new_unique(), 1).is_err());
        assert!(verify_binding(&payload, &manager, &emitter, 2_000_000_001).is_err());
        for variant in 0..7 {
            let mut changed = payload.clone();
            match variant {
                0 => changed.hub_core[0] ^= 1,
                1 => changed.factory[0] ^= 1,
                2 => changed.hub_chain_id += 1,
                3 => changed.nonce[31] += 1,
                4 => changed.manager_evm[0] ^= 1,
                5 => changed.signature[32..64].fill(255),
                _ => changed.signature[64] = 0,
            }
            assert!(verify_binding(&changed, &manager, &emitter, 1).is_err());
        }
    }
}
