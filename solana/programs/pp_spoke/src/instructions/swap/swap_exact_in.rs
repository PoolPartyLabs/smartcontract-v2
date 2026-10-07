use crate::errors::SpokeError;
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-193, DEC-197: exact-in remains scaffolded; no CPI or state mutation is authorized.
#[derive(Accounts)]
pub struct SwapExactIn<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Account<'info, FundState>,
    /// CHECK: owning track must enforce the per-Fund vault PDA; handler always fails meanwhile.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: DEC-197 selects Jupiter for swap-to-ratio; this exact-in handler remains fail-closed.
    pub swap_program: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(_ctx: Context<SwapExactIn>, _payload: Vec<u8>) -> Result<()> {
    err!(SpokeError::NotImplemented)
}
