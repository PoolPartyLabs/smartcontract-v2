use super::snapshot::ReportError;
use crate::instructions::core::custody::WORMHOLE;
use anchor_lang::prelude::*;
use anchor_lang::solana_program::instruction::{AccountMeta, Instruction};

/// DEC-192: source-pinned Wormhole PostMessage Borsh enum, Finalized is 1, VAA byte is 32.
pub fn post_message(
    payer: Pubkey,
    emitter: Pubkey,
    message: Pubkey,
    payload: Vec<u8>,
) -> Result<Instruction> {
    require!(payload.len() <= 48_000, ReportError::ReportTooLarge);
    let bridge = Pubkey::find_program_address(&[b"Bridge"], &WORMHOLE).0;
    let sequence = Pubkey::find_program_address(&[b"Sequence", emitter.as_ref()], &WORMHOLE).0;
    let collector = Pubkey::find_program_address(&[b"fee_collector"], &WORMHOLE).0;
    let mut data = vec![1];
    data.extend_from_slice(&0u32.to_le_bytes());
    data.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    data.extend(payload);
    data.push(1);
    Ok(Instruction {
        program_id: WORMHOLE,
        accounts: vec![
            AccountMeta::new(bridge, false),
            AccountMeta::new(message, true),
            AccountMeta::new_readonly(emitter, true),
            AccountMeta::new(sequence, false),
            AccountMeta::new(payer, true),
            AccountMeta::new(collector, false),
            AccountMeta::new_readonly(anchor_lang::solana_program::sysvar::clock::ID, false),
            AccountMeta::new_readonly(anchor_lang::solana_program::sysvar::rent::ID, false),
            AccountMeta::new_readonly(System::id(), false),
        ],
        data,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pinned_post_message_wire_and_account_privileges() {
        let payer = Pubkey::new_unique();
        let emitter = Pubkey::new_unique();
        let message = Pubkey::new_unique();
        let instruction = post_message(payer, emitter, message, vec![6, 7]).unwrap();
        assert_eq!(instruction.data, vec![1, 0, 0, 0, 0, 2, 0, 0, 0, 6, 7, 1]);
        assert_eq!(instruction.accounts.len(), 9);
        assert!(instruction.accounts[1].is_signer && instruction.accounts[1].is_writable);
        assert!(instruction.accounts[2].is_signer && !instruction.accounts[2].is_writable);
        assert!(instruction.accounts[4].is_signer && instruction.accounts[4].is_writable);
    }
}
