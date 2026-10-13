use anchor_lang::prelude::*;

/// DEC-120/122/151: retain execution evidence and reserved custody across retries.
#[account]
#[derive(InitSpace)]
pub struct HubCommand {
    pub fund: Pubkey,
    pub order_id: [u8; 32],
    pub request_id: [u8; 32],
    pub kind: u8,
    pub attempt: u32,
    pub sequence: u64,
    pub reserved: u64,
    pub amount_sent: u64,
    pub amount_to_arrive: u64,
    pub transit_id: [u8; 32],
    pub delivered: u64,
    pub excluded: u64,
    pub completed: bool,
    pub rent_payer: Pubkey,
    pub payload: [u8; 352],
    #[max_len(32)]
    pub delivered_steps: Vec<Pubkey>,
}
