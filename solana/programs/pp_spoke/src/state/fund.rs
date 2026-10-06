use anchor_lang::prelude::*;

/// DEC-188, DEC-190: per-Fund identity; layout is provisional until T1 implements initialization.
#[account]
#[derive(InitSpace)]
pub struct FundState {
    pub hub_core: [u8; 20],
    pub spoke_index: u16,
    pub fund_id: [u8; 32],
    pub mandate_hash: [u8; 32],
    pub manager_evm: [u8; 20],
    pub manager_solana: Pubkey,
    pub report_sequence: u64,
    pub order_sequence: u64,
    pub closed: bool,
    pub bump: u8,
    pub vault_bump: u8,
}
