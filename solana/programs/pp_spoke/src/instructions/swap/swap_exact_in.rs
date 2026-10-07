use super::{config::{StageRequest, StagedPolicy}, guard::SwapError};
use anchor_lang::prelude::*;

/// DEC-200, DEC-202: staging only; exact-in execution remains unavailable.
#[derive(Accounts)]
pub struct SwapExactIn<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    /// CHECK: planned Fund PDA; authenticated initialization consumes the staged consent.
    pub fund: UncheckedAccount<'info>,
    /// CHECK: owning track must enforce the per-Fund vault PDA; handler always fails meanwhile.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: DEC-197 selects Jupiter for swap-to-ratio; this exact-in handler remains fail-closed.
    pub swap_program: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler<'info>(ctx: Context<'_, '_, '_, 'info, SwapExactIn<'info>>, payload: Vec<u8>) -> Result<()> {
    require!(payload.len() <= 512 && ctx.remaining_accounts.len() == 1, SwapError::Route);
    let args = StageRequest::try_from_slice(&payload).map_err(|_| error!(SwapError::Route))?;
    args.creation.policy.validate()?;
    let stage = &ctx.remaining_accounts[0];
    require!(stage.is_signer && stage.is_writable && stage.owner == &System::id() && stage.data_is_empty(), SwapError::Custody);
    let space = 8 + StagedPolicy::INIT_SPACE;
    anchor_lang::solana_program::program::invoke(&anchor_lang::solana_program::system_instruction::create_account(
        &ctx.accounts.authority.key(), stage.key, Rent::get()?.minimum_balance(space), space as u64, &crate::ID),
        &[ctx.accounts.authority.to_account_info(), stage.clone(), ctx.accounts.system_program.to_account_info()])?;
    StagedPolicy { fund: ctx.accounts.fund.key(), manager_solana: ctx.accounts.authority.key(),
        binding_digest: args.binding_digest, creation: args.creation }.try_serialize(&mut &mut stage.try_borrow_mut_data()?[..])
}
