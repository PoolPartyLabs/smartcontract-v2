use super::guard::{SwapError, JUPITER};
#[cfg(feature = "rehearsal-v1-swap")]
use super::rehearsal_guard::{SwapRequest, SealedPolicy, execute_guarded};
use crate::state::FundState;
use anchor_lang::prelude::*;

/// DEC-190, DEC-193; RULINGS R5.1: fixed Manager and pinned Jupiter target.
#[derive(Accounts)]
pub struct SwapToRatio<'info> {
    #[account(address = fund.manager_solana @ SwapError::Unauthorized)]
    pub authority: Signer<'info>,
    #[account(mut, seeds = [b"fund", &fund.hub_chain_id.to_le_bytes(), fund.hub_core.as_ref(), &fund.spoke_index.to_le_bytes(), fund.policy_hash.as_ref()], bump = fund.bump,
        constraint = !fund.closed @ SwapError::Closed)]
    pub fund: Box<Account<'info, FundState>>,
    /// CHECK: DEC-190, DEC-195: PDA signs token transfers, never holds Fund SOL.
    #[account(seeds = [b"vault", fund.key().as_ref()], bump = fund.vault_bump,
        constraint = vault.lamports() == 0 @ SwapError::Custody)]
    pub vault: UncheckedAccount<'info>,
    /// CHECK: RULINGS R5.1: the executable Jupiter program is pinned, not caller-selected.
    #[account(address = JUPITER @ SwapError::Program, executable)]
    pub swap_program: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

#[cfg(feature = "rehearsal-v1-swap")]
pub fn handler<'info>(ctx: Context<'_, '_, '_, 'info, SwapToRatio<'info>>, payload: Vec<u8>) -> Result<()> {
    require!(cfg!(feature = "rehearsal-v1-swap"), SwapError::IntegrationPending);
    crate::instructions::core::admission::manager(&ctx.accounts.fund, &ctx.accounts.authority.to_account_info())?;
    let request = SwapRequest::try_from_slice(&payload).map_err(|_| SwapError::Route)?;
    require!(ctx.remaining_accounts.len() >= 2, SwapError::Custody);
    let ledger_offset = ctx.remaining_accounts.len() - 2;
    let input_account = &ctx.remaining_accounts[ledger_offset];
    let output_account = &ctx.remaining_accounts[ledger_offset + 1];
    let mut input = crate::instructions::core::admission::read_ledger(input_account, ctx.accounts.fund.key(), request.input_mint)?;
    let mut output = crate::instructions::core::admission::read_ledger(output_account, ctx.accounts.fund.key(), request.output_mint)?;
    require!(request.requested_input <= input.principal, SwapError::Custody);
    let mints: Vec<Pubkey> = ctx.accounts.fund.assets.iter().map(|asset| asset.mint).collect();
    for mint in [request.input_mint, request.output_mint] {
        if ctx.accounts.fund.assets.iter().any(|asset| asset.mint == mint && asset.stock) {
            let mint_account = ctx.remaining_accounts[..ledger_offset].iter().find(|account| *account.key == mint).ok_or(SwapError::Mint)?;
            let ata = crate::instructions::core::custody::associated_address(&ctx.accounts.vault.key(), &mint)?;
            let token_account = ctx.remaining_accounts[..ledger_offset].iter().find(|account| *account.key == ata).ok_or(SwapError::Custody)?;
            crate::instructions::core::stock::witness(mint_account, token_account)?;
        }
    }
    let policy = SealedPolicy { mints: &mints, max_slippage_bps: request.slippage_bps };
    // DEC-197, R6.2/R6.3: guarded V1 rehearsal path only; T5b replaces pricing/quote/decoder.
    let fund_key = ctx.accounts.fund.key();
    let bump = [ctx.accounts.fund.vault_bump];
    let seeds = [b"vault".as_slice(), fund_key.as_ref(), bump.as_slice()];
    let conversion = execute_guarded(&ctx.accounts.swap_program.to_account_info(), &ctx.accounts.vault.to_account_info(),
        &ctx.remaining_accounts[..ledger_offset], &seeds, &request, &policy)?;
    input.debit_principal(conversion.input_units)?;
    output.credit_principal(conversion.output_units)?;
    crate::instructions::core::admission::write_ledger(input_account, &input)?;
    crate::instructions::core::admission::write_ledger(output_account, &output)
}

#[cfg(not(feature = "rehearsal-v1-swap"))]
pub fn handler<'info>(ctx: Context<'_, '_, '_, 'info, SwapToRatio<'info>>, payload: Vec<u8>) -> Result<()> {
    crate::instructions::core::admission::manager(&ctx.accounts.fund, &ctx.accounts.authority.to_account_info())?;
    require!(payload.len() <= 4096, SwapError::Route);
    super::authorized::AuthorizedSwap::try_from_slice(&payload).map_err(|_| error!(SwapError::Route))?;
    // TODO(decision): DEC-202 requires sealed signer/oracle policy and nonce persistence before enabling execution.
    err!(SwapError::IntegrationPending)
}
