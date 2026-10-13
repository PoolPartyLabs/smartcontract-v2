use super::{
    cpi,
    wire::{discriminator, TRANSMITTER},
    CctpError,
};
use crate::state::transit::Transit;
use anchor_lang::prelude::*;
use anchor_lang::solana_program::instruction::{AccountMeta, Instruction};

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct ReclaimParams {
    pub attestation: Vec<u8>,
    pub destination_message: Vec<u8>,
}

/// DEC-195: payer calls Circle directly after its five-day window; claim stays pending.
pub fn reclaim_event_account(transit: &Transit, params: ReclaimParams) -> Result<Instruction> {
    require!(
        transit.outbound
            && transit.event_account != Pubkey::default()
            && transit.rent_payer != Pubkey::default(),
        CctpError::InvalidAccount
    );
    let mut data = discriminator("reclaim_event_account").to_vec();
    params.serialize(&mut data)?;
    Ok(Instruction {
        program_id: TRANSMITTER,
        accounts: vec![
            AccountMeta::new(transit.rent_payer, true),
            AccountMeta::new(cpi::pda(&TRANSMITTER, &[b"message_transmitter"]), false),
            AccountMeta::new(transit.event_account, false),
        ],
        data,
    })
}
