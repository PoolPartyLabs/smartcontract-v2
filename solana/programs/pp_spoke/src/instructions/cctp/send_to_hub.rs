use super::{cpi, wire::*, CctpError, CctpTransitRecorded};
use crate::state::{
    transit::{CctpLedger, CctpRoute, Transit},
    FundState,
};
use anchor_lang::prelude::*;

/// DEC-190, DEC-191, DEC-195: Manager pays burn and event rent, vault signs custody CPI.
#[derive(Accounts)]
#[instruction(payload: Vec<u8>)]
pub struct SendToHub<'info> {
    #[account(mut, address = fund.manager_solana @ CctpError::Unauthorized)]
    pub authority: Signer<'info>,
    #[account(mut, seeds = [b"fund", &fund.hub_chain_id.to_le_bytes(), fund.hub_core.as_ref(), &fund.spoke_index.to_le_bytes(), fund.policy_hash.as_ref()], bump = fund.bump, constraint = !fund.closed @ CctpError::Unauthorized)]
    pub fund: Box<Account<'info, FundState>>,
    /// CHECK: canonical per-Fund vault, signs only the pinned Circle burn CPI.
    #[account(seeds = [b"vault", fund.key().as_ref()], bump = fund.vault_bump)]
    pub vault: UncheckedAccount<'info>,
    #[account(seeds = [b"cctp_route", fund.key().as_ref()], bump, has_one = fund, constraint = route.sealed && route.mandate_hash == fund.mandate_hash @ CctpError::UnsealedRoute)]
    pub route: Account<'info, CctpRoute>,
    #[account(mut, seeds = [b"cctp_ledger", fund.key().as_ref()], bump, has_one = fund)]
    pub ledger: Account<'info, CctpLedger>,
    #[account(init, payer = authority, space = 8 + Transit::INIT_SPACE, seeds = [b"transit", b"out", fund.key().as_ref(), &outbound_id(&fund.fund_id, transit_seed(&payload)?)?], bump)]
    pub transit: Account<'info, Transit>,
    /// CHECK: legacy native USDC ATA layout and custody checked before and after CPI.
    #[account(mut, address = cpi::ata(&vault.key()))]
    pub usdc_ata: UncheckedAccount<'info>,
    #[account(mut, seeds = [b"ledger", fund.key().as_ref(), USDC.as_ref()], bump = token_ledger.bump, has_one = fund,
        constraint = token_ledger.mint == USDC @ CctpError::InvalidAccount)]
    pub token_ledger: Box<Account<'info, crate::state::TokenLedger>>,
    #[account(mut)]
    pub event_account: Signer<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<SendToHub>, payload: Vec<u8>) -> Result<()> {
    crate::instructions::core::guards::require_fund_address(&ctx.accounts.fund, &ctx.accounts.fund.key())?;
    let mut params = SendParams::try_from_slice(&payload).map_err(|_| CctpError::InvalidPayload)?;
    params.transit_id = outbound_id(&ctx.accounts.fund.fund_id, &params.transit_id)?;
    let active = ctx.accounts.fund.active_command;
    let mut command = if active != Pubkey::default() {
        let account = ctx.remaining_accounts.last().ok_or(CctpError::InvalidAccount)?;
        require!(*account.key == active && *account.owner == crate::ID && account.is_writable,
            CctpError::InvalidAccount);
        let command = crate::state::command::HubCommand::try_deserialize(&mut &account.try_borrow_data()?[..])?;
        require!(command.fund == ctx.accounts.fund.key() && !command.completed && command.reserved == params.amount
            && command.transit_id == [0;32], CctpError::InvalidAmount);
        Some(command)
    } else {
        require!(!ctx.accounts.fund.close_requested, CctpError::Unauthorized);
        None
    };
    let income = command.as_ref().is_some_and(|command| command.kind == 3);
    require!(
        params.transit_id != [0; 32]
            && ctx.accounts.route.hub_connector != [0; 20]
            && ctx.accounts.route.solana_chain_id != 0
            && ctx.accounts.route.solana_chain_id != HUB_CHAIN,
        CctpError::UnsealedRoute
    );
    let net = fee_bound(
        params.amount,
        params.max_fee,
        ctx.accounts.route.max_fee_bps_scaled,
    )?;
    let ledger = &mut ctx.accounts.ledger;
    require!(
        (if income { ctx.accounts.token_ledger.collected_income } else { ctx.accounts.token_ledger.principal }) >= params.amount,
        CctpError::InsufficientPrincipal
    );
    let before = cpi::balance(
        &ctx.accounts.usdc_ata.to_account_info(),
        &ctx.accounts.vault.key(),
    )?;
    let fund_key = ctx.accounts.fund.key();
    let bump = [ctx.accounts.fund.vault_bump];
    let seeds = [b"vault".as_slice(), fund_key.as_ref(), bump.as_slice()];
    cpi::execute(
        MESSENGER,
        burn_data_kind(
            &params,
            &ctx.accounts.fund.hub_core,
            &ctx.accounts.route.hub_connector,
            &ctx.accounts.fund.fund_id,
            ctx.accounts.route.solana_chain_id,
            u8::from(income),
        ),
        if command.is_some() { &ctx.remaining_accounts[..ctx.remaining_accounts.len() - 1] } else { ctx.remaining_accounts },
        &cpi::burn_accounts(
            ctx.accounts.vault.key(),
            ctx.accounts.authority.key(),
            ctx.accounts.event_account.key(),
        ),
        &seeds,
    )?;
    let after = cpi::balance(
        &ctx.accounts.usdc_ata.to_account_info(),
        &ctx.accounts.vault.key(),
    )?;
    require!(
        before.checked_sub(after) == Some(params.amount),
        CctpError::WrongDelta
    );
    if income { ctx.accounts.token_ledger.debit_income(params.amount)?; }
    else { ctx.accounts.token_ledger.debit_principal(params.amount)?; }
    ledger.principal = ctx.accounts.token_ledger.principal;
    ledger.outbound_gross = ledger
        .outbound_gross
        .checked_add(params.amount)
        .ok_or(CctpError::InvalidAmount)?;
    ledger.outbound_in_flight = ledger
        .outbound_in_flight
        .checked_add(net)
        .ok_or(CctpError::InvalidAmount)?;
    ctx.accounts.fund.register_transit(ctx.accounts.transit.key())?;
    ctx.accounts.fund.cumulative_sent_home = ctx.accounts.fund.cumulative_sent_home.checked_add(u128::from(params.amount)).ok_or(CctpError::InvalidAmount)?;
    if let Some(command) = command.as_mut() {
        command.reserved = 0;
        command.transit_id = params.transit_id;
        command.amount_sent = params.amount;
        command.amount_to_arrive = net;
        command.try_serialize(&mut &mut ctx.remaining_accounts.last().unwrap().try_borrow_mut_data()?[..])?;
    }
    ctx.accounts.transit.set_inner(Transit {
        fund: fund_key,
        transit_id: params.transit_id,
        outbound: true,
        amount: params.amount,
        max_fee: params.max_fee,
        in_flight: net,
        credited: 0,
        fee_executed: 0,
        fee_surplus_principal: 0,
        nonce: [0; 32],
        message_hash: [0; 32],
        event_account: ctx.accounts.event_account.key(),
        rent_payer: ctx.accounts.authority.key(),
        received: false,
    });
    emit!(CctpTransitRecorded {
        fund: fund_key,
        transit_id: params.transit_id,
        outbound: true,
        amount: params.amount,
        max_fee: params.max_fee,
        credited: 0
    });
    Ok(())
}
