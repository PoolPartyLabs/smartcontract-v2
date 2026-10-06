#![allow(unexpected_cfgs)]
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{entrypoint, entrypoint::ProgramResult};
#[path = "../../../../programs/pp_spoke/src/instructions/swap/guard.rs"]
mod guard;
use guard::{execute_guarded, SealedPolicy, SwapRequest, SwapError};

pub const ID: Pubkey = Pubkey::new_from_array([77; 32]);

entrypoint!(process_instruction);

fn process_instruction(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    let request = SwapRequest::try_from_slice(data).map_err(|_| anchor_lang::error::Error::from(SwapError::Route))?;
    let manager = &accounts[0];
    let fund = &accounts[1];
    let vault = &accounts[2];
    let jupiter = &accounts[3];
    if !manager.is_signer { return Err(anchor_lang::error::Error::from(SwapError::Unauthorized).into()); }
    let (expected, bump) = Pubkey::find_program_address(&[b"vault", fund.key.as_ref()], program_id);
    if *vault.key != expected { return Err(anchor_lang::error::Error::from(SwapError::Custody).into()); }
    let mints = [
        pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"),
        pubkey!("XsDoVfqeBukxuZHWhdvWHBhgEHjGNst4MLodqsJHzoB"),
        pubkey!("Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh"),
        pubkey!("So11111111111111111111111111111111111111112"),
    ];
    let conversion = execute_guarded(jupiter, vault, &accounts[4..],
        &[b"vault", fund.key.as_ref(), &[bump]], &request,
        &SealedPolicy { mints: &mints, max_slippage_bps: 200 })?;
    msg!("TEST PROBE internal conversion: {} -> {}", conversion.input_units, conversion.output_units);
    Ok(())
}
