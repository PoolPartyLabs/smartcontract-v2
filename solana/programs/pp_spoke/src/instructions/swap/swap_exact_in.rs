use super::guard::SwapError;
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct SwapExactIn<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    pub fund: SystemAccount<'info>,
    #[account(mut)]
    pub vault: SystemAccount<'info>,
    pub swap_program: SystemAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(_ctx: Context<SwapExactIn>, _payload: Vec<u8>) -> Result<()> {
    err!(SwapError::IntegrationPending)
}
