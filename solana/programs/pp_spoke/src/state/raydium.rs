use anchor_lang::prelude::*;

/// DEC-190, DEC-193, DEC-194: T1 creates this immutable admission at Fund creation.
/// TODO(decision): coordinator must authenticate its contents against the Hub Mandate.
#[account]
#[derive(InitSpace)]
pub struct RaydiumPolicy {
    pub fund: Pubkey,
    pub mandate_hash: [u8; 32],
    pub pool: Pubkey,
    pub minimum_tick: i32,
    pub maximum_tick: i32,
    pub enabled: bool,
}

/// DEC-193, DEC-195: fees are separate from principal; rent belongs to the payer.
#[account]
#[derive(InitSpace)]
pub struct RaydiumPosition {
    pub fund: Pubkey,
    pub pool: Pubkey,
    pub personal_position: Pubkey,
    pub nft_mint: Pubkey,
    pub rent_payer: Pubkey,
    pub tick_lower: i32,
    pub tick_upper: i32,
    pub liquidity: u128,
    pub collected_fees_0: u64,
    pub collected_fees_1: u64,
    pub closed: bool,
    pub bump: u8,
}

/// DEC-079, DEC-193: authenticated allocations, never raw balances, fund entries.
/// TODO(decision): T1 must credit/debit this ledger atomically across all adapters.
#[account]
#[derive(InitSpace)]
pub struct RaydiumLedger {
    pub fund: Pubkey,
    pub pool: Pubkey,
    pub idle_principal_0: u64,
    pub idle_principal_1: u64,
    pub idle_income_0: u64,
    pub idle_income_1: u64,
}
