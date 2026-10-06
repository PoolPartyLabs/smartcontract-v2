use crate::state::FundState;
use anchor_lang::prelude::*;

#[error_code]
pub enum CoreError {
    InvalidBinding,
    BindingExpired,
    InvalidConfiguration,
    UnauthorizedManager,
    FundClosed,
    ArithmeticOverflow,
    InsufficientRecordedBalance,
    InvalidCustody,
    BootstrapNotAuthenticated,
    AdapterNotIntegrated,
    ExcessRecipientNotConfigured,
}

/// DEC-190: direct signer authority is fixed per Fund, never a keeper or CPI caller.
pub fn require_manager(fund: &FundState, signer: &AccountInfo) -> Result<()> {
    require!(
        signer.is_signer && *signer.key == fund.manager_solana,
        CoreError::UnauthorizedManager
    );
    require!(!fund.closed, CoreError::FundClosed);
    Ok(())
}

pub fn require_fund_address(fund: &FundState, address: &Pubkey) -> Result<()> {
    let expected = Pubkey::create_program_address(
        &[
            b"fund",
            &fund.hub_core,
            &fund.spoke_index.to_le_bytes(),
            &[fund.bump],
        ],
        &crate::ID,
    )
    .map_err(|_| error!(CoreError::InvalidConfiguration))?;
    require_keys_eq!(*address, expected, CoreError::InvalidConfiguration);
    Ok(())
}

#[cfg(test)]
pub(crate) fn fixture() -> (FundState, Pubkey) {
    let hub_core = [1; 20];
    let (key, bump) =
        Pubkey::find_program_address(&[b"fund", &hub_core, &0u16.to_le_bytes()], &crate::ID);
    let (_, vault_bump) = Pubkey::find_program_address(&[b"vault", key.as_ref()], &crate::ID);
    let (_, emitter_bump) = Pubkey::find_program_address(&[b"emitter", key.as_ref()], &crate::ID);
    (
        FundState {
            hub_core,
            spoke_index: 0,
            fund_id: [2; 32],
            mandate_hash: [3; 32],
            manager_evm: [4; 20],
            manager_solana: Pubkey::new_unique(),
            report_sequence: 0,
            order_sequence: 0,
            closed: false,
            bump,
            vault_bump,
            emitter_bump,
            hub_chain_id: 42161,
            factory: [5; 20],
            spoke_chain_id: 1,
            native_mandate_hash: [6; 32],
            binding_nonce: [7; 32],
            binding_digest: [8; 32],
            binding_expiry: 2000,
            hub_emitter: super::binding::address_word(&hub_core),
            hub_emitter_chain: 23,
            cumulative_received: 0,
            cumulative_sent_home: 0,
            active_positions: 0,
            pending_transits: 0,
            pending_results: 0,
            assets: vec![],
            venues: vec![],
            transport: crate::state::Transport::default(),
        },
        key,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_manager_must_sign_and_closed_fund_refuses_actions() {
        let (mut fund, key) = fixture();
        require_fund_address(&fund, &key).unwrap();
        assert!(require_fund_address(&fund, &Pubkey::new_unique()).is_err());
        let manager = fund.manager_solana;
        let owner = System::id();
        let mut lamports = 0;
        let mut data = [];
        let account = AccountInfo::new(
            &manager,
            true,
            false,
            &mut lamports,
            &mut data,
            &owner,
            false,
            0,
        );
        require_manager(&fund, &account).unwrap();
        let mut unsigned = account.clone();
        unsigned.is_signer = false;
        assert!(require_manager(&fund, &unsigned).is_err());
        fund.closed = true;
        assert!(require_manager(&fund, &account).is_err());
    }
}
