use super::snapshot::ReportError;
use crate::{
    instructions::core::{binding::word, custody::WORMHOLE, guards::require_fund_address},
    state::FundState,
};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::keccak;

/// DEC-111, DEC-120: accept only guardian-verified PostedVAA, never a locally posted msg/msu.
pub fn verify_order(
    fund: &FundState,
    fund_key: Pubkey,
    posted: &AccountInfo,
    kind: Option<u8>,
    now: i64,
) -> Result<()> {
    require_fund_address(fund, &fund_key)?;
    require_keys_eq!(*posted.owner, WORMHOLE, ReportError::InvalidOrder);
    let data = posted.try_borrow_data()?;
    require!(
        data.len() >= 95 && &data[..3] == b"vaa" && data[3] == 1 && data[4] == 200,
        ReportError::InvalidOrder
    );
    let timestamp = u32::from_le_bytes(data[5..9].try_into().unwrap());
    let nonce = u32::from_le_bytes(data[45..49].try_into().unwrap());
    let sequence = u64::from_le_bytes(data[49..57].try_into().unwrap());
    let chain = u16::from_le_bytes(data[57..59].try_into().unwrap());
    require!(
        chain == fund.hub_emitter_chain
            && data[59..91] == fund.hub_emitter
            && sequence > fund.order_sequence,
        ReportError::InvalidOrder
    );
    let length = u32::from_le_bytes(data[91..95].try_into().unwrap()) as usize;
    require!(
        length == 320 && data.len() == 95 + length,
        ReportError::InvalidOrder
    );
    let payload = &data[95..];
    let mut body = timestamp.to_be_bytes().to_vec();
    body.extend(nonce.to_be_bytes());
    body.extend(chain.to_be_bytes());
    body.extend(fund.hub_emitter);
    body.extend(sequence.to_be_bytes());
    body.push(200);
    body.extend(payload);
    let hash = keccak::hash(&body).to_bytes();
    let expected = Pubkey::find_program_address(&[b"PostedVAA", &hash], &WORMHOLE).0;
    require_keys_eq!(*posted.key, expected, ReportError::InvalidOrder);
    require!(
        payload[..32] == word(1) && payload[64..96] == fund.fund_id,
        ReportError::InvalidOrder
    );
    require!(payload[32..63] == [0; 31], ReportError::InvalidOrder);
    let actual_kind = payload[63];
    require!(
        (1..=4).contains(&actual_kind) && kind.is_none_or(|required| actual_kind == required),
        ReportError::InvalidOrder
    );
    require!(
        payload[128..152] == [0; 24]
            && payload[160..184] == [0; 24]
            && payload[288..319] == [0; 31]
            && payload[319] <= 1,
        ReportError::InvalidOrder
    );
    let deadline = u64::from_be_bytes(payload[184..192].try_into().unwrap());
    require!(
        now >= i64::from(timestamp) && now >= 0 && now as u64 <= deadline,
        ReportError::InvalidOrder
    );
    if actual_kind == 1 {
        require!(
            payload[224..256] != word(0) && payload[192..224] <= payload[224..256],
            ReportError::InvalidOrder
        );
    }
    if actual_kind == 2 {
        require!(
            payload[192..224] == word(1) && payload[224..256] == word(1),
            ReportError::InvalidOrder
        );
    }
    Ok(())
}

pub fn dispatch_unavailable() -> Result<()> {
    // TODO(interface): DEC-120/121/122/191 require resumable T3/T4/T1b execution and ACK reconciliation.
    err!(ReportError::OrderExecutionNotIntegrated)
}
