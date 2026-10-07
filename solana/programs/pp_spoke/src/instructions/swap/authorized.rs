use super::{guard::{self, Conversion, SealedPolicy, SwapError, SwapRequest, WSOL}, oracle::{self, OraclePolicy, OracleError}, quote::{self, QuoteDomain, SignedQuote}};
use anchor_lang::prelude::*;

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct AuthorizedSwap {
    pub quote: SignedQuote,
    pub max_price_impact_bps: u16,
    pub route_data: Vec<u8>,
}

pub struct SealedSwapConfig<'policy> {
    pub api_signer: [u8; 20],
    pub domain: QuoteDomain,
    pub next_nonce: u64,
    pub route: SealedPolicy<'policy>,
    pub oracle: OraclePolicy,
}

pub struct OracleAccounts<'info> {
    pub sol: AccountInfo<'info>,
    pub usdc: AccountInfo<'info>,
    pub chainlink_sol: AccountInfo<'info>,
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
    // TODO(decision): Q2 option C; stock integration remains disabled until subscribed evidence passes.
    require!((input == WSOL && output == usdc_mint) || (input == usdc_mint && output == WSOL), OracleError::StockDisabled);
    let sol = oracle::pyth(&prices.sol, &oracle::PYTH_SOL, &oracle::SOL_FEED, now, &sealed.oracle)?;
    let usdc = oracle::pyth(&prices.usdc, &oracle::PYTH_USDC, &oracle::USDC_FEED, now, &sealed.oracle)?;
    let cross = oracle::chainlink_sol(&prices.chainlink_sol, now, &sealed.oracle)?;
    oracle::cross_check(*fund, sol, cross, &sealed.oracle)?;
    let input_decimals = oracle::mint_decimals(&accounts[3], &input)?;
    let output_decimals = oracle::mint_decimals(&accounts[4], &output)?;
    let minimum_out = oracle::minimum(request.quote.quoted_amount_in,
        if input == WSOL { sol } else { usdc }, if output == WSOL { sol } else { usdc },
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
