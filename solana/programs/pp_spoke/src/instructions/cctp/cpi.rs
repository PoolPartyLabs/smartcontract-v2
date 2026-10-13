use super::{wire::*, CctpError};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    instruction::{AccountMeta, Instruction},
    program::invoke_signed,
};

pub fn pda(program: &Pubkey, seeds: &[&[u8]]) -> Pubkey {
    Pubkey::find_program_address(seeds, program).0
}

pub fn ata(vault: &Pubkey) -> Pubkey {
    pda(&ATA, &[vault.as_ref(), TOKEN.as_ref(), USDC.as_ref()])
}

pub fn balance(account: &AccountInfo, vault: &Pubkey) -> Result<u64> {
    require_keys_eq!(*account.owner, TOKEN, CctpError::InvalidAccount);
    require_keys_eq!(account.key(), ata(vault), CctpError::InvalidAccount);
    let data = account.try_borrow_data()?;
    require!(
        data.len() == 165
            && data[..32] == USDC.to_bytes()
            && data[32..64] == vault.to_bytes()
            && data[108] == 1,
        CctpError::InvalidAccount
    );
    require!(
        data[72..76] == [0; 4] && data[109..113] == [0; 4] && data[129..133] == [0; 4],
        CctpError::InvalidAccount
    );
    Ok(u64::from_le_bytes(
        data[64..72]
            .try_into()
            .map_err(|_| CctpError::InvalidAccount)?,
    ))
}

pub fn execute<'info>(
    program: Pubkey,
    data: Vec<u8>,
    accounts: &[AccountInfo<'info>],
    expected: &[(Pubkey, bool, bool)],
    seeds: &[&[u8]],
) -> Result<()> {
    require!(
        accounts.len() == expected.len() + 1,
        CctpError::InvalidAccount
    );
    let target = accounts.last().ok_or(CctpError::InvalidAccount)?;
    require!(
        target.key() == program && target.executable,
        CctpError::InvalidAccount
    );
    let mut metas = Vec::with_capacity(expected.len());
    for (account, (key, signer, writable)) in accounts.iter().zip(expected) {
        require_keys_eq!(account.key(), *key, CctpError::InvalidAccount);
        require!(!writable || account.is_writable, CctpError::InvalidAccount);
        metas.push(if *writable {
            AccountMeta::new(*key, *signer)
        } else {
            AccountMeta::new_readonly(*key, *signer)
        });
    }
    invoke_signed(
        &Instruction {
            program_id: program,
            accounts: metas,
            data,
        },
        accounts,
        &[seeds],
    )
    .map_err(Into::into)
}

pub fn burn_accounts(vault: Pubkey, payer: Pubkey, event: Pubkey) -> Vec<(Pubkey, bool, bool)> {
    vec![
        (vault, true, false),
        (payer, true, true),
        (pda(&MESSENGER, &[b"sender_authority"]), false, false),
        (ata(&vault), false, true),
        (
            pda(&MESSENGER, &[b"denylist_account", vault.as_ref()]),
            false,
            false,
        ),
        (pda(&TRANSMITTER, &[b"message_transmitter"]), false, true),
        (pda(&MESSENGER, &[b"token_messenger"]), false, false),
        (
            pda(&MESSENGER, &[b"remote_token_messenger", b"3"]),
            false,
            false,
        ),
        (pda(&MESSENGER, &[b"token_minter"]), false, false),
        (
            pda(&MESSENGER, &[b"local_token", USDC.as_ref()]),
            false,
            true,
        ),
        (USDC, false, true),
        (event, true, true),
        (TRANSMITTER, false, false),
        (MESSENGER, false, false),
        (TOKEN, false, false),
        (System::id(), false, false),
        (pda(&MESSENGER, &[b"__event_authority"]), false, false),
        (MESSENGER, false, false),
    ]
}

pub fn receive_accounts(
    caller: Pubkey,
    payer: Pubkey,
    recipient: Pubkey,
    nonce: &[u8; 32],
    fee_recipient: Pubkey,
) -> Vec<(Pubkey, bool, bool)> {
    let remote_usdc = evm(&[
        0xaf, 0x88, 0xd0, 0x65, 0xe7, 0x7c, 0x8c, 0xc2, 0x23, 0x93, 0x27, 0xc5, 0xed, 0xb3, 0xa4,
        0x32, 0x26, 0x8e, 0x58, 0x31,
    ]);
    vec![
        (payer, true, true),
        (caller, true, false),
        (
            pda(
                &TRANSMITTER,
                &[b"message_transmitter_authority", MESSENGER.as_ref()],
            ),
            false,
            false,
        ),
        (pda(&TRANSMITTER, &[b"message_transmitter"]), false, false),
        (pda(&TRANSMITTER, &[b"used_nonce", nonce]), false, true),
        (MESSENGER, false, false),
        (System::id(), false, false),
        (pda(&TRANSMITTER, &[b"__event_authority"]), false, false),
        (TRANSMITTER, false, false),
        (pda(&MESSENGER, &[b"token_messenger"]), false, false),
        (
            pda(&MESSENGER, &[b"remote_token_messenger", b"3"]),
            false,
            false,
        ),
        (pda(&MESSENGER, &[b"token_minter"]), false, false),
        (
            pda(&MESSENGER, &[b"local_token", USDC.as_ref()]),
            false,
            true,
        ),
        (
            pda(&MESSENGER, &[b"token_pair", b"3", &remote_usdc]),
            false,
            false,
        ),
        (fee_recipient, false, true),
        (recipient, false, true),
        (pda(&MESSENGER, &[b"custody", USDC.as_ref()]), false, true),
        (TOKEN, false, false),
        (pda(&MESSENGER, &[b"__event_authority"]), false, false),
        (MESSENGER, false, false),
    ]
}
