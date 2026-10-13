use super::guards::CoreError;
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    instruction::{AccountMeta, Instruction},
    program::invoke,
};

pub const USDC: Pubkey = pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
pub const TSLAX: Pubkey = pubkey!("XsDoVfqeBukxuZHWhdvWHBhgEHjGNst4MLodqsJHzoB");
pub const NVDAX: Pubkey = pubkey!("Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh");
pub const WSOL: Pubkey = pubkey!("So11111111111111111111111111111111111111112");
pub const TOKEN: Pubkey = pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
pub const TOKEN_2022: Pubkey = pubkey!("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");
pub const ATA: Pubkey = pubkey!("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
pub const WORMHOLE: Pubkey = pubkey!("worm2ZoG2kUd4vFXhvjh93UUH596ayRfgQ2MgjNMTth");
pub const CCTP_TRANSMITTER: Pubkey = pubkey!("CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC");
pub const CCTP_MESSENGER: Pubkey = pubkey!("CCTPV2vPZJS2u2BBsUoscuikbYjnpFmbFsvVuJdgUMQe");

pub fn token_program(mint: &Pubkey) -> Result<Pubkey> {
    match *mint {
        USDC | WSOL => Ok(TOKEN),
        TSLAX | NVDAX => Ok(TOKEN_2022),
        _ => err!(CoreError::InvalidConfiguration),
    }
}

pub fn associated_address(vault: &Pubkey, mint: &Pubkey) -> Result<Pubkey> {
    Ok(Pubkey::find_program_address(
        &[vault.as_ref(), token_program(mint)?.as_ref(), mint.as_ref()],
        &ATA,
    )
    .0)
}

pub fn recorded_custody_balance(
    account: &AccountInfo,
    vault: &Pubkey,
    mint: &Pubkey,
) -> Result<u64> {
    require_keys_eq!(
        *account.key,
        associated_address(vault, mint)?,
        CoreError::InvalidCustody
    );
    require_keys_eq!(
        *account.owner,
        token_program(mint)?,
        CoreError::InvalidCustody
    );
    let data = account.try_borrow_data()?;
    require!(data.len() >= 165, CoreError::InvalidCustody);
    require!(
        data[..32] == mint.to_bytes() && data[32..64] == vault.to_bytes(),
        CoreError::InvalidCustody
    );
    require!(data[108] == 1, CoreError::InvalidCustody);
    require!(
        data[72..76] == [0; 4] && data[129..133] == [0; 4],
        CoreError::InvalidCustody
    );
    Ok(u64::from_le_bytes(data[64..72].try_into().unwrap()))
}

/// DEC-194, DEC-195: correct Token-2022 ATA seeds; Manager pays rent, vault pays nothing.
pub fn create_ata<'info>(
    payer: AccountInfo<'info>,
    account: AccountInfo<'info>,
    vault: AccountInfo<'info>,
    mint: AccountInfo<'info>,
    system: AccountInfo<'info>,
    token: AccountInfo<'info>,
    ata: AccountInfo<'info>,
) -> Result<()> {
    require_keys_eq!(
        *account.key,
        associated_address(vault.key, mint.key)?,
        CoreError::InvalidCustody
    );
    require_keys_eq!(
        *token.key,
        token_program(mint.key)?,
        CoreError::InvalidCustody
    );
    require_keys_eq!(*mint.owner, *token.key, CoreError::InvalidCustody);
    require_keys_eq!(*ata.key, ATA, CoreError::InvalidCustody);
    require!(
        token.executable && ata.executable,
        CoreError::InvalidCustody
    );
    let instruction = Instruction {
        program_id: ATA,
        accounts: vec![
            AccountMeta::new(*payer.key, true),
            AccountMeta::new(*account.key, false),
            AccountMeta::new_readonly(*vault.key, false),
            AccountMeta::new_readonly(*mint.key, false),
            AccountMeta::new_readonly(*system.key, false),
            AccountMeta::new_readonly(*token.key, false),
        ],
        data: vec![1],
    };
    invoke(
        &instruction,
        &[payer, account, vault, mint, system, token, ata],
    )?;
    Ok(())
}
