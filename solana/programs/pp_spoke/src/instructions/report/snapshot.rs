use super::codec::{self, NativeReport};
use crate::instructions::core::{binding::word, custody, guards::require_fund_address};
use crate::state::{FundState, TokenLedger};
use anchor_lang::prelude::*;

#[error_code]
pub enum ReportError {
    InvalidAccounts,
    AdapterNotIntegrated,
    TransitNotIntegrated,
    ResultsNotIntegrated,
    StockWitnessNotIntegrated,
    ReportTooLarge,
    InvalidWormhole,
    SequenceOverflow,
    OrderExecutionNotIntegrated,
    InvalidOrder,
}

/// DEC-093, DEC-192: never accept keeper-supplied quantities or silently omit live exposure.
pub fn snapshot(
    fund: &FundState,
    key: Pubkey,
    accounts: &[AccountInfo],
    clock: &Clock,
) -> Result<NativeReport> {
    require_fund_address(fund, &key)?;
    value_adapter_positions(fund)?;
    require!(
        fund.pending_transits == 0,
        ReportError::TransitNotIntegrated
    );
    require!(fund.pending_results == 0, ReportError::ResultsNotIntegrated);
    require!(
        !fund.assets.iter().any(|asset| asset.stock),
        ReportError::StockWitnessNotIntegrated
    );
    require!(
        accounts.len() == fund.assets.len() * 2 && clock.unix_timestamp >= 0,
        ReportError::InvalidAccounts
    );
    let vault =
        Pubkey::create_program_address(&[b"vault", key.as_ref(), &[fund.vault_bump]], &crate::ID)
            .map_err(|_| error!(ReportError::InvalidAccounts))?;
    let mut report = NativeReport {
        fund_id: fund.fund_id,
        mandate_hash: fund.mandate_hash,
        native_mandate_hash: fund.native_mandate_hash,
        sequence: fund
            .report_sequence
            .checked_add(1)
            .ok_or_else(|| error!(ReportError::SequenceOverflow))?,
        chain: fund.spoke_chain_id,
        slot: clock.slot,
        timestamp: clock.unix_timestamp as u64,
        cumulative_received: fund.cumulative_received,
        cumulative_sent_home: fund.cumulative_sent_home,
        ..NativeReport::default()
    };
    for (asset, pair) in fund.assets.iter().zip(accounts.chunks_exact(2)) {
        let ledger_key = Pubkey::find_program_address(
            &[b"ledger", key.as_ref(), asset.mint.as_ref()],
            &crate::ID,
        )
        .0;
        require_keys_eq!(*pair[0].key, ledger_key, ReportError::InvalidAccounts);
        require_keys_eq!(*pair[0].owner, crate::ID, ReportError::InvalidAccounts);
        let ledger = TokenLedger::try_deserialize(&mut &pair[0].try_borrow_data()?[..])?;
        require!(
            ledger.fund == key && ledger.mint == asset.mint,
            ReportError::InvalidAccounts
        );
        let observed = custody::recorded_custody_balance(&pair[1], &vault, &asset.mint)?;
        ledger.excess(observed)?;
        report
            .unallocated
            .push([asset.mint.to_bytes(), word(u128::from(ledger.principal))]);
        report.collected_income.push([
            asset.mint.to_bytes(),
            word(u128::from(ledger.collected_income)),
        ]);
        report
            .cumulative_income
            .push([asset.mint.to_bytes(), word(ledger.cumulative_income)]);
    }
    Ok(report)
}

fn value_adapter_positions(fund: &FundState) -> Result<()> {
    // TODO(interface): DEC-193 requires T3/T4 fresh valuation and exhaustive position registry.
    require!(
        fund.active_positions == 0,
        ReportError::AdapterNotIntegrated
    );
    Ok(())
}

pub fn encoded_snapshot(
    fund: &FundState,
    key: Pubkey,
    accounts: &[AccountInfo],
    clock: &Clock,
) -> Result<Vec<u8>> {
    codec::encode(&snapshot(fund, key, accounts, clock)?)
}
