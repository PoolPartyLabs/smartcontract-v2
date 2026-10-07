use super::{guard::{self, Conversion, SealedPolicy, SwapError, SwapRequest, WSOL}, oracle::{self, OraclePolicy, OracleError}, quote::{self, QuoteDomain, SignedQuote}};
use anchor_lang::prelude::*;
use super::streams::{self, StockPolicy};

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct AuthorizedSwap {
    pub quote: SignedQuote,
    pub max_price_impact_bps: u16,
    pub route_data: Vec<u8>,
    pub stock_report: Option<Vec<u8>>,
}

pub struct SealedSwapConfig<'policy> {
    pub api_signer: [u8; 20],
    pub domain: QuoteDomain,
    pub next_nonce: u64,
    pub route: SealedPolicy<'policy>,
    pub oracle: OraclePolicy,
    pub stocks: &'policy [(Pubkey, StockPolicy)],
}

pub struct OracleAccounts<'info> {
    pub sol: AccountInfo<'info>,
    pub usdc: AccountInfo<'info>,
    pub chainlink_sol: AccountInfo<'info>,
    pub stock_program: Option<AccountInfo<'info>>,
    pub stock_accounts: Vec<AccountInfo<'info>>,
}

pub struct AuthorizedConversion {
    pub conversion: Conversion,
    pub next_nonce: u64,
    pub minimum_out: u64,
}

/// DEC-202: no unsigned quote or Manager-provided reference is admitted here.
/// DEC-079, DEC-080: coordinator must atomically persist conversion and next_nonce.
pub fn execute<'info>(program: &AccountInfo<'info>, vault: &AccountInfo<'info>, fund: &Pubkey,
    accounts: &[AccountInfo<'info>], prices: &OracleAccounts<'info>, seeds: &[&[u8]],
    request: &AuthorizedSwap, sealed: &SealedSwapConfig, now: i64) -> Result<AuthorizedConversion> {
    require!(accounts.len() >= 10, SwapError::Route);
    require!(sealed.domain.program == crate::ID, SwapError::Program);
    let route_hash = quote::route_hash(&request.route_data, accounts, vault.key);
    let next_nonce = quote::verify(&request.quote, &sealed.domain, &sealed.api_signer, fund,
        &route_hash, sealed.next_nonce, now)?;
    let usdc_mint = pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
    let input = request.quote.token_in;
    let output = request.quote.token_out;
    require!(input == usdc_mint || output == usdc_mint, SwapError::Mint);
    let paired_mint = if input == usdc_mint { output } else { input };
    let usdc = oracle::pyth(&prices.usdc, &oracle::PYTH_USDC, &oracle::USDC_FEED, now, &sealed.oracle)?;
    let paired = if paired_mint == WSOL {
        require!(request.stock_report.is_none() && prices.stock_accounts.is_empty(), SwapError::Route);
        let sol = oracle::pyth(&prices.sol, &oracle::PYTH_SOL, &oracle::SOL_FEED, now, &sealed.oracle)?;
        oracle::monitor_cross_check(*fund, sol, &prices.chainlink_sol, now, &sealed.oracle)?;
        sol
    } else {
        // TODO(decision): Q2 option C defaults stock_enabled=false until subscription and packet-fit evidence.
        require!(sealed.oracle.stock_enabled, OracleError::StockDisabled);
        let stock = sealed.stocks.iter().find(|(mint, _)| *mint == paired_mint).ok_or(OracleError::StockDisabled)?;
        require!(prices.stock_accounts.len() == 4 && prices.stock_accounts[2].is_signer, OracleError::InvalidAccount);
        let underlying = streams::verify_stock(prices.stock_program.as_ref().ok_or(OracleError::InvalidAccount)?,
            &prices.stock_accounts, request.stock_report.as_ref().ok_or(OracleError::InvalidPrice)?,
            &stock.1, &sealed.oracle, now)?;
        let mint = if input == paired_mint { &accounts[3] } else { &accounts[4] };
        oracle::stock_price(underlying, mint, now)?
    };
    let input_decimals = oracle::mint_decimals(&accounts[3], &input)?;
    let output_decimals = oracle::mint_decimals(&accounts[4], &output)?;
    let minimum_out = oracle::minimum(request.quote.quoted_amount_in,
        if input == usdc_mint { usdc } else { paired }, if output == usdc_mint { usdc } else { paired },
        input_decimals, output_decimals, request.quote.min_amount_out, request.max_price_impact_bps, &sealed.oracle)?;
    let swap = SwapRequest { input_mint: input, output_mint: output,
        requested_input: request.quote.quoted_amount_in, min_out: minimum_out,
        slippage_bps: request.route_data.get(24..26).map(|bytes| u16::from_le_bytes(bytes.try_into().unwrap())).ok_or(SwapError::Route)?,
        route_data: request.route_data.clone() };
    guard::route_amount(&swap, &sealed.route)?;
    let quoted = u64::from_le_bytes(swap.route_data[16..24].try_into().unwrap());
    require!(quoted >= minimum_out, OracleError::Impact);
    let conversion = guard::execute_guarded(program, vault, accounts, seeds, &swap, &sealed.route)?;
    Ok(AuthorizedConversion { conversion, next_nonce, minimum_out })
}
