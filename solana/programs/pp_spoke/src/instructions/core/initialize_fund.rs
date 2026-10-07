use super::{
    binding::{self, InitializePayload},
    custody,
    guards::CoreError,
};
use crate::state::{FundState, TokenLedger, transit::{CctpLedger, CctpRoute}};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{program::invoke_signed, system_instruction};

/// DEC-188, DEC-190, DEC-195: signer accepts a fixed binding and pays account/ATA rent.
#[derive(Accounts)]
pub struct InitializeFund<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    /// CHECK: derived from signed Hub Core and spoke index before allocation.
    #[account(mut)]
    pub fund: UncheckedAccount<'info>,
    /// CHECK: derived from the per-Fund state; never a spendable native SOL treasury.
    pub vault: UncheckedAccount<'info>,
    /// CHECK: canonical USDC mint and SPL Token owner validated before CPI.
    #[account(address = custody::USDC)]
    pub usdc_mint: UncheckedAccount<'info>,
    /// CHECK: canonical TSLAx mint and Token-2022 owner validated before CPI.
    #[account(address = custody::TSLAX)]
    pub tslax_mint: UncheckedAccount<'info>,
    /// CHECK: canonical WSOL mint and SPL Token owner validated before CPI.
    #[account(address = custody::WSOL)]
    pub wsol_mint: UncheckedAccount<'info>,
    /// CHECK: canonical vault ATA validated by create_ata.
    #[account(mut)]
    pub usdc_ata: UncheckedAccount<'info>,
    /// CHECK: canonical vault Token-2022 ATA validated by create_ata.
    #[account(mut)]
    pub tslax_ata: UncheckedAccount<'info>,
    /// CHECK: canonical vault ATA validated by create_ata.
    #[account(mut)]
    pub wsol_ata: UncheckedAccount<'info>,
    /// CHECK: per-Fund, per-mint ledger PDA validated before allocation.
    #[account(mut)]
    pub usdc_ledger: UncheckedAccount<'info>,
    /// CHECK: per-Fund, per-mint ledger PDA validated before allocation.
    #[account(mut)]
    pub tslax_ledger: UncheckedAccount<'info>,
    /// CHECK: per-Fund, per-mint ledger PDA validated before allocation.
    #[account(mut)]
    pub wsol_ledger: UncheckedAccount<'info>,
    /// CHECK: sealed CCTP route PDA allocated only after dual consent.
    #[account(mut)]
    pub cctp_route: UncheckedAccount<'info>,
    /// CHECK: transport metrics PDA; TokenLedger is the canonical spendable balance.
    #[account(mut)]
    pub cctp_ledger: UncheckedAccount<'info>,
    /// CHECK: pinned executable Token program.
    #[account(address = custody::TOKEN, executable)]
    pub token_program: UncheckedAccount<'info>,
    /// CHECK: pinned executable Token-2022 program.
    #[account(address = custody::TOKEN_2022, executable)]
    pub token_2022_program: UncheckedAccount<'info>,
    /// CHECK: pinned executable associated-token program.
    #[account(address = custody::ATA, executable)]
    pub ata_program: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

#[event]
pub struct CoreFundInitialized {
    pub fund: Pubkey,
    pub hub_core: [u8; 20],
    pub manager_evm: [u8; 20],
    pub manager_solana: Pubkey,
    pub native_mandate_hash: [u8; 32],
    pub binding_digest: [u8; 32],
}

pub fn handler(ctx: Context<InitializeFund>, payload: Vec<u8>) -> Result<()> {
    require!(payload.len() <= 2048, CoreError::InvalidConfiguration);
    let args = InitializePayload::try_from_slice(&payload)
        .map_err(|_| error!(CoreError::InvalidConfiguration))?;
    let index = args.spoke_index.to_le_bytes();
    let (fund_key, bump) =
        Pubkey::find_program_address(&[b"fund", &args.hub_core, &index, &args.mandate_hash], &crate::ID);
    require_keys_eq!(
        ctx.accounts.fund.key(),
        fund_key,
        CoreError::InvalidConfiguration
    );
    require!(
        ctx.accounts.fund.owner == &System::id() && ctx.accounts.fund.data_is_empty(),
        CoreError::InvalidConfiguration
    );
    let (vault_key, vault_bump) =
        Pubkey::find_program_address(&[b"vault", fund_key.as_ref()], &crate::ID);
    require_keys_eq!(
        ctx.accounts.vault.key(),
        vault_key,
        CoreError::InvalidCustody
    );
    let (emitter, emitter_bump) =
        Pubkey::find_program_address(&[b"emitter", fund_key.as_ref()], &crate::ID);
    let manager = ctx.accounts.authority.key();
    validate_config(&args, &manager, &emitter)?;
    let digest = binding::verify_binding(&args, &manager, &emitter, Clock::get()?.unix_timestamp)?;
    binding::verify_bootstrap(&args, &manager, &fund_key, Clock::get()?.unix_timestamp)?;
    let payer = ctx.accounts.authority.to_account_info();
    let system = ctx.accounts.system_program.to_account_info();
    allocate(
        &payer,
        &ctx.accounts.fund.to_account_info(),
        &system,
        8 + FundState::INIT_SPACE,
        &[b"fund", &args.hub_core, &index, &args.mandate_hash, &[bump]],
    )?;
    let route = CctpRoute {
        fund: fund_key,
        mandate_hash: args.mandate_hash,
        hub_connector: args.hub_core,
        solana_chain_id: args.spoke_chain_id,
        max_fee_bps_scaled: args.transport.fast_fee_ceiling,
        sealed: true,
    };
    let fund = FundState {
        hub_core: args.hub_core,
        spoke_index: args.spoke_index,
        fund_id: args.fund_id,
        mandate_hash: args.mandate_hash,
        manager_evm: args.manager_evm,
        manager_solana: manager,
        report_sequence: 0,
        order_sequence: 0,
        closed: false,
        bump,
        vault_bump,
        emitter_bump,
        hub_chain_id: args.hub_chain_id,
        factory: args.factory,
        spoke_chain_id: args.spoke_chain_id,
        native_mandate_hash: args.native_mandate_hash,
        binding_nonce: args.nonce,
        binding_digest: digest,
        binding_expiry: args.expiry,
        hub_emitter: binding::address_word(&args.hub_core),
        hub_emitter_chain: 23,
        cumulative_received: 0,
        cumulative_sent_home: 0,
        active_positions: 0,
        pending_transits: 0,
        pending_results: 0,
        assets: args.assets,
        venues: args.venues,
        transport: args.transport,
        position_registry: vec![],
        transit_registry: vec![],
    };
    fund.try_serialize(&mut &mut ctx.accounts.fund.try_borrow_mut_data()?[..])?;
    for (prefix, account, space) in [
        (b"cctp_route".as_slice(), &ctx.accounts.cctp_route, 8 + CctpRoute::INIT_SPACE),
        (b"cctp_ledger".as_slice(), &ctx.accounts.cctp_ledger, 8 + CctpLedger::INIT_SPACE),
    ] {
        let (expected, account_bump) = Pubkey::find_program_address(&[prefix, fund_key.as_ref()], &crate::ID);
        require_keys_eq!(account.key(), expected, CoreError::InvalidConfiguration);
        allocate(&payer, &account.to_account_info(), &system, space, &[prefix, fund_key.as_ref(), &[account_bump]])?;
    }
    route.try_serialize(&mut &mut ctx.accounts.cctp_route.try_borrow_mut_data()?[..])?;
    CctpLedger { fund: fund_key, principal: 0, outbound_gross: 0, outbound_in_flight: 0, received_principal: 0, fee_surplus_principal: 0 }
        .try_serialize(&mut &mut ctx.accounts.cctp_ledger.try_borrow_mut_data()?[..])?;
    for (mint, ata, ledger, token) in [
        (
            &ctx.accounts.usdc_mint,
            &ctx.accounts.usdc_ata,
            &ctx.accounts.usdc_ledger,
            &ctx.accounts.token_program,
        ),
        (
            &ctx.accounts.tslax_mint,
            &ctx.accounts.tslax_ata,
            &ctx.accounts.tslax_ledger,
            &ctx.accounts.token_2022_program,
        ),
        (
            &ctx.accounts.wsol_mint,
            &ctx.accounts.wsol_ata,
            &ctx.accounts.wsol_ledger,
            &ctx.accounts.token_program,
        ),
    ] {
        custody::create_ata(
            payer.clone(),
            ata.to_account_info(),
            ctx.accounts.vault.to_account_info(),
            mint.to_account_info(),
            system.clone(),
            token.to_account_info(),
            ctx.accounts.ata_program.to_account_info(),
        )?;
        let mint_key = mint.key();
        let (ledger_key, ledger_bump) = Pubkey::find_program_address(
            &[b"ledger", fund_key.as_ref(), mint_key.as_ref()],
            &crate::ID,
        );
        require_keys_eq!(ledger.key(), ledger_key, CoreError::InvalidCustody);
        allocate(
            &payer,
            &ledger.to_account_info(),
            &system,
            8 + TokenLedger::INIT_SPACE,
            &[
                b"ledger",
                fund_key.as_ref(),
                mint_key.as_ref(),
                &[ledger_bump],
            ],
        )?;
        TokenLedger {
            fund: fund_key,
            mint: mint_key,
            bump: ledger_bump,
            ..TokenLedger::default()
        }
        .try_serialize(&mut &mut ledger.try_borrow_mut_data()?[..])?;
    }
    emit!(CoreFundInitialized {
        fund: fund_key,
        hub_core: fund.hub_core,
        manager_evm: fund.manager_evm,
        manager_solana: manager,
        native_mandate_hash: fund.native_mandate_hash,
        binding_digest: digest
    });
    Ok(())
}

pub(crate) fn allocate<'info>(
    payer: &AccountInfo<'info>,
    account: &AccountInfo<'info>,
    system: &AccountInfo<'info>,
    space: usize,
    seeds: &[&[u8]],
) -> Result<()> {
    require!(
        account.owner == &System::id() && account.data_is_empty(),
        CoreError::InvalidConfiguration
    );
    let rent = Rent::get()?.minimum_balance(space);
    if account.lamports() == 0 {
        invoke_signed(
            &system_instruction::create_account(
                payer.key,
                account.key,
                rent,
                space as u64,
                &crate::ID,
            ),
            &[payer.clone(), account.clone(), system.clone()],
            &[seeds],
        )?;
    } else {
        let needed = rent.saturating_sub(account.lamports());
        if needed != 0 {
            anchor_lang::solana_program::program::invoke(
                &system_instruction::transfer(payer.key, account.key, needed),
                &[payer.clone(), account.clone(), system.clone()],
            )?;
        }
        invoke_signed(
            &system_instruction::allocate(account.key, space as u64),
            &[account.clone(), system.clone()],
            &[seeds],
        )?;
        invoke_signed(
            &system_instruction::assign(account.key, &crate::ID),
            &[account.clone(), system.clone()],
            &[seeds],
        )?;
    }
    Ok(())
}

pub fn validate_config(args: &InitializePayload, manager: &Pubkey, emitter: &Pubkey) -> Result<()> {
    let fund = Pubkey::find_program_address(
        &[b"fund", &args.hub_core, &args.spoke_index.to_le_bytes(), &args.mandate_hash],
        &crate::ID,
    )
    .0;
    let vault = Pubkey::find_program_address(&[b"vault", fund.as_ref()], &crate::ID).0;
    require!(
        args.transport.hub_usdc
            == [
                0xaf, 0x88, 0xd0, 0x65, 0xe7, 0x7c, 0x8c, 0xc2, 0x23, 0x93, 0x27, 0xc5, 0xed, 0xb3,
                0xa4, 0x32, 0x26, 0x8e, 0x58, 0x31
            ]
            && args.transport.token_messenger
                == [
                    0x28, 0xb5, 0xa0, 0xe9, 0xc6, 0x21, 0xa5, 0xba, 0xda, 0xa5, 0x36, 0x21, 0x9b,
                    0x3a, 0x22, 0x8c, 0x81, 0x68, 0xcf, 0x5d
                ]
            && args.transport.message_transmitter
                == [
                    0x81, 0xd4, 0x0f, 0x21, 0xf1, 0x2a, 0x8f, 0x0e, 0x32, 0x52, 0xbc, 0xcb, 0x95,
                    0x4d, 0x72, 0x2d, 0x4c, 0x46, 0x4b, 0x64
                ]
            && args.transport.destination_domain == 5
            && args.transport.fast_fee_ceiling == 50_000
            && args.transport.remote_token_messenger == custody::CCTP_MESSENGER
            && args.transport.remote_vault_authority == vault
            && args.transport.destination_caller == vault
            && args.transport.mint_recipient
                == custody::associated_address(&vault, &custody::USDC)?,
        CoreError::InvalidConfiguration
    );
    require!(
        args.hub_chain_id == 42161
            && args.spoke_chain_id == 1
            && args.factory != [0; 20]
            && args.hub_core != [0; 20]
            && args.fund_id != [0; 32]
            && args.mandate_hash != [0; 32],
        CoreError::InvalidConfiguration
    );
    require!(
        !args.assets.is_empty()
            && args.assets.len() <= 3
            && !args.venues.is_empty()
            && args.venues.len() <= 8,
        CoreError::InvalidConfiguration
    );
    for (index, asset) in args.assets.iter().enumerate() {
        custody::token_program(&asset.mint)?;
        require!(
            asset.stock == (asset.mint == custody::TSLAX)
                && asset.accounting_id == binding::accounting_alias(&asset.mint),
            CoreError::InvalidConfiguration
        );
        require!(!args.assets[..index].iter().any(|prior| prior.mint == asset.mint
            || prior.accounting_id == asset.accounting_id), CoreError::InvalidConfiguration);
    }
    require!(
        args.assets.iter().any(|asset| asset.mint == custody::USDC),
        CoreError::InvalidConfiguration
    );
    for (index, venue) in args.venues.iter().enumerate() {
        require!(
            (venue.pool == Pubkey::default()) != (venue.reserve == Pubkey::default())
                && !args.venues[..index].contains(venue),
            CoreError::InvalidConfiguration
        );
        require!(
            args.assets.iter().any(|asset| asset.mint == venue.token0),
            CoreError::InvalidConfiguration
        );
        if venue.reserve != Pubkey::default() {
            require!(
                venue.program == pubkey!("KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD")
                    && venue.reserve == crate::instructions::kamino::protocol::RESERVE
                    && venue.token0 == custody::USDC
                    && venue.token1 == Pubkey::default(),
                CoreError::InvalidConfiguration
            );
        } else {
            require!(
                venue.program == pubkey!("CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK")
                    && [crate::instructions::raydium::wire::TSLA_POOL, crate::instructions::raydium::wire::SOL_POOL].contains(&venue.pool)
                    && venue.token0 != venue.token1
                    && args.assets.iter().any(|asset| asset.mint == venue.token1),
                CoreError::InvalidConfiguration
            );
        }
    }
    require!(
        args.native_mandate_hash
            == binding::native_mandate_hash(
                manager,
                emitter,
                args.spoke_chain_id,
                &args.assets,
                &args.venues,
                &args.transport
            ),
        CoreError::InvalidConfiguration
    );
    Ok(())
}
