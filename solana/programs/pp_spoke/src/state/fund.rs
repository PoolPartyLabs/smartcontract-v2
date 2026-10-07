use anchor_lang::prelude::*;

/// DEC-188, DEC-190: immutable per-Fund identity and sealed native configuration.
#[account]
#[derive(InitSpace)]
pub struct FundState {
    pub hub_core: [u8; 20],
    pub spoke_index: u16,
    pub fund_id: [u8; 32],
    pub mandate_hash: [u8; 32],
    pub manager_evm: [u8; 20],
    pub manager_solana: Pubkey,
    pub report_sequence: u64,
    pub order_sequence: u64,
    pub closed: bool,
    pub bump: u8,
    pub vault_bump: u8,
    pub emitter_bump: u8,
    pub hub_chain_id: u64,
    pub factory: [u8; 20],
    pub spoke_chain_id: u64,
    pub native_mandate_hash: [u8; 32],
    pub binding_nonce: [u8; 32],
    pub binding_digest: [u8; 32],
    pub binding_expiry: u64,
    pub hub_emitter: [u8; 32],
    pub hub_emitter_chain: u16,
    pub cumulative_received: u128,
    pub cumulative_sent_home: u128,
    pub active_positions: u16,
    pub pending_transits: u16,
    pub pending_results: u16,
    #[max_len(3)]
    pub assets: Vec<Asset>,
    #[max_len(8)]
    pub venues: Vec<Venue>,
    pub transport: Transport,
    #[max_len(32)]
    pub position_registry: Vec<Pubkey>,
    #[max_len(64)]
    pub transit_registry: Vec<Pubkey>,
    pub policy_hash: [u8; 32],
    pub hub_policy_hash: [u8; 32],
    pub active_command: Pubkey,
    pub close_requested: bool,
    #[max_len(8)]
    pub command_registry: Vec<Pubkey>,
}

impl FundState {
    /// DEC-093, DEC-191, DEC-193: persistent exhaustive inventory; never truncate a report.
    pub fn register_position(&mut self, position: Pubkey) -> Result<()> {
        if !self.position_registry.contains(&position) {
            require!(self.position_registry.len() < 32, crate::instructions::core::guards::CoreError::ArithmeticOverflow);
            self.position_registry.push(position);
        }
        Ok(())
    }

    pub fn register_transit(&mut self, transit: Pubkey) -> Result<()> {
        require!(self.transit_registry.len() < 64 && !self.transit_registry.contains(&transit), crate::instructions::core::guards::CoreError::ArithmeticOverflow);
        self.transit_registry.push(transit);
        self.pending_transits = self.transit_registry.len() as u16;
        Ok(())
    }
}

#[cfg(test)]
mod registry_tests {
    use super::*;

    #[test]
    fn registry_is_persistent_unique_and_bounded() {
        let (mut fund, _) = crate::instructions::core::guards::fixture();
        let position = Pubkey::new_unique();
        fund.register_position(position).unwrap();
        fund.register_position(position).unwrap();
        assert_eq!(fund.position_registry.len(), 1);
        for _ in 1..32 { fund.register_position(Pubkey::new_unique()).unwrap(); }
        assert!(fund.register_position(Pubkey::new_unique()).is_err());
        let transit = Pubkey::new_unique();
        fund.register_transit(transit).unwrap();
        assert!(fund.register_transit(transit).is_err());
        for _ in 1..64 { fund.register_transit(Pubkey::new_unique()).unwrap(); }
        assert!(fund.register_transit(Pubkey::new_unique()).is_err());
        assert_eq!(fund.pending_transits, 64);
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace, Default)]
pub struct Transport {
    pub hub_usdc: [u8; 20],
    pub token_messenger: [u8; 20],
    pub message_transmitter: [u8; 20],
    pub destination_domain: u32,
    pub mint_recipient: Pubkey,
    pub destination_caller: Pubkey,
    pub remote_token_messenger: Pubkey,
    pub remote_vault_authority: Pubkey,
    pub fast_fee_ceiling: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace, PartialEq, Eq)]
pub struct Asset {
    pub mint: Pubkey,
    pub accounting_id: [u8; 20],
    pub stock: bool,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace, PartialEq, Eq)]
pub struct Venue {
    pub program: Pubkey,
    pub pool: Pubkey,
    pub reserve: Pubkey,
    pub token0: Pubkey,
    pub token1: Pubkey,
}

/// DEC-055, DEC-080: observations never authorize credits; adapters mutate recorded buckets.
#[account]
#[derive(InitSpace, Default)]
pub struct TokenLedger {
    pub fund: Pubkey,
    pub mint: Pubkey,
    pub principal: u64,
    pub collected_income: u64,
    pub cumulative_income: u128,
    pub bump: u8,
}
