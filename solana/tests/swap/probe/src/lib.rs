#![allow(unexpected_cfgs)]
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{entrypoint, entrypoint::ProgramResult};
#[path = "../../../../programs/pp_spoke/src/instructions/swap/guard.rs"]
mod guard;
#[path = "../../../../programs/pp_spoke/src/instructions/swap/quote.rs"]
mod quote;
#[path = "../../../../programs/pp_spoke/src/instructions/swap/oracle.rs"]
mod oracle;
#[path = "../../../../programs/pp_spoke/src/instructions/swap/scope.rs"]
mod scope;
#[path = "../../../../programs/pp_spoke/src/instructions/swap/streams.rs"]
mod streams;
#[path = "../../../../programs/pp_spoke/src/instructions/swap/authorized.rs"]
mod authorized;
use guard::{execute_guarded, SealedPolicy, SwapRequest, SwapError};

pub const ID: Pubkey = Pubkey::new_from_array([77; 32]);

entrypoint!(process_instruction);

fn process_instruction(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    if data.first() == Some(&3) { return scope_reference(accounts, &data[1..]).map_err(|error| { error.log(); error.into() }); }
    if data.first() == Some(&1) { return signed_swap(program_id, accounts, &data[1..]).map_err(|error| { error.log(); error.into() }); }
    if data.first() == Some(&2) { return stock_report(accounts, &data[1..]).map_err(|error| { error.log(); error.into() }); }
    let data = &data[1..];
    let request = SwapRequest::try_from_slice(data).map_err(|_| anchor_lang::error::Error::from(SwapError::Route))?;
    let manager = &accounts[0];
    let fund = &accounts[1];
    let vault = &accounts[2];
    let jupiter = &accounts[3];
    if !manager.is_signer { return Err(anchor_lang::error::Error::from(SwapError::Unauthorized).into()); }
    let (expected, bump) = Pubkey::find_program_address(&[b"vault", fund.key.as_ref()], program_id);
    if *vault.key != expected { return Err(anchor_lang::error::Error::from(SwapError::Custody).into()); }
    let mints = [
        pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"),
        pubkey!("XsDoVfqeBukxuZHWhdvWHBhgEHjGNst4MLodqsJHzoB"),
        pubkey!("Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh"),
        pubkey!("So11111111111111111111111111111111111111112"),
    ];
    let conversion = execute_guarded(jupiter, vault, &accounts[4..],
        &[b"vault", fund.key.as_ref(), &[bump]], &request,
        &SealedPolicy { mints: &mints, max_slippage_bps: 200 })?;
    msg!("TEST PROBE internal conversion: {} -> {}", conversion.input_units, conversion.output_units);
    Ok(())
}

fn scope_reference(accounts: &[AccountInfo], data: &[u8]) -> Result<()> {
    require!(accounts.len() == 3 && data.len() == 20, oracle::OracleError::InvalidAccount);
    let mut clock = Clock::get()?;
    let replay = i64::from_le_bytes(data[2..10].try_into().unwrap());
    if replay != 0 { clock.unix_timestamp = replay; }
    match data[1] {
        1 => clock.unix_timestamp = 1_791_403_200,
        2 => clock.unix_timestamp += 61,
        3 => clock.unix_timestamp -= 1,
        _ => {},
    }
    let policy = oracle::OraclePolicy { max_age_seconds: 120, max_confidence_bps: 100,
        cross_check_deviation_bps: 50, block_cross_check: false, require_manager_bound: false,
        stock_enabled: data[0] == 1 };
    let price = scope::reference(&accounts[0], &accounts[1], &accounts[2], data[0] == 1, &policy, &clock)?;
    let api_min = u64::from_le_bytes(data[10..18].try_into().unwrap());
    let impact = u16::from_le_bytes(data[18..20].try_into().unwrap());
    let minimum = oracle::minimum(25_000_000, oracle::Price { value: 100_000_000, exponent: -8 },
        price, 6, 8, api_min, impact, &policy)?;
    msg!("SCOPE PROBE: value {} exponent {} minimum {}", price.value, price.exponent, minimum);
    Ok(())
}

fn signed_swap(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> Result<()> {
    let now = i64::from_le_bytes(data[..8].try_into().unwrap());
    let request = authorized::AuthorizedSwap::try_from_slice(&data[8..]).map_err(|_| anchor_lang::error::Error::from(SwapError::Route))?;
    require!(accounts[0].is_signer, SwapError::Unauthorized);
    let fund = &accounts[1];
    require!(*fund.owner == *program_id && fund.data_len() == 8, SwapError::Custody);
    let nonce = u64::from_le_bytes(fund.try_borrow_data()?[..8].try_into().unwrap());
    let (expected, bump) = Pubkey::find_program_address(&[b"vault", fund.key.as_ref()], program_id);
    require!(*accounts[2].key == expected, SwapError::Custody);
    let mints = [pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"), guard::WSOL];
    let sealed = authorized::SealedSwapConfig {
        api_signer: [0xb0, 0xe5, 0x86, 0x3d, 0x0d, 0xdf, 0x7e, 0x10, 0x5e, 0x40, 0x9f, 0xee, 0x0e, 0xcc, 0x01, 0x23, 0xa3, 0x62, 0xe1, 0x4b],
        domain: quote::QuoteDomain { chain_id: 42161, verifying_contract: [5; 20], program: *program_id },
        next_nonce: nonce, route: SealedPolicy { mints: &mints, max_slippage_bps: 200 }, stocks: &[], scope_enabled: false,
        oracle: oracle::OraclePolicy { max_age_seconds: 120, max_confidence_bps: 100,
            cross_check_deviation_bps: 50, block_cross_check: false, require_manager_bound: false, stock_enabled: false },
    };
    let prices = authorized::OracleAccounts { sol: accounts[4].clone(), usdc: accounts[5].clone(), chainlink_sol: accounts[6].clone(), stock_program: None, stock_accounts: vec![] };
    let result = authorized::execute(&accounts[3], &accounts[2], fund.key, &accounts[7..], &prices,
        &[b"vault", fund.key.as_ref(), &[bump]], &request, &sealed, now)?;
    fund.try_borrow_mut_data()?[..8].copy_from_slice(&result.next_nonce.to_le_bytes());
    msg!("SIGNED PROBE: {} -> {}, min {}, nonce {}", result.conversion.input_units, result.conversion.output_units, result.minimum_out, result.next_nonce);
    Ok(())
}

fn stock_report(accounts: &[AccountInfo], data: &[u8]) -> Result<()> {
    let stock = streams::StockPolicy { feed_id: { let mut feed = [0; 32]; feed[1] = 10; feed },
        report_config: *accounts[4].key, access_controller: *accounts[2].key, price_decimals: 18 };
    let policy = oracle::OraclePolicy { max_age_seconds: 120, max_confidence_bps: 100,
        cross_check_deviation_bps: 50, block_cross_check: false, require_manager_bound: false, stock_enabled: true };
    let price = streams::verify_stock(&accounts[0], &accounts[1..5], data, &stock, &policy, Clock::get()?.unix_timestamp)?;
    msg!("STOCK PROBE: {} exponent {}", price.value, price.exponent);
    Ok(())
}
