use super::{accounts::*, protocol::*, valuation::checkpoint, KaminoError};
use crate::state::{fund::FundState, kamino::KaminoPosition};
use anchor_lang::prelude::*;
use crate::instructions::core::admission;

/// DEC-068, DEC-190: exits remain available when entry is disabled; only the Manager may request them.
#[derive(Accounts)]
pub struct KaminoRedeem<'info> {
    pub authority: Signer<'info>,
    #[account(mut, seeds = [b"fund", fund.hub_core.as_ref(), &fund.spoke_index.to_le_bytes(), fund.mandate_hash.as_ref()], bump = fund.bump,
        constraint = fund.manager_solana == authority.key() @ KaminoError::Unauthorized,
        constraint = !fund.closed @ KaminoError::EntryDisabled)]
    pub fund: Account<'info, FundState>,
    /// CHECK: canonical per-Fund vault signer.
    #[account(seeds = [b"vault", fund.key().as_ref()], bump = fund.vault_bump)]
    pub vault: UncheckedAccount<'info>,
    #[account(mut, seeds = [b"position", fund.key().as_ref(), RESERVE.as_ref()], bump,
        has_one = fund, constraint = position.reserve == RESERVE @ KaminoError::WrongReserve)]
    pub position: Account<'info, KaminoPosition>,
    pub venue: KaminoVenue<'info>,
    #[account(mut, seeds = [b"ledger", fund.key().as_ref(), USDC.as_ref()], bump = token_ledger.bump, has_one = fund,
        constraint = token_ledger.mint == USDC @ KaminoError::InvalidTokenAccount)]
    pub token_ledger: Account<'info, crate::state::TokenLedger>,
}

/// Payload: u64 cToken units, u64 minimum USDC; u64::MAX means all recorded units.
/// DEC-068: never silently redeem a partial request; illiquid requests remain pending in cToken units.
pub fn handler(ctx: Context<KaminoRedeem>, payload: Vec<u8>) -> Result<()> {
    admission::manager(&ctx.accounts.fund, &ctx.accounts.authority.to_account_info())?;
    admission::venue(&ctx.accounts.fund, PROGRAM, Pubkey::default(), RESERVE)?;
    require!(payload.len() == 16, KaminoError::InvalidAmount);
    let requested = read_u64(&payload, 0)?;
    let minimum = read_u64(&payload, 8)?;
    let position = &mut ctx.accounts.position;
    let units = if requested == u64::MAX {
        position.units
    } else {
        requested
    };
    require!(
        units > 0 && units <= position.units,
        KaminoError::InvalidAmount
    );
    require!(
        position.pending_units == 0
            || (position.pending_units == units && position.pending_min_liquidity == minimum),
        KaminoError::PendingWithdrawal
    );
    let (usdc_before, units_before) = ctx
        .accounts
        .venue
        .validate(&ctx.accounts.vault.key(), position.units)?;
    let reserve = ctx.accounts.venue.refresh()?;
    let expected = reserve.value(units)?;
    require!(
        expected >= minimum && expected > 0,
        KaminoError::UnexpectedDelta
    );
    if expected > reserve.freely_available()? {
        position.pending_units = units;
        position.pending_min_liquidity = minimum;
        checkpoint(position, reserve)?;
        emit!(KaminoWithdrawalPending {
            fund: position.fund,
            units,
            expected_liquidity: expected
        });
        return Ok(());
    }
    let value_before = reserve.value(position.units)?;
    let principal_now = position.principal.min(value_before);
    ctx.accounts.venue.invoke(
        ctx.accounts.vault.to_account_info(),
        &ctx.accounts.fund.key(),
        ctx.accounts.fund.vault_bump,
        units,
        false,
    )?;
    let (usdc_after, units_after) = ctx
        .accounts
        .venue
        .validate(&ctx.accounts.vault.key(), position.units - units)?;
    let received = usdc_after
        .checked_sub(usdc_before)
        .ok_or(KaminoError::UnexpectedDelta)?;
    require!(
        received == expected
            && received >= minimum
            && units_before.checked_sub(units_after) == Some(units),
        KaminoError::UnexpectedDelta
    );
    let principal_paid = received.min(principal_now);
    let income_paid = received - principal_paid;
    position.units -= units;
    position.principal = if position.units == 0 || principal_paid == principal_now {
        0
    } else {
        position
            .principal
            .checked_sub(principal_paid)
            .ok_or(KaminoError::MathOverflow)?
    };
    ctx.accounts.token_ledger.credit_principal(principal_paid)?;
    ctx.accounts.token_ledger.credit_income(income_paid)?;
    if position.units == 0 {
        ctx.accounts.fund.active_positions = ctx.accounts.fund.active_positions.checked_sub(1).ok_or(KaminoError::UnexpectedDelta)?;
    }
    position.cumulative_realized_income =
        checked_add(position.cumulative_realized_income, income_paid)?;
    position.pending_units = 0;
    position.pending_min_liquidity = 0;
    let refreshed = ctx.accounts.venue.refresh()?;
    let rounding_shortfall =
        (value_before - received).saturating_sub(refreshed.value(position.units)?);
    position.principal = position.principal.saturating_sub(rounding_shortfall);
    checkpoint(position, refreshed)?;
    emit!(KaminoRedeemed {
        fund: position.fund,
        units,
        principal: principal_paid,
        income: income_paid
    });
    Ok(())
}

#[event]
pub struct KaminoWithdrawalPending {
    pub fund: Pubkey,
    pub units: u64,
    pub expected_liquidity: u64,
}

#[event]
pub struct KaminoRedeemed {
    pub fund: Pubkey,
    pub units: u64,
    pub principal: u64,
    pub income: u64,
}
