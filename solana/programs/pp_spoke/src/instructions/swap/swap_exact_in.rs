use super::guard::SwapError;
use crate::state::FundState;
use anchor_lang::prelude::*;

/// CR-33: typed Fund so the disabled entry fails closed with IntegrationPending, not AccountNotSystemOwned.
#[derive(Accounts)]
pub struct SwapExactIn<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    pub fund: Box<Account<'info, FundState>>,
    /// CHECK: unused until the signed exact-in liquidation (LIFECYCLE opcode 4) is integrated.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: unused until the signed exact-in liquidation (LIFECYCLE opcode 4) is integrated.
    pub swap_program: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(_ctx: Context<SwapExactIn>, _payload: Vec<u8>) -> Result<()> {
    err!(SwapError::IntegrationPending)
}
