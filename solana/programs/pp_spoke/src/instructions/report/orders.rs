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
        length == 352 && data.len() == 95 + length,
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
        payload[128..156] == [0; 28]
            && payload[160..184] == [0; 24]
            && payload[288..319] == [0; 31]
            && payload[319] <= 1
            && payload[256..286] == [0; 30]
            && payload[320..344] == [0; 24],
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

/// DEC-191: only the sealed Hub's confirmed-arrival ACK retires a perpetual claim.
pub fn execute_acknowledgement(fund: &mut Account<FundState>, posted: &AccountInfo, accounts: &[AccountInfo]) -> Result<()> {
    let data = posted.try_borrow_data()?;
    let payload = &data[95..];
    require!(payload[63] == 4, ReportError::OrderExecutionNotIntegrated);
    let sequence = u64::from_le_bytes(data[49..57].try_into().unwrap());
    if payload[192..224] != word(u128::from(fund.spoke_chain_id)) {
        fund.order_sequence = sequence;
        return Ok(());
    }
    require!(payload[224..256] == word(2) && accounts.len() == 2, ReportError::InvalidOrder);
    let id: [u8;32] = payload[96..128].try_into().unwrap();
    require_keys_eq!(*accounts[0].owner, crate::ID, ReportError::InvalidOrder);
    require!(accounts[0].is_writable && accounts[1].is_writable, ReportError::InvalidOrder);
    let mut transit = crate::state::transit::Transit::try_deserialize(&mut &accounts[0].try_borrow_data()?[..])?;
    require!(transit.fund == fund.key() && transit.outbound && transit.transit_id == id, ReportError::InvalidOrder);
    let key = Pubkey::find_program_address(&[b"transit_out", fund.key().as_ref(), &transit.nonce], &crate::ID).0;
    require_keys_eq!(*accounts[0].key, key, ReportError::InvalidOrder);
    require!(id == crate::instructions::cctp::wire::outbound_id(&fund.fund_id, &transit.nonce)?, ReportError::InvalidOrder);
    let ledger_key = Pubkey::find_program_address(&[b"cctp_ledger", fund.key().as_ref()], &crate::ID).0;
    require_keys_eq!(*accounts[1].key, ledger_key, ReportError::InvalidOrder);
    require_keys_eq!(*accounts[1].owner, crate::ID, ReportError::InvalidOrder);
    let mut ledger = crate::state::transit::CctpLedger::try_deserialize(&mut &accounts[1].try_borrow_data()?[..])?;
    require_keys_eq!(ledger.fund, fund.key(), ReportError::InvalidOrder);
    if !transit.received {
        let index = fund.transit_registry.iter().position(|entry| *entry == key).ok_or(ReportError::InvalidOrder)?;
        ledger.outbound_in_flight = ledger.outbound_in_flight.checked_sub(transit.in_flight).ok_or(ReportError::InvalidOrder)?;
        fund.transit_registry.remove(index);
        fund.pending_transits = fund.transit_registry.len() as u16;
        transit.received = true;
        transit.try_serialize(&mut &mut accounts[0].try_borrow_mut_data()?[..])?;
        ledger.try_serialize(&mut &mut accounts[1].try_borrow_mut_data()?[..])?;
    }
    fund.order_sequence = sequence;
    emit!(HubArrivalAcknowledged { fund: fund.key(), transit_id: id, sequence });
    Ok(())
}

#[event]
pub struct HubArrivalAcknowledged {
    pub fund: Pubkey,
    pub transit_id: [u8;32],
    pub sequence: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn posted(fund: &FundState) -> (Pubkey, Vec<u8>) {
        let payload = [
            word(1),
            word(1),
            fund.fund_id,
            word(9),
            word(1),
            word(1100),
            word(1),
            word(2),
            word(100),
            word(0),
            word(0),
        ]
        .concat();
        let mut body = 1000u32.to_be_bytes().to_vec();
        body.extend(0u32.to_be_bytes());
        body.extend(fund.hub_emitter_chain.to_be_bytes());
        body.extend(fund.hub_emitter);
        body.extend(1u64.to_be_bytes());
        body.push(200);
        body.extend(&payload);
        let key = Pubkey::find_program_address(
            &[b"PostedVAA", &keccak::hash(&body).to_bytes()],
            &WORMHOLE,
        )
        .0;
        let mut data = b"vaa".to_vec();
        data.extend([1, 200]);
        data.extend(1000u32.to_le_bytes());
        data.extend([1; 32]);
        data.extend(1001u32.to_le_bytes());
        data.extend(0u32.to_le_bytes());
        data.extend(1u64.to_le_bytes());
        data.extend(fund.hub_emitter_chain.to_le_bytes());
        data.extend(fund.hub_emitter);
        data.extend((payload.len() as u32).to_le_bytes());
        data.extend(payload);
        (key, data)
    }

    #[test]
    fn authenticate_posted_vaa_identity_fund_kind_deadline_and_replay() {
        let (mut fund, fund_key) = crate::instructions::core::guards::fixture();
        let (key, mut data) = posted(&fund);
        let mut lamports = 1;
        let account = AccountInfo::new(
            &key,
            false,
            false,
            &mut lamports,
            &mut data,
            &WORMHOLE,
            false,
            0,
        );
        verify_order(&fund, fund_key, &account, Some(1), 1100).unwrap();
        assert!(verify_order(&fund, fund_key, &account, Some(2), 1001).is_err());
        assert!(verify_order(&fund, fund_key, &account, None, 1101).is_err());
        fund.order_sequence = 1;
        assert!(verify_order(&fund, fund_key, &account, None, 1001).is_err());
        fund.order_sequence = 0;
        fund.fund_id[0] ^= 1;
        assert!(verify_order(&fund, fund_key, &account, None, 1001).is_err());
    }

    #[test]
    fn reject_local_messages_wrong_owner_emitter_address_and_noncanonical_order() {
        let (fund, fund_key) = crate::instructions::core::guards::fixture();
        for variant in 0..6 {
            let (mut key, mut data) = posted(&fund);
            let mut owner = WORMHOLE;
            match variant {
                0 => data[..3].copy_from_slice(b"msg"),
                1 => owner = crate::ID,
                2 => data[59] ^= 1,
                3 => key = Pubkey::new_unique(),
                4 => data[4] = 32,
                _ => {
                    data[91..95].copy_from_slice(&320u32.to_le_bytes());
                    data.truncate(415);
                }
            }
            let mut lamports = 1;
            let account = AccountInfo::new(
                &key,
                false,
                false,
                &mut lamports,
                &mut data,
                &owner,
                false,
                0,
            );
            assert!(verify_order(&fund, fund_key, &account, None, 1001).is_err());
        }
    }
}
