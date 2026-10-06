use anchor_lang::prelude::*;

/// DEC-068, DEC-080, DEC-193: only credited principal and recorded cTokens are Share Assets.
/// T1 creates this PDA and credits it atomically with authenticated USDC arrivals.
/// TODO(decision): coordinate the final shared ledger interface; no public credit setter exists.
#[account]
#[derive(InitSpace)]
pub struct KaminoPosition {
    pub fund: Pubkey,
    pub reserve: Pubkey,
    pub enabled: bool,
    pub units: u64,
    pub principal: u64,
    pub idle_principal: u64,
    pub idle_income: u64,
    pub cumulative_realized_income: u64,
    pub pending_units: u64,
    pub pending_min_liquidity: u64,
    pub last_value: u64,
    pub last_principal: u64,
    pub last_income: u64,
    pub last_refresh_slot: u64,
}
