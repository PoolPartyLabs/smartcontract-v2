use super::{cpi, wire::*, CctpError, CctpTransitRecorded};
use crate::state::{
    transit::{CctpLedger, CctpRoute, Transit},
    FundState,
};
use anchor_lang::prelude::*;

/// DEC-191: permissionless relaying, authenticated atomic credit, business-id replay fails.
#[derive(Accounts)]
#[instruction(payload: Vec<u8>)]
pub struct ReceiveAndCredit<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    // TODO(decision): coordinate closed-Fund excess arrival handling with T1 (DEC-167).
    #[account(mut, seeds = [b"fund", fund.hub_core.as_ref(), &fund.spoke_index.to_le_bytes(), fund.mandate_hash.as_ref()], bump = fund.bump, constraint = !fund.closed @ CctpError::Unauthorized)]
    pub fund: Account<'info, FundState>,
    /// CHECK: canonical vault signs as destinationCaller, never the relayer.
    #[account(seeds = [b"vault", fund.key().as_ref()], bump = fund.vault_bump)]
    pub vault: UncheckedAccount<'info>,
    #[account(seeds = [b"cctp_route", fund.key().as_ref()], bump, has_one = fund, constraint = route.sealed && route.mandate_hash == fund.mandate_hash @ CctpError::UnsealedRoute)]
    pub route: Account<'info, CctpRoute>,
    #[account(mut, seeds = [b"cctp_ledger", fund.key().as_ref()], bump, has_one = fund)]
    pub ledger: Account<'info, CctpLedger>,
    #[account(init, payer = authority, space = 8 + Transit::INIT_SPACE, seeds = [b"transit", fund.key().as_ref(), transit_seed(&payload)?], bump)]
    pub transit: Account<'info, Transit>,
    /// CHECK: native USDC custody and exact delta verified around Circle receive.
    #[account(mut, address = cpi::ata(&vault.key()))]
    pub usdc_ata: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

pub fn handler(ctx: Context<ReceiveAndCredit>, payload: Vec<u8>) -> Result<()> {
    let params = ReceiveParams::try_from_slice(&payload).map_err(|_| CctpError::InvalidPayload)?;
    require!(
        params.transit_id != [0; 32]
            && !params.attestation.is_empty()
            && params.attestation.len() <= 65 * 16,
        CctpError::InvalidPayload
    );
    let arrival = validate_arrival(
        &params.message,
        &ctx.accounts.fund.fund_id,
        &params.transit_id,
        &ctx.accounts.fund.hub_core,
        &ctx.accounts.vault.key(),
        &ctx.accounts.usdc_ata.key(),
        ctx.accounts.route.max_fee_bps_scaled,
    )?;
    let before = cpi::balance(
        &ctx.accounts.usdc_ata.to_account_info(),
        &ctx.accounts.vault.key(),
    )?;
    let messenger = ctx
        .remaining_accounts
        .get(9)
        .ok_or(CctpError::InvalidAccount)?;
    require!(
        messenger.key() == cpi::pda(&MESSENGER, &[b"token_messenger"])
            && *messenger.owner == MESSENGER,
        CctpError::InvalidAccount
    );
    let fee_recipient = {
        let data = messenger.try_borrow_data()?;
        require!(data.len() >= 141, CctpError::InvalidAccount);
        let fee_owner = Pubkey::new_from_array(
            data[109..141]
                .try_into()
                .map_err(|_| CctpError::InvalidAccount)?,
        );
        cpi::pda(&ATA, &[fee_owner.as_ref(), TOKEN.as_ref(), USDC.as_ref()])
    };
    let fund_key = ctx.accounts.fund.key();
    let bump = [ctx.accounts.fund.vault_bump];
    let seeds = [b"vault".as_slice(), fund_key.as_ref(), bump.as_slice()];
    let data = [
        discriminator("receive_message").as_slice(),
        &(params.message.len() as u32).to_le_bytes(),
        &params.message,
        &(params.attestation.len() as u32).to_le_bytes(),
        &params.attestation,
    ]
    .concat();
    cpi::execute(
        TRANSMITTER,
        data,
        ctx.remaining_accounts,
        &cpi::receive_accounts(
            ctx.accounts.vault.key(),
            ctx.accounts.authority.key(),
            ctx.accounts.usdc_ata.key(),
            &arrival.nonce,
            fee_recipient,
        ),
        &seeds,
    )?;
    let after = cpi::balance(
        &ctx.accounts.usdc_ata.to_account_info(),
        &ctx.accounts.vault.key(),
    )?;
    let credited = arrival.amount - arrival.fee_executed;
    require!(
        after.checked_sub(before) == Some(credited),
        CctpError::WrongDelta
    );
    let surplus = arrival.max_fee - arrival.fee_executed;
    let ledger = &mut ctx.accounts.ledger;
    ctx.accounts.fund.pending_transits = ctx
        .accounts
        .fund
        .pending_transits
        .checked_add(1)
        .ok_or(CctpError::InvalidAmount)?;
    ledger.principal = ledger
        .principal
        .checked_add(credited)
        .ok_or(CctpError::InvalidAmount)?;
    ledger.received_principal = ledger
        .received_principal
        .checked_add(credited)
        .ok_or(CctpError::InvalidAmount)?;
    ledger.fee_surplus_principal = ledger
        .fee_surplus_principal
        .checked_add(surplus)
        .ok_or(CctpError::InvalidAmount)?;
    ctx.accounts.transit.set_inner(Transit {
        fund: fund_key,
        transit_id: params.transit_id,
        outbound: false,
        amount: arrival.amount,
        max_fee: arrival.max_fee,
        in_flight: arrival.amount - arrival.max_fee,
        credited,
        fee_executed: arrival.fee_executed,
        fee_surplus_principal: surplus,
        nonce: arrival.nonce,
        message_hash: anchor_lang::solana_program::keccak::hash(&params.message).to_bytes(),
        event_account: Pubkey::default(),
        rent_payer: ctx.accounts.authority.key(),
        received: true,
    });
    emit!(CctpTransitRecorded {
        fund: fund_key,
        transit_id: params.transit_id,
        outbound: false,
        amount: arrival.amount,
        max_fee: arrival.max_fee,
        credited
    });
    Ok(())
}
