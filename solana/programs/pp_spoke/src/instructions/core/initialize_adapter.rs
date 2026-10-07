use super::{admission, custody, guards::CoreError, initialize_fund::allocate};
use crate::{instructions::{kamino::protocol, raydium::{validation, wire}}, state::{FundState, kamino::KaminoPosition, raydium::{RaydiumLedger, RaydiumPolicy}}};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::instruction::AccountMeta;

/// DEC-190, DEC-193, DEC-195: lazily materialize only creation-time sealed admissions.
#[derive(Accounts)]
pub struct InitializeAdapter<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Account<'info, FundState>,
    /// CHECK: canonical vault authority.
    #[account(seeds = [b"vault", fund.key().as_ref()], bump = fund.vault_bump)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: pinned program and admission checked before allocation.
    pub venue_program: UncheckedAccount<'info>,
    /// CHECK: pool or reserve is validated by its owning adapter.
    pub venue: UncheckedAccount<'info>,
    /// CHECK: canonical strategy position or policy PDA.
    #[account(mut)]
    pub position_or_policy: UncheckedAccount<'info>,
    /// CHECK: canonical collateral ATA or Raydium compatibility ledger.
    #[account(mut)]
    pub collateral_or_ledger: UncheckedAccount<'info>,
    /// CHECK: Kamino collateral mint or Raydium unused placeholder.
    pub collateral_mint: UncheckedAccount<'info>,
    /// CHECK: pinned token executable.
    #[account(address = custody::TOKEN, executable)]
    pub token_program: UncheckedAccount<'info>,
    /// CHECK: pinned associated-token executable.
    #[account(address = custody::ATA, executable)]
    pub ata_program: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<InitializeAdapter>, payload: Vec<u8>) -> Result<()> {
    require!(payload.is_empty() && ctx.remaining_accounts.is_empty(), CoreError::InvalidConfiguration);
    admission::manager(&ctx.accounts.fund, &ctx.accounts.authority.to_account_info())?;
    require!(ctx.accounts.venue_program.executable, CoreError::InvalidConfiguration);
    let fund = ctx.accounts.fund.key();
    let venue = ctx.accounts.venue.key();
    let payer = ctx.accounts.authority.to_account_info();
    let system = ctx.accounts.system_program.to_account_info();
    if ctx.accounts.venue_program.key() == protocol::PROGRAM {
        admission::venue(&ctx.accounts.fund, protocol::PROGRAM, Pubkey::default(), venue)?;
        require_keys_eq!(venue, protocol::RESERVE, CoreError::InvalidConfiguration);
        require_keys_eq!(*ctx.accounts.venue.owner, protocol::PROGRAM, CoreError::InvalidConfiguration);
        require_keys_eq!(ctx.accounts.collateral_mint.key(), protocol::COLLATERAL, CoreError::InvalidCustody);
        let (expected, bump) = Pubkey::find_program_address(&[b"position", fund.as_ref(), venue.as_ref()], &crate::ID);
        require_keys_eq!(ctx.accounts.position_or_policy.key(), expected, CoreError::InvalidConfiguration);
        allocate(&payer, &ctx.accounts.position_or_policy, &system, 8 + KaminoPosition::INIT_SPACE, &[b"position", fund.as_ref(), venue.as_ref(), &[bump]])?;
        let position = KaminoPosition { fund, reserve: venue, enabled: true, units: 0, principal: 0, idle_principal: 0, idle_income: 0, cumulative_realized_income: 0, pending_units: 0, pending_min_liquidity: 0, last_value: 0, last_principal: 0, last_income: 0, last_refresh_slot: 0 };
        position.try_serialize(&mut &mut ctx.accounts.position_or_policy.try_borrow_mut_data()?[..])?;
        let expected_ata = Pubkey::find_program_address(&[ctx.accounts.vault.key().as_ref(), custody::TOKEN.as_ref(), protocol::COLLATERAL.as_ref()], &custody::ATA).0;
        require_keys_eq!(ctx.accounts.collateral_or_ledger.key(), expected_ata, CoreError::InvalidCustody);
        let instruction = anchor_lang::solana_program::instruction::Instruction {
            program_id: custody::ATA,
            accounts: vec![
                AccountMeta::new(payer.key(), true), AccountMeta::new(expected_ata, false),
                AccountMeta::new_readonly(ctx.accounts.vault.key(), false), AccountMeta::new_readonly(protocol::COLLATERAL, false),
                AccountMeta::new_readonly(System::id(), false), AccountMeta::new_readonly(custody::TOKEN, false),
            ], data: vec![1],
        };
        anchor_lang::solana_program::program::invoke(&instruction, &[payer, ctx.accounts.collateral_or_ledger.to_account_info(), ctx.accounts.vault.to_account_info(), ctx.accounts.collateral_mint.to_account_info(), system, ctx.accounts.token_program.to_account_info(), ctx.accounts.ata_program.to_account_info()])?;
        ctx.accounts.fund.register_position(expected)?;
    } else {
        admission::venue(&ctx.accounts.fund, wire::CLMM, venue, Pubkey::default())?;
        require_keys_eq!(ctx.accounts.venue_program.key(), wire::CLMM, CoreError::InvalidConfiguration);
        let pool = validation::pool(&ctx.accounts.venue)?;
        let sealed = ctx.accounts.fund.venues.iter().find(|entry| entry.pool == venue).ok_or(CoreError::InvalidConfiguration)?;
        require!(sealed.token0 == pool.mints[0] && sealed.token1 == pool.mints[1], CoreError::InvalidConfiguration);
        for (prefix, account, space) in [
            (b"raydium_policy".as_slice(), &ctx.accounts.position_or_policy, 8 + RaydiumPolicy::INIT_SPACE),
            (b"raydium_ledger".as_slice(), &ctx.accounts.collateral_or_ledger, 8 + RaydiumLedger::INIT_SPACE),
        ] {
            let (expected, bump) = Pubkey::find_program_address(&[prefix, fund.as_ref(), venue.as_ref()], &crate::ID);
            require_keys_eq!(account.key(), expected, CoreError::InvalidConfiguration);
            allocate(&payer, &account.to_account_info(), &system, space, &[prefix, fund.as_ref(), venue.as_ref(), &[bump]])?;
        }
        RaydiumPolicy { fund, mandate_hash: ctx.accounts.fund.mandate_hash, pool: venue, minimum_tick: -443636, maximum_tick: 443636, enabled: true }
            .try_serialize(&mut &mut ctx.accounts.position_or_policy.try_borrow_mut_data()?[..])?;
        RaydiumLedger { fund, pool: venue, idle_principal_0: 0, idle_principal_1: 0, idle_income_0: 0, idle_income_1: 0 }
            .try_serialize(&mut &mut ctx.accounts.collateral_or_ledger.try_borrow_mut_data()?[..])?;
    }
    Ok(())
}
