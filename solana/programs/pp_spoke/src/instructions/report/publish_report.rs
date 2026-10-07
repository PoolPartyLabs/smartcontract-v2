use super::{
    snapshot::{encoded_snapshot, ReportError},
    wormhole,
};
use crate::instructions::core::custody::WORMHOLE;
use crate::state::FundState;
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    program::{invoke, invoke_signed},
    system_instruction,
};

/// DEC-093, DEC-192, DEC-195: validated snapshot with keeper-paid reliable bridge CPI.
#[derive(Accounts)]
pub struct PublishReport<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Box<Account<'info, FundState>>,
    /// CHECK: compatibility account only; snapshot independently derives the custody PDA.
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: pinned executable mainnet core bridge; CPI owns its validated PDAs.
    #[account(address = WORMHOLE, executable)]
    pub wormhole_program: UncheckedAccount<'info>,
    /// CHECK: immutable Fund-specific emitter PDA, signed only by this instruction.
    #[account(seeds = [b"emitter", fund.key().as_ref()], bump = fund.emitter_bump)]
    pub emitter: UncheckedAccount<'info>,
    /// CHECK: canonical Bridge account owner, size and fee verified before CPI.
    #[account(mut, seeds = [b"Bridge"], bump, seeds::program = WORMHOLE, owner = WORMHOLE)]
    pub bridge: UncheckedAccount<'info>,
    /// CHECK: canonical sequence PDA; bridge CPI validates and initializes it.
    #[account(mut, seeds = [b"Sequence", emitter.key().as_ref()], bump, seeds::program = WORMHOLE)]
    pub sequence: UncheckedAccount<'info>,
    /// CHECK: canonical fee collector PDA; only keeper funds its fee.
    #[account(mut, seeds = [b"fee_collector"], bump, seeds::program = WORMHOLE)]
    pub fee_collector: UncheckedAccount<'info>,
    #[account(mut)]
    pub message: Signer<'info>,
    pub clock: Sysvar<'info, Clock>,
    pub rent: Sysvar<'info, Rent>,
    pub system_program: Program<'info, System>,
}

#[event]
pub struct NativeReportPublished {
    pub fund: Pubkey,
    pub report_sequence: u64,
    pub wormhole_sequence: u64,
    pub message: Pubkey,
    pub slot: u64,
    pub consistency: u8,
}

pub fn handler(ctx: Context<PublishReport>, payload: Vec<u8>) -> Result<()> {
    require!(payload.is_empty(), ReportError::InvalidAccounts);
    let fund_key = ctx.accounts.fund.key();
    let encoded = encoded_snapshot(
        &ctx.accounts.fund,
        fund_key,
        ctx.remaining_accounts,
        &ctx.accounts.clock,
    )?;
    let fee = {
        let data = ctx.accounts.bridge.try_borrow_data()?;
        require!(data.len() == 24, ReportError::InvalidWormhole);
        u64::from_le_bytes(data[16..24].try_into().unwrap())
    };
    let sequence = {
        let data = ctx.accounts.sequence.try_borrow_data()?;
        if data.is_empty() {
            require!(
                ctx.accounts.sequence.owner == &System::id(),
                ReportError::InvalidWormhole
            );
            0
        } else {
            require!(
                data.len() == 8 && ctx.accounts.sequence.owner == &WORMHOLE,
                ReportError::InvalidWormhole
            );
            u64::from_le_bytes(data[..8].try_into().unwrap())
        }
    };
    require!(sequence < u64::MAX, ReportError::SequenceOverflow);
    invoke(
        &system_instruction::transfer(
            &ctx.accounts.authority.key(),
            &ctx.accounts.fee_collector.key(),
            fee,
        ),
        &[
            ctx.accounts.authority.to_account_info(),
            ctx.accounts.fee_collector.to_account_info(),
            ctx.accounts.system_program.to_account_info(),
        ],
    )?;
    let instruction = wormhole::post_message(
        ctx.accounts.authority.key(),
        ctx.accounts.emitter.key(),
        ctx.accounts.message.key(),
        encoded,
    )?;
    invoke_signed(
        &instruction,
        &[
            ctx.accounts.bridge.to_account_info(),
            ctx.accounts.message.to_account_info(),
            ctx.accounts.emitter.to_account_info(),
            ctx.accounts.sequence.to_account_info(),
            ctx.accounts.authority.to_account_info(),
            ctx.accounts.fee_collector.to_account_info(),
            ctx.accounts.clock.to_account_info(),
            ctx.accounts.rent.to_account_info(),
            ctx.accounts.system_program.to_account_info(),
            ctx.accounts.wormhole_program.to_account_info(),
        ],
        &[&[
            b"emitter",
            fund_key.as_ref(),
            &[ctx.accounts.fund.emitter_bump],
        ]],
    )?;
    let new_sequence = u64::from_le_bytes(
        ctx.accounts.sequence.try_borrow_data()?[..8]
            .try_into()
            .unwrap(),
    );
    require!(new_sequence == sequence + 1, ReportError::InvalidWormhole);
    if ctx.accounts.fund.close_requested && ctx.accounts.fund.active_command == Pubkey::default() {
        let report = super::snapshot::snapshot(&ctx.accounts.fund, fund_key, ctx.remaining_accounts, &ctx.accounts.clock)?;
        require!(report.positions.is_empty() && report.in_flight.is_empty() && report.collected_income.is_empty()
            && report.unallocated.iter().all(|entry| entry[1] == [0;32]), ReportError::OrderExecutionNotIntegrated);
        ctx.accounts.fund.closed = true;
    }
    ctx.accounts.fund.report_sequence = ctx
        .accounts
        .fund
        .report_sequence
        .checked_add(1)
        .ok_or_else(|| error!(ReportError::SequenceOverflow))?;
    emit!(NativeReportPublished {
        fund: fund_key,
        report_sequence: ctx.accounts.fund.report_sequence,
        wormhole_sequence: sequence,
        message: ctx.accounts.message.key(),
        slot: ctx.accounts.clock.slot,
        consistency: 32
    });
    Ok(())
}
