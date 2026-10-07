use super::{config::{StageRequest, StagedPolicy}, guard::SwapError};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct StageSwapPolicy<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    pub fund: SystemAccount<'info>,
    /// CHECK: canonical stage PDA, owner, signer binding and write-once state checked by handler.
    #[account(mut)]
    pub stage: AccountInfo<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<StageSwapPolicy>, payload: Vec<u8>) -> Result<()> {
    require!(ctx.remaining_accounts.is_empty() && payload.len() <= 650, SwapError::Route);
    let args = StageRequest::try_from_slice(&payload).map_err(|_| error!(SwapError::Route))?;
    require!(args.policy_hash != [0;32] && args.total_len > 0 && args.total_len <= 4096, SwapError::Route);
    require!(ctx.accounts.fund.owner == &System::id() && ctx.accounts.fund.data_is_empty(), SwapError::Custody);
    let fund = ctx.accounts.fund.key();
    let manager = ctx.accounts.authority.key();
    let (expected, bump) = Pubkey::find_program_address(&[b"swap_policy_stage", fund.as_ref(), manager.as_ref()], &crate::ID);
    require_keys_eq!(ctx.accounts.stage.key(), expected, SwapError::Custody);
    let stage = ctx.accounts.stage.to_account_info();
    let mut state = if stage.owner == &System::id() && stage.data_is_empty() {
        require!(args.offset == 0, SwapError::Route);
        crate::instructions::core::initialize_fund::allocate(&ctx.accounts.authority.to_account_info(), &stage,
            &ctx.accounts.system_program.to_account_info(), 8 + StagedPolicy::INIT_SPACE,
            &[b"swap_policy_stage", fund.as_ref(), manager.as_ref(), &[bump]])?;
        StagedPolicy { fund, manager_solana: manager, policy_hash: args.policy_hash,
            total_len: args.total_len, sealed: false, payload: vec![] }
    } else {
        require!(*stage.owner == crate::ID, SwapError::Custody);
        let state = StagedPolicy::try_deserialize(&mut &stage.try_borrow_data()?[..])?;
        require!(state.fund == fund && state.manager_solana == manager, SwapError::Custody);
        state
    };
    state.append(args)?;
    state.try_serialize(&mut &mut stage.try_borrow_mut_data()?[..])?;
    Ok(())
}
