use anchor_lang::prelude::*;

/// DEC-188, DEC-190, DEC-191: created and sealed only by verified Fund initialization.
#[account]
#[derive(InitSpace)]
pub struct CctpRoute {
    pub fund: Pubkey,
    pub mandate_hash: [u8; 32],
    pub hub_connector: [u8; 20],
    pub solana_chain_id: u64,
    /// TODO(decision): numeric immutable ceiling; no production default (DEC-191).
    pub max_fee_bps_scaled: u64,
    pub sealed: bool,
}

/// DEC-191: isolated accounting interface for T1; never infer principal from donations.
#[account]
#[derive(InitSpace)]
pub struct CctpLedger {
    pub fund: Pubkey,
    pub principal: u64,
    pub outbound_gross: u64,
    pub outbound_in_flight: u64,
    pub received_principal: u64,
    pub fee_surplus_principal: u64,
}

/// DEC-191, DEC-195: persistent business-id receipt/claim and original rent payer.
#[account]
#[derive(InitSpace)]
pub struct Transit {
    pub fund: Pubkey,
    pub transit_id: [u8; 32],
    pub outbound: bool,
    pub amount: u64,
    pub max_fee: u64,
    pub in_flight: u64,
    pub credited: u64,
    pub fee_executed: u64,
    pub fee_surplus_principal: u64,
    pub nonce: [u8; 32],
    pub message_hash: [u8; 32],
    pub event_account: Pubkey,
    pub rent_payer: Pubkey,
    pub received: bool,
    pub transfer_kind: u8,
}
