use super::{commands, snapshot::ReportError};
use crate::{instructions::core::{custody, guards::require_fund_address}, state::{FundState, TokenLedger, command::HubCommand}};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{instruction::{AccountMeta, Instruction}, program::invoke};

#[derive(Accounts)]
pub struct ResumeCommand<'info> {
    #[account(mut, address = fund.manager_solana)]
    pub authority: Signer<'info>,
    #[account(mut)]
    pub fund: Box<Account<'info, FundState>>,
    #[account(mut, seeds = [b"command", fund.key().as_ref(), &command.order_id], bump, has_one = fund)]
    pub command: Box<Account<'info, HubCommand>>,
    #[account(mut, seeds = [b"ledger", fund.key().as_ref(), custody::USDC.as_ref()], bump = usdc_ledger.bump, has_one = fund)]
    pub usdc_ledger: Box<Account<'info, TokenLedger>>,
    /// CHECK: only the current executable may dispatch guarded public adapter entries.
    #[account(address = crate::ID, executable)]
    pub spoke_program: UncheckedAccount<'info>,
}

/// DEC-151: opcode plus adapter payload; exact account lists belong to public adapter entries.
pub fn handler<'info>(ctx: Context<'_, '_, '_, 'info, ResumeCommand<'info>>, payload: Vec<u8>) -> Result<()> {
    require_fund_address(&ctx.accounts.fund, &ctx.accounts.fund.key())?;
    require!(!ctx.accounts.fund.closed && !ctx.accounts.command.completed
        && ctx.accounts.fund.active_command == ctx.accounts.command.key(), ReportError::InvalidOrder);
    let opcode = *payload.first().ok_or(ReportError::InvalidOrder)?;
    if opcode == 0 { return finalize(ctx); }
    let accounts = ctx.remaining_accounts;
    require!(accounts.len() >= 3 && *accounts[0].key == ctx.accounts.authority.key()
        && *accounts[1].key == ctx.accounts.fund.key(), ReportError::InvalidAccounts);
    let command = &ctx.accounts.command;
    let mut adapter_payload = payload[1..].to_vec();
    let (entry, step) = match opcode {
        1 => {
            // TODO(decision): proportional withdrawal Market Cost evidence is not integrated.
            require!(command.kind == 2 && accounts.len() > 3, ReportError::OrderExecutionNotIntegrated);
            let position = crate::state::kamino::KaminoPosition::try_deserialize(&mut &accounts[3].try_borrow_data()?[..])?;
            require!(position.fund == ctx.accounts.fund.key() && *accounts[3].owner == crate::ID, ReportError::InvalidAccounts);
            let units = commands::fraction(position.units, &command.payload[192..224], &command.payload[224..256])?;
            require!(units != 0 && adapter_payload.len() == 8, ReportError::InvalidOrder);
            adapter_payload = [units.to_le_bytes().as_slice(), adapter_payload.as_slice()].concat();
            ("kamino_redeem", Some(*accounts[3].key))
        }
        2 => {
            require!(command.kind == 2 && accounts.len() > 5, ReportError::OrderExecutionNotIntegrated);
            ("raydium_close_position", Some(*accounts[5].key))
        }
        3 => {
            require!(command.kind == 3 && accounts.len() > 5, ReportError::InvalidOrder);
            ("raydium_collect_fees", Some(*accounts[5].key))
        }
        4 => {
            require!(command.kind == 2, ReportError::OrderExecutionNotIntegrated);
            // TODO(decision): shared signed exact-in liquidation API; disabled entry stays pending.
            ("swap_exact_in", None)
        }
        _ => return err!(ReportError::InvalidOrder),
    };
    if let Some(step) = step {
        require!(ctx.accounts.fund.position_registry.contains(&step)
            && !command.delivered_steps.contains(&step) && command.delivered_steps.len() < 32, ReportError::InvalidOrder);
    }
    require!(accounts.iter().any(|account| *account.key == ctx.accounts.usdc_ledger.key()), ReportError::InvalidAccounts);
    let before = if command.kind == 3 { ctx.accounts.usdc_ledger.collected_income } else { ctx.accounts.usdc_ledger.principal };
    let was_closing = ctx.accounts.fund.close_requested;
    ctx.accounts.fund.active_command = Pubkey::default();
    ctx.accounts.fund.close_requested = false;
    ctx.accounts.fund.exit(&crate::ID)?;
    let discriminator = anchor_lang::solana_program::hash::hash(format!("global:{entry}").as_bytes()).to_bytes();
    let mut data = discriminator[..8].to_vec();
    adapter_payload.serialize(&mut data)?;
    let instruction = Instruction { program_id: crate::ID, accounts: accounts.iter().map(|account|
        if account.is_writable { AccountMeta::new(*account.key, account.is_signer) }
        else { AccountMeta::new_readonly(*account.key, account.is_signer) }).collect(), data };
    let mut infos = accounts.to_vec();
    infos.push(ctx.accounts.spoke_program.to_account_info());
    invoke(&instruction, &infos)?;
    ctx.accounts.fund.reload()?;
    ctx.accounts.usdc_ledger.reload()?;
    ctx.accounts.fund.active_command = ctx.accounts.command.key();
    ctx.accounts.fund.close_requested = was_closing;
    let after = if ctx.accounts.command.kind == 3 { ctx.accounts.usdc_ledger.collected_income } else { ctx.accounts.usdc_ledger.principal };
    ctx.accounts.command.reserved = ctx.accounts.command.reserved.checked_add(after.checked_sub(before)
        .ok_or(ReportError::InvalidAccounts)?).ok_or(ReportError::InvalidAccounts)?;
    if let Some(step) = step {
        let pending = opcode == 1 && crate::state::kamino::KaminoPosition::try_deserialize(&mut &accounts[3].try_borrow_data()?[..])?.pending_units != 0;
        if !pending {
            ctx.accounts.command.delivered_steps.push(step);
            ctx.accounts.command.delivered += 1;
        }
    }
    Ok(())
}

fn finalize(ctx: Context<ResumeCommand>) -> Result<()> {
    require!(ctx.accounts.command.reserved == 0, ReportError::OrderExecutionNotIntegrated);
    if ctx.accounts.command.kind == 2 {
        let report = super::snapshot::snapshot(&ctx.accounts.fund, ctx.accounts.fund.key(), ctx.remaining_accounts, &Clock::get()?)?;
        require!(report.positions.is_empty() && report.in_flight.is_empty()
            && report.unallocated.iter().all(|entry| entry[1] == [0;32])
            && report.collected_income.is_empty(), ReportError::OrderExecutionNotIntegrated);
    } else {
        require!(ctx.accounts.fund.assets.len() == 1, ReportError::OrderExecutionNotIntegrated);
        require!(ctx.accounts.command.delivered_steps.len() == ctx.accounts.fund.position_registry.len(),
            ReportError::OrderExecutionNotIntegrated);
        // TODO(decision): proportional non-USDC sales and authenticated Market Cost parity.
    }
    ctx.accounts.command.completed = true;
    ctx.accounts.fund.active_command = Pubkey::default();
    Ok(())
}
