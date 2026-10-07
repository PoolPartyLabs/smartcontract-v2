use super::guards::CoreError;
use crate::state::{Asset, Transport, Venue};
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
    pub transport: Transport,
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

/// DEC-191, DEC-199: exact Hub factory CREATE3 connector namespace, not the Core.
pub fn hub_connector(factory: &[u8;20], fund_id: &[u8;32], chain: u64) -> [u8;20] {
    let mut role = [0u8;32];
    role[..20].copy_from_slice(b"CctpReceiveConnector");
    let salt = hash_words(&[*fund_id, role, word(u128::from(chain))]);
    let proxy_code = [0x75,0x36,0x3d,0x3d,0x37,0x36,0x3d,0x34,0xf0,0x60,0x14,0x57,0x3d,0x60,0x00,0x80,0x3e,0x3d,0x60,0x00,0xfd,0x5b,0x00,0x3d,0x52,0x60,0x16,0x60,0x0a,0xf3];
    let proxy_hash = keccak::hashv(&[&[0xff], factory, &salt, &keccak::hash(&proxy_code).to_bytes()]).to_bytes();
    keccak::hashv(&[&[0xd6,0x94], &proxy_hash[12..], &[1]]).to_bytes()[12..].try_into().unwrap()
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
    let digest = binding_digest(payload, manager, emitter);
    verify_signature(&payload.manager_evm, &payload.signature, digest)?;
    Ok(digest)
}

fn verify_signature(manager: &[u8; 20], signature: &[u8; 65], digest: [u8; 32]) -> Result<()> {
    require!(*manager != [0; 20], CoreError::InvalidBinding);
    let scalar: [u8; 32] = signature[32..64].try_into().unwrap();
    require!(
        scalar != [0; 32] && scalar <= HALF_ORDER,
        CoreError::InvalidBinding
    );
    require!(
        signature[64] == 27 || signature[64] == 28,
        CoreError::InvalidBinding
    );
    let recovered = secp256k1_recover(&digest, signature[64] - 27, &signature[..64])
        .map_err(|_| error!(CoreError::InvalidBinding))?;
    let public_hash = keccak::hash(&recovered.to_bytes()).to_bytes();
    require!(
        public_hash[12..] == *manager,
        CoreError::InvalidBinding
    );
    Ok(())
}

/// DEC-190, R6.1: native consent binds the exact tuple; Hub factory consent is separate.
pub fn bootstrap_digest(payload: &InitializePayload, manager: &Pubkey, fund: &Pubkey) -> Result<[u8; 32]> {
    let vault = Pubkey::find_program_address(&[b"vault", fund.as_ref()], &crate::ID).0;
    let domain = hash_words(&[
        keccak::hash(DOMAIN.as_bytes()).to_bytes(),
        keccak::hash(b"PoolParty Solana Fund").to_bytes(),
        keccak::hash(b"6").to_bytes(),
        word(u128::from(payload.hub_chain_id)),
        address_word(&payload.factory),
    ]);
    let message = hash_words(&[
        keccak::hash(b"SolanaBootstrap(uint256 hubChain,address core,bytes32 mandateHash,uint16 spokeIndex,bytes32 program,bytes32 fundPda,bytes32 solanaKey,bytes32 usdcAta,bytes32 tslaxAta,bytes32 nvdaxAta,bytes32 wsolAta,bytes32 nativeMandateHash,bytes32 fundId,uint256 nonce,uint256 expiry)").to_bytes(),
        word(u128::from(payload.hub_chain_id)), address_word(&payload.hub_core), payload.mandate_hash,
        word(u128::from(payload.spoke_index)), crate::ID.to_bytes(), fund.to_bytes(), manager.to_bytes(),
        super::custody::associated_address(&vault, &super::custody::USDC)?.to_bytes(),
        super::custody::associated_address(&vault, &super::custody::TSLAX)?.to_bytes(),
        super::custody::associated_address(&vault, &super::custody::NVDAX)?.to_bytes(),
        super::custody::associated_address(&vault, &super::custody::WSOL)?.to_bytes(),
        payload.native_mandate_hash, payload.fund_id, payload.nonce, word(u128::from(payload.expiry)),
    ]);
    Ok(keccak::hashv(&[b"\x19\x01", &domain, &message]).to_bytes())
}

pub fn verify_bootstrap(payload: &InitializePayload, manager: &Pubkey, fund: &Pubkey, now: i64) -> Result<()> {
    require!(now >= 0 && now as u64 <= payload.expiry, CoreError::BindingExpired);
    verify_signature(&payload.manager_evm, &payload.signature, bootstrap_digest(payload, manager, fund)?)
}

/// DEC-053, DEC-190: canonical abi.encode(uint256(6), Config), not Borsh.
pub fn native_mandate_hash(
    manager: &Pubkey,
    emitter: &Pubkey,
    chain: u64,
    assets: &[Asset],
    venues: &[Venue],
    transport: &Transport,
) -> [u8; 32] {
    let mut words = vec![
        word(6),
        word(64),
        crate::ID.to_bytes(),
        emitter.to_bytes(),
        super::custody::USDC.to_bytes(),
        manager.to_bytes(),
        word(u128::from(chain)),
        word(512),
        word(512 + 32 + (assets.len() as u128) * 96),
        address_word(&transport.hub_usdc),
        address_word(&transport.token_messenger),
        address_word(&transport.message_transmitter),
        word(u128::from(transport.destination_domain)),
        transport.mint_recipient.to_bytes(),
        transport.destination_caller.to_bytes(),
        transport.remote_token_messenger.to_bytes(),
        transport.remote_vault_authority.to_bytes(),
        word(u128::from(transport.fast_fee_ceiling)),
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
            assets: vec![], venues: vec![], transport: Transport::default(),
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
    fn complete_transport_hash_matches_independent_evm_abi() {
        let manager = Pubkey::new_from_array(fixed_hex(
            "0f0248bf50f38b8fa1b2f34e5ee9070476e3c10c3e72eefd4e4ddc58e0a5a3a1",
        ));
        let emitter = Pubkey::new_from_array(fixed_hex(
            "1ee39f01232b2e295e21e516f476e557768949820bc25b6f3b5466250070b0f1",
        ));
        let vault = Pubkey::new_from_array(fixed_hex(
            "f33ef011782bb01b1cf6ea9095db6c03278a314b670e89eb33101bd25dcd9dd4",
        ));
        let transport = Transport {
            hub_usdc: fixed_hex("af88d065e77c8cc2239327c5edb3a432268e5831"),
            token_messenger: fixed_hex("28b5a0e9c621a5badaa536219b3a228c8168cf5d"),
            message_transmitter: fixed_hex("81d40f21f12a8f0e3252bccb954d722d4c464b64"),
            destination_domain: 5,
            mint_recipient: Pubkey::new_from_array(fixed_hex(
                "7982cec8701aa4528f0d651030ecac78bb73226fe7646083d8d29db7d79ceeaa",
            )),
            destination_caller: vault,
            remote_token_messenger: super::super::custody::CCTP_MESSENGER,
            remote_vault_authority: vault,
            fast_fee_ceiling: 50_000,
        };
        let assets = vec![Asset {
            mint: super::super::custody::USDC,
            accounting_id: fixed_hex("06dcacb276039c31d0c4d13c8d7b4d129b4e7253"),
            stock: false,
        }];
        let venues = vec![Venue {
            program: pubkey!("KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD"),
            pool: Pubkey::default(),
            reserve: pubkey!("D6q6wuQSrifJKZYpR1M8R4YawnLDtDsMmWM1NbBmgJ59"),
            token0: super::super::custody::USDC,
            token1: Pubkey::default(),
        }];
        let expected =
            fixed_hex("8bedf458b0756b03aef050251911a6ab3494ed4085546059c31f352e802e2d40");
        assert_eq!(
            native_mandate_hash(&manager, &emitter, 1, &assets, &venues, &transport),
            expected
        );
        let mut changed = transport.clone();
        changed.fast_fee_ceiling += 1;
        assert_ne!(
            native_mandate_hash(&manager, &emitter, 1, &assets, &venues, &changed),
            expected
        );
    }

    #[test]
    fn connector_matches_hub_create3_namespace() {
        assert_eq!(hub_connector(&[3;20], &word(1), 42161), fixed_hex("8c5438e4a5361b9b8d5a0e91a04c80083967ef9d"));
    }

    #[test]
    fn exact_bootstrap_tuple_and_mandate_namespace_cannot_be_substituted() {
        let (payload, manager, _) = fixture();
        let (fund, _) = Pubkey::find_program_address(&[b"fund", &payload.hub_core, &payload.spoke_index.to_le_bytes(), &payload.mandate_hash], &crate::ID);
        let expected = bootstrap_digest(&payload, &manager, &fund).unwrap();
        assert_ne!(expected, bootstrap_digest(&payload, &Pubkey::new_unique(), &fund).unwrap());
        assert_ne!(expected, bootstrap_digest(&payload, &manager, &Pubkey::new_unique()).unwrap());
        for variant in 0..8 {
            let mut changed = payload.clone();
            match variant {
                0 => changed.mandate_hash[0] ^= 1, 1 => changed.spoke_index += 1,
                2 => changed.hub_core[0] ^= 1, 3 => changed.hub_chain_id += 1,
                4 => changed.nonce[31] += 1, 5 => changed.expiry += 1,
                6 => changed.native_mandate_hash[0] ^= 1, _ => changed.fund_id[0] ^= 1,
            }
            assert_ne!(expected, bootstrap_digest(&changed, &manager, &fund).unwrap());
        }
        let mut squatter = payload.clone(); squatter.mandate_hash[0] ^= 1;
        let (squatter_fund, _) = Pubkey::find_program_address(&[b"fund", &squatter.hub_core, &squatter.spoke_index.to_le_bytes(), &squatter.mandate_hash], &crate::ID);
        assert_ne!(fund, squatter_fund);
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
