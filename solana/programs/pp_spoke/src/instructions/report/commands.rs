use super::{orders::verify_order, snapshot::ReportError};
use crate::{instructions::core::{binding::word, custody, initialize_fund::allocate}, state::{FundState, TokenLedger, command::HubCommand}};
use anchor_lang::prelude::*;

pub fn read_u64(encoded: &[u8]) -> Result<u64> {
    require!(encoded.len() == 32 && encoded[..24] == [0;24], ReportError::InvalidOrder);
    Ok(u64::from_be_bytes(encoded[24..].try_into().unwrap()))
}

/// DEC-137: full-width Hub fractions; reject overflow rather than truncate a sizing term.
pub fn fraction(amount: u64, numerator: &[u8], denominator: &[u8]) -> Result<u64> {
    let numerator = read_u64(numerator)?;
    let denominator = read_u64(denominator)?;
    require!(denominator != 0 && numerator <= denominator, ReportError::InvalidOrder);
    Ok((u128::from(amount) * u128::from(numerator) / u128::from(denominator)) as u64)
}

/// DEC-120/122/151: authenticated receipt is acceptance, never a fabricated completed execution.
pub fn accept<'info>(fund: &mut Account<'info, FundState>, payer: &AccountInfo<'info>,
    posted: &AccountInfo<'info>, system: &AccountInfo<'info>, accounts: &[AccountInfo<'info>], kind: u8) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    verify_order(fund, fund.key(), posted, Some(kind), now)?;
    require!(!fund.closed && (!fund.close_requested || kind == 2)
        && fund.active_command == Pubkey::default() && fund.command_registry.len() < 8,
        ReportError::OrderExecutionNotIntegrated);
    require!(accounts.len() == 2, ReportError::InvalidAccounts);
    let data = posted.try_borrow_data()?;
    let payload = &data[95..];
    if kind == 2 {
        let started = read_u64(&payload[320..352])?;
        require!(started != 0 && started <= now as u64, ReportError::InvalidOrder);
    }
    let id = anchor_lang::solana_program::keccak::hash(&[
        word(u128::from(kind)).as_slice(), &payload[64..96], &payload[96..128], &payload[128..160]
    ].concat()).to_bytes();
    let (key, bump) = Pubkey::find_program_address(&[b"command", fund.key().as_ref(), &id], &crate::ID);
    require_keys_eq!(*accounts[0].key, key, ReportError::InvalidAccounts);
    let ledger_key = Pubkey::find_program_address(&[b"ledger", fund.key().as_ref(), custody::USDC.as_ref()], &crate::ID).0;
    require_keys_eq!(*accounts[1].key, ledger_key, ReportError::InvalidAccounts);
    require_keys_eq!(*accounts[1].owner, crate::ID, ReportError::InvalidAccounts);
    let ledger = TokenLedger::try_deserialize(&mut &accounts[1].try_borrow_data()?[..])?;
    require!(ledger.fund == fund.key() && ledger.mint == custody::USDC, ReportError::InvalidAccounts);
    let reserved = if kind == 3 { ledger.collected_income } else { fraction(ledger.principal, &payload[192..224], &payload[224..256])? };
    let fund_key = fund.key();
    allocate(payer, &accounts[0], system, 8 + HubCommand::INIT_SPACE, &[b"command", fund_key.as_ref(), &id, &[bump]])?;
    if kind == 3 { read_u64(&payload[96..128])?; }
    let command = HubCommand { fund: fund_key, order_id: id, request_id: payload[96..128].try_into().unwrap(), kind,
        attempt: u32::from_be_bytes(payload[156..160].try_into().unwrap()),
        sequence: u64::from_le_bytes(data[49..57].try_into().unwrap()), reserved, amount_sent: 0, amount_to_arrive: 0,
        transit_id: [0;32], delivered: 0, excluded: 0, completed: false, rent_payer: *payer.key,
        payload: payload.try_into().unwrap(), delivered_steps: vec![] };
    command.try_serialize(&mut &mut accounts[0].try_borrow_mut_data()?[..])?;
    fund.order_sequence = command.sequence;
    fund.active_command = key;
    fund.close_requested |= kind == 2;
    fund.command_registry.push(key);
    emit!(HubCommandAccepted { fund: fund_key, order_id: id, kind, reserved });
    Ok(())
}

#[event]
pub struct HubCommandAccepted { pub fund: Pubkey, pub order_id: [u8;32], pub kind: u8, pub reserved: u64 }

pub fn unwind_result(command: &HubCommand) -> Vec<u8> {
    [word(32), word(1), command.order_id, command.request_id, word(u128::from(command.attempt)), command.transit_id,
        word(u128::from(command.amount_sent)), word(u128::from(command.amount_to_arrive)), word(0), word(0), word(0),
        word(u128::from(command.delivered)), word(u128::from(command.excluded)), word(0), word(0)].concat()
}

pub fn collection_result(command: &HubCommand) -> Vec<u8> {
    let count = u128::from(command.amount_sent != 0);
    let array_bytes = 32 + count * 32;
    let mut encoded = [word(32), word(1), word(32), word(u128::from(command.sequence)),
        command.request_id, command.transit_id, word(u128::from(command.amount_sent)), word(256),
        word(256 + array_bytes), word(256 + array_bytes * 2), word(u128::from(command.amount_to_arrive)), word(count)].concat();
    if count != 0 { encoded.extend(custody::USDC.to_bytes()); }
    encoded.extend(word(count));
    if count != 0 { encoded.extend(word(u128::from(command.amount_sent))); }
    encoded.extend(word(count));
    if count != 0 { encoded.extend(word(u128::from(command.amount_sent))); }
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fractions_round_down_and_never_truncate_hub_words() {
        assert_eq!(fraction(11, &word(1), &word(2)).unwrap(), 5);
        assert!(fraction(11, &word(1), &word(0)).is_err());
        assert!(fraction(11, &word(3), &word(2)).is_err());
        assert!(fraction(11, &word(u128::MAX), &word(u128::MAX)).is_err());
    }
}
