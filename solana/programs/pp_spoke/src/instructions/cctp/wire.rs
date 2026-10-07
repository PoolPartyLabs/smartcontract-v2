use super::CctpError;
use anchor_lang::prelude::*;

pub const HUB_DOMAIN: u32 = 3;
pub const SOLANA_DOMAIN: u32 = 5;
pub const HUB_CHAIN: u64 = 42161;
pub const FAST: u32 = 1000;
pub const FEE_SCALE: u128 = 100_000_000;
pub const MESSAGE_LEN: usize = 536;
pub const MESSENGER: Pubkey = pubkey!("CCTPV2vPZJS2u2BBsUoscuikbYjnpFmbFsvVuJdgUMQe");
pub const TRANSMITTER: Pubkey = pubkey!("CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC");
pub const USDC: Pubkey = pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
pub const TOKEN: Pubkey = pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
pub const ATA: Pubkey = pubkey!("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct SendParams {
    pub transit_id: [u8; 32],
    pub amount: u64,
    pub max_fee: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct ReceiveParams {
    pub transit_id: [u8; 32],
    pub message: Vec<u8>,
    pub attestation: Vec<u8>,
}

pub struct Arrival {
    pub amount: u64,
    pub max_fee: u64,
    pub fee_executed: u64,
    pub nonce: [u8; 32],
}

pub fn transit_seed(payload: &[u8]) -> Result<&[u8]> {
    payload
        .get(..32)
        .ok_or_else(|| error!(CctpError::InvalidPayload))
}

pub fn evm(address: &[u8; 20]) -> [u8; 32] {
    let mut word = [0; 32];
    word[12..].copy_from_slice(address);
    word
}

pub fn uint_word(value: u64) -> [u8; 32] {
    let mut word = [0; 32];
    word[24..].copy_from_slice(&value.to_be_bytes());
    word
}

pub fn word_u64(word: &[u8]) -> Result<u64> {
    require!(
        word.len() == 32 && word[..24] == [0; 24],
        CctpError::InvalidAmount
    );
    Ok(u64::from_be_bytes(
        word[24..]
            .try_into()
            .map_err(|_| CctpError::InvalidAmount)?,
    ))
}

pub fn hook(fund_id: &[u8; 32], chain: u64, id: &[u8; 32]) -> Vec<u8> {
    hook_kind(fund_id, chain, id, 0)
}

pub fn hook_kind(fund_id: &[u8;32], chain: u64, id: &[u8;32], kind: u8) -> Vec<u8> {
    [
        uint_word(1).as_slice(),
        fund_id,
        &uint_word(chain),
        id,
        &uint_word(u64::from(kind)),
    ]
    .concat()
}

pub fn fee_bound(amount: u64, max_fee: u64, ceiling: u64) -> Result<u64> {
    require!(
        amount > 0 && max_fee < amount && ceiling > 0 && ceiling < FEE_SCALE as u64,
        CctpError::InvalidAmount
    );
    let cap = (u128::from(amount) * u128::from(ceiling)).div_ceil(FEE_SCALE);
    require!(u128::from(max_fee) <= cap, CctpError::FeeCapExceeded);
    Ok(amount - max_fee)
}

/// DEC-191: exact T2b TransitMessage v1 ABI, not Borsh or JSON; principal only.
pub fn validate_arrival(
    message: &[u8],
    fund_id: &[u8; 32],
    id: &[u8; 32],
    hub_core: &[u8; 20],
    caller: &Pubkey,
    recipient: &Pubkey,
    ceiling: u64,
) -> Result<Arrival> {
    require!(message.len() == MESSAGE_LEN, CctpError::InvalidMessage);
    for (offset, value) in [
        (0, 1u32),
        (4, HUB_DOMAIN),
        (8, SOLANA_DOMAIN),
        (140, FAST),
        (148, 1),
    ] {
        require!(
            message[offset..offset + 4] == value.to_be_bytes(),
            CctpError::InvalidMessage
        );
    }
    let finality = u32::from_be_bytes(
        message[144..148]
            .try_into()
            .map_err(|_| CctpError::InvalidMessage)?,
    );
    require!(finality >= FAST, CctpError::InvalidMessage);
    require!(message[12..44] != [0; 32], CctpError::InvalidMessage);
    require!(
        message[44..76]
            == evm(&[
                0x28, 0xb5, 0xa0, 0xe9, 0xc6, 0x21, 0xa5, 0xba, 0xda, 0xa5, 0x36, 0x21, 0x9b, 0x3a,
                0x22, 0x8c, 0x81, 0x68, 0xcf, 0x5d
            ]),
        CctpError::WrongSender
    );
    require!(
        message[76..108] == MESSENGER.to_bytes(),
        CctpError::WrongRecipient
    );
    require!(
        message[108..140] == caller.to_bytes(),
        CctpError::WrongCaller
    );
    require!(
        message[152..184]
            == evm(&[
                0xaf, 0x88, 0xd0, 0x65, 0xe7, 0x7c, 0x8c, 0xc2, 0x23, 0x93, 0x27, 0xc5, 0xed, 0xb3,
                0xa4, 0x32, 0x26, 0x8e, 0x58, 0x31
            ]),
        CctpError::WrongMint
    );
    require!(
        message[184..216] == recipient.to_bytes(),
        CctpError::WrongRecipient
    );
    require!(message[248..280] == evm(hub_core), CctpError::WrongSender);
    require!(
        message[376..] == hook(fund_id, HUB_CHAIN, id),
        CctpError::InvalidHook
    );
    let amount = word_u64(&message[216..248])?;
    let max_fee = word_u64(&message[280..312])?;
    let fee_executed = word_u64(&message[312..344])?;
    fee_bound(amount, max_fee, ceiling)?;
    require!(fee_executed <= max_fee, CctpError::FeeCapExceeded);
    Ok(Arrival {
        amount,
        max_fee,
        fee_executed,
        nonce: message[12..44]
            .try_into()
            .map_err(|_| CctpError::InvalidMessage)?,
    })
}

pub fn discriminator(name: &str) -> [u8; 8] {
    anchor_lang::solana_program::hash::hash(format!("global:{name}").as_bytes()).to_bytes()[..8]
        .try_into()
        .unwrap()
}

/// Circle v2 source ec16e95d28ee47f7832df4203ae07b5981d146fc, Borsh field order.
pub fn burn_data(
    params: &SendParams,
    hub: &[u8; 20],
    connector: &[u8; 20],
    fund_id: &[u8; 32],
    chain: u64,
) -> Vec<u8> {
    burn_data_kind(params, hub, connector, fund_id, chain, 0)
}

pub fn burn_data_kind(params: &SendParams, hub: &[u8;20], connector: &[u8;20], fund_id: &[u8;32], chain: u64, kind: u8) -> Vec<u8> {
    let hook = hook_kind(fund_id, chain, &params.transit_id, kind);
    [
        discriminator("deposit_for_burn_with_hook").as_slice(),
        &params.amount.to_le_bytes(),
        &HUB_DOMAIN.to_le_bytes(),
        &evm(hub),
        &evm(connector),
        &params.max_fee.to_le_bytes(),
        &FAST.to_le_bytes(),
        &(hook.len() as u32).to_le_bytes(),
        &hook,
    ]
    .concat()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (Vec<u8>, [u8; 32], [u8; 32], [u8; 20], Pubkey, Pubkey) {
        let fund = [7; 32];
        let id = [8; 32];
        let hub = [9; 20];
        let caller = Pubkey::new_unique();
        let recipient = Pubkey::new_unique();
        let mut message = vec![0; MESSAGE_LEN];
        for (offset, value) in [
            (0, 1u32),
            (4, 3),
            (8, 5),
            (140, 1000),
            (144, 1000),
            (148, 1),
        ] {
            message[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
        }
        message[12..44].fill(1);
        message[44..76].copy_from_slice(&evm(&[
            0x28, 0xb5, 0xa0, 0xe9, 0xc6, 0x21, 0xa5, 0xba, 0xda, 0xa5, 0x36, 0x21, 0x9b, 0x3a,
            0x22, 0x8c, 0x81, 0x68, 0xcf, 0x5d,
        ]));
        message[76..108].copy_from_slice(MESSENGER.as_ref());
        message[108..140].copy_from_slice(caller.as_ref());
        message[152..184].copy_from_slice(&evm(&[
            0xaf, 0x88, 0xd0, 0x65, 0xe7, 0x7c, 0x8c, 0xc2, 0x23, 0x93, 0x27, 0xc5, 0xed, 0xb3,
            0xa4, 0x32, 0x26, 0x8e, 0x58, 0x31,
        ]));
        message[184..216].copy_from_slice(recipient.as_ref());
        message[216..248].copy_from_slice(&uint_word(1_000_000));
        message[248..280].copy_from_slice(&evm(&hub));
        message[280..312].copy_from_slice(&uint_word(200));
        message[312..344].copy_from_slice(&uint_word(100));
        message[376..].copy_from_slice(&hook(&fund, HUB_CHAIN, &id));
        (message, fund, id, hub, caller, recipient)
    }

    #[test]
    fn exact_v2_arrival_preserves_fee_surplus_as_principal() {
        let (message, fund, id, hub, caller, recipient) = fixture();
        let arrival =
            validate_arrival(&message, &fund, &id, &hub, &caller, &recipient, 20_000).unwrap();
        assert_eq!(arrival.amount - arrival.max_fee, 999_800);
        assert_eq!(arrival.amount - arrival.fee_executed, 999_900);
        assert_eq!(arrival.max_fee - arrival.fee_executed, 100);
    }

    #[test]
    fn reject_every_authenticated_route_field_mutation() {
        let (message, fund, id, hub, caller, recipient) = fixture();
        for offset in [
            0, 4, 8, 12, 44, 76, 108, 140, 144, 148, 152, 184, 216, 248, 280, 312, 376, 408, 440,
            472, 504,
        ] {
            let mut changed = message.clone();
            if offset == 144 {
                changed[144..148].copy_from_slice(&999u32.to_be_bytes());
            } else if offset == 12 {
                changed[12..44].fill(0);
            } else {
                changed[offset] ^= 1;
            }
            assert!(
                validate_arrival(&changed, &fund, &id, &hub, &caller, &recipient, 20_000).is_err(),
                "offset {offset}"
            );
        }
        assert!(validate_arrival(
            &message[..535],
            &fund,
            &id,
            &hub,
            &caller,
            &recipient,
            20_000
        )
        .is_err());
        let mut trailing = message.clone();
        trailing.push(0);
        assert!(
            validate_arrival(&trailing, &fund, &id, &hub, &caller, &recipient, 20_000).is_err()
        );
    }

    #[test]
    fn fee_bounds_round_up_without_u64_overflow() {
        assert_eq!(fee_bound(1_000_001, 201, 20_000).unwrap(), 999_800);
        assert!(fee_bound(1_000_001, 202, 20_000).is_err());
        assert!(fee_bound(0, 0, 20_000).is_err());
        assert!(fee_bound(1, 1, 20_000).is_err());
        assert!(fee_bound(100, 0, 0).is_err());
        assert!(fee_bound(u64::MAX, 1, 20_000).is_ok());
        assert!(word_u64(&[255; 32]).is_err());
        assert!(transit_seed(&[0; 31]).is_err());
    }

    #[test]
    fn burn_cpi_has_pinned_borsh_offsets_and_abi_hook() {
        let params = SendParams {
            transit_id: [8; 32],
            amount: 1_000_000,
            max_fee: 200,
        };
        let data = burn_data(&params, &[9; 20], &[10; 20], &[7; 32], 123);
        assert_eq!(data.len(), 260);
        assert_eq!(&data[16..20], &3u32.to_le_bytes());
        assert_eq!(&data[20..52], &evm(&[9; 20]));
        assert_eq!(&data[52..84], &evm(&[10; 20]));
        assert_eq!(&data[92..96], &1000u32.to_le_bytes());
        assert_eq!(&data[100..], hook(&[7; 32], 123, &[8; 32]));
    }
}
