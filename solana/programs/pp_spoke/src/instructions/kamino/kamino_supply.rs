use super::{accounts::*, protocol::*, valuation::checkpoint, KaminoError};
use crate::state::{fund::FundState, kamino::KaminoPosition};
use anchor_lang::prelude::*;
use crate::instructions::core::admission;

/// DEC-190, DEC-193, DEC-195: Manager signs; only the vault PDA controls Fund tokens.
#[derive(Accounts)]
pub struct KaminoSupply<'info> {
    pub authority: Signer<'info>,
    #[account(mut, seeds = [b"fund", &fund.hub_chain_id.to_le_bytes(), fund.hub_core.as_ref(), &fund.spoke_index.to_le_bytes(), fund.policy_hash.as_ref()], bump = fund.bump,
        constraint = fund.manager_solana == authority.key() @ KaminoError::Unauthorized,
        constraint = !fund.closed @ KaminoError::EntryDisabled)]
    pub fund: Box<Account<'info, FundState>>,
    /// CHECK: canonical per-Fund vault signer, never the Manager wallet.
    #[account(seeds = [b"vault", fund.key().as_ref()], bump = fund.vault_bump)]
    pub vault: UncheckedAccount<'info>,
    #[account(mut, seeds = [b"position", fund.key().as_ref(), RESERVE.as_ref()], bump,
        has_one = fund, constraint = position.reserve == RESERVE @ KaminoError::WrongReserve,
        constraint = position.enabled @ KaminoError::EntryDisabled)]
    pub position: Account<'info, KaminoPosition>,
    pub venue: KaminoVenue<'info>,
    #[account(mut, seeds = [b"ledger", fund.key().as_ref(), USDC.as_ref()], bump = token_ledger.bump, has_one = fund,
        constraint = token_ledger.mint == USDC @ KaminoError::InvalidTokenAccount)]
    pub token_ledger: Box<Account<'info, crate::state::TokenLedger>>,
}

/// Payload: exact u64 little-endian USDC units. No amount is inferred from wallet balances (DEC-080).
pub fn handler(ctx: Context<KaminoSupply>, payload: Vec<u8>) -> Result<()> {
    admission::manager(&ctx.accounts.fund, &ctx.accounts.authority.to_account_info())?;
    admission::venue(&ctx.accounts.fund, PROGRAM, Pubkey::default(), RESERVE)?;
    require!(payload.len() == 8, KaminoError::InvalidAmount);
    let amount = read_u64(&payload, 0)?;
    require!(amount > 0, KaminoError::InvalidAmount);
    let position = &mut ctx.accounts.position;
    require!(position.pending_units == 0, KaminoError::PendingWithdrawal);
    require!(
        amount <= ctx.accounts.token_ledger.principal,
        KaminoError::InsufficientPrincipal
    );
    let (usdc_before, units_before) = ctx
        .accounts
        .venue
        .validate(&ctx.accounts.vault.key(), position.units)?;
    require!(
        usdc_before >= ctx.accounts.token_ledger.recorded_total()?,
        KaminoError::InsufficientPrincipal
    );
    ctx.accounts.venue.refresh()?;
    ctx.accounts.venue.invoke(
        ctx.accounts.vault.to_account_info(),
        &ctx.accounts.fund.key(),
        ctx.accounts.fund.vault_bump,
        amount,
        true,
    )?;
    let (usdc_after, units_after) = ctx
        .accounts
        .venue
        .validate(&ctx.accounts.vault.key(), position.units)?;
    let received = units_after
        .checked_sub(units_before)
        .ok_or(KaminoError::UnexpectedDelta)?;
    require!(
        received > 0 && usdc_before.checked_sub(usdc_after) == Some(amount),
        KaminoError::UnexpectedDelta
    );
    position.units = checked_add(position.units, received)?;
    position.principal = checked_add(position.principal, amount)?;
    let was_empty = position.units == received;
    ctx.accounts.token_ledger.debit_principal(amount)?;
    checkpoint(position, ctx.accounts.venue.refresh()?)?;
    ctx.accounts.fund.register_position(position.key())?;
    if was_empty {
    ctx.accounts.fund.active_positions = ctx
        .accounts
        .fund
        .active_positions
        .checked_add(1)
        .ok_or(KaminoError::UnexpectedDelta)?;
    }
    emit!(KaminoSupplied {
        fund: position.fund,
        liquidity: amount,
        collateral: received
    });
    Ok(())
}

#[event]
pub struct KaminoSupplied {
    pub fund: Pubkey,
    pub liquidity: u64,
    pub collateral: u64,
}
