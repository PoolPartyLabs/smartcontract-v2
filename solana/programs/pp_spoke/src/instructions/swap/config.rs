use super::{guard::{SealedPolicy, SwapError}, oracle::{self, OraclePolicy}, quote::QuoteDomain};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{keccak, secp256k1_recover::secp256k1_recover};

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct SwapPolicy {
    pub api_signer: [u8; 20],
    pub sol_account: Pubkey,
    pub usdc_account: Pubkey,
    pub sol_feed: [u8; 32],
    pub usdc_feed: [u8; 32],
    pub max_age_seconds: u64,
    pub max_confidence_bps: u16,
    pub cross_check_deviation_bps: u16,
    pub max_slippage_bps: u16,
    pub reference_mode: u8,
    pub stock_enabled: bool,
}

#[account]
#[derive(InitSpace)]
pub struct SwapConfig {
    pub fund: Pubkey,
    pub binding_digest: [u8; 32],
    pub policy: SwapPolicy,
    pub next_nonce: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace)]
pub struct CreationPolicy {
    pub policy: SwapPolicy,
    pub signature: [u8; 65],
}

#[account]
#[derive(InitSpace)]
pub struct StagedPolicy {
    pub fund: Pubkey,
    pub manager_solana: Pubkey,
    pub binding_digest: [u8; 32],
    pub creation: CreationPolicy,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct StageRequest {
    pub binding_digest: [u8; 32],
    pub creation: CreationPolicy,
}

impl SwapPolicy {
    /// DEC-202, DEC-203: oracle mode is sealed; TODO(decision) sol-oracle-Q2 stocks remain disabled.
    pub fn validate(&self) -> Result<()> {
        require!(self.api_signer != [0; 20] && self.max_age_seconds > 0
            && self.max_age_seconds <= 300 && self.max_confidence_bps > 0
            && self.max_confidence_bps < 10_000 && self.cross_check_deviation_bps < 10_000
            && self.max_slippage_bps < 10_000, SwapError::Route);
        require!(self.reference_mode == 0 && !self.stock_enabled, SwapError::IntegrationPending);
        require!(self.sol_account == oracle::PYTH_SOL && self.usdc_account == oracle::PYTH_USDC
            && self.sol_feed == oracle::SOL_FEED && self.usdc_feed == oracle::USDC_FEED, SwapError::Route);
        Ok(())
    }

    pub fn oracle(&self) -> OraclePolicy {
        OraclePolicy { max_age_seconds: self.max_age_seconds, max_confidence_bps: self.max_confidence_bps,
            cross_check_deviation_bps: self.cross_check_deviation_bps, block_cross_check: false,
            require_manager_bound: false, stock_enabled: self.stock_enabled }
    }
}

/// DEC-190, DEC-200, DEC-202: separate EVM consent binds policy to the authenticated creation tuple.
pub fn digest(policy: &SwapPolicy, binding: &[u8; 32], fund: &Pubkey, domain: &QuoteDomain) -> Result<[u8; 32]> {
    let mut contract = [0u8; 32];
    contract[12..].copy_from_slice(&domain.verifying_contract);
    let domain_hash = keccak::hashv(&[
        &keccak::hash(b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)").to_bytes(),
        &keccak::hash(b"Pool Party Swap Adapter").to_bytes(), &keccak::hash(b"2").to_bytes(),
        &crate::instructions::core::binding::word(u128::from(domain.chain_id)), &contract, &domain.program.to_bytes(),
    ]).to_bytes();
    let message = keccak::hashv(&[
        &keccak::hash(b"SolanaSwapPolicy(bytes32 fund,bytes32 bindingDigest,bytes32 policyHash)").to_bytes(),
        &fund.to_bytes(), binding, &keccak::hash(&policy.try_to_vec()?).to_bytes(),
    ]).to_bytes();
    Ok(keccak::hashv(&[b"\x19\x01", &domain_hash, &message]).to_bytes())
}

pub fn verify(creation: &CreationPolicy, binding: &[u8; 32], fund: &Pubkey, manager: &[u8; 20], domain: &QuoteDomain) -> Result<()> {
    creation.policy.validate()?;
    let scalar: [u8; 32] = creation.signature[32..64].try_into().unwrap();
    let half_order = [0x7f,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
        0x5d,0x57,0x6e,0x73,0x57,0xa4,0x50,0x1d,0xdf,0xe9,0x2f,0x46,0x68,0x1b,0x20,0xa0];
    require!(scalar != [0; 32] && scalar <= half_order && matches!(creation.signature[64], 27 | 28), SwapError::Unauthorized);
    let recovered = secp256k1_recover(&digest(&creation.policy, binding, fund, domain)?, creation.signature[64] - 27,
        &creation.signature[..64]).map_err(|_| error!(SwapError::Unauthorized))?;
    require!(keccak::hash(&recovered.to_bytes()).to_bytes()[12..] == *manager && *manager != [0; 20], SwapError::Unauthorized);
    Ok(())
}

pub fn route_policy<'policy>(policy: &SwapPolicy, mints: &'policy [Pubkey]) -> SealedPolicy<'policy> {
    SealedPolicy { mints, max_slippage_bps: policy.max_slippage_bps }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reject_unapproved_modes_and_unpinned_feeds() {
        let mut policy = SwapPolicy { api_signer: [1; 20], sol_account: oracle::PYTH_SOL,
            usdc_account: oracle::PYTH_USDC, sol_feed: oracle::SOL_FEED, usdc_feed: oracle::USDC_FEED,
            max_age_seconds: 120, max_confidence_bps: 100, cross_check_deviation_bps: 50,
            max_slippage_bps: 100, reference_mode: 0, stock_enabled: false };
        assert!(policy.validate().is_ok());
        policy.stock_enabled = true; assert!(policy.validate().is_err()); policy.stock_enabled = false;
        policy.reference_mode = 1; assert!(policy.validate().is_err()); policy.reference_mode = 0;
        policy.sol_feed[0] ^= 1; assert!(policy.validate().is_err());
    }

    #[test]
    fn consent_commits_every_policy_byte_and_creation_identity() {
        let mut policy = SwapPolicy { api_signer: [1; 20], sol_account: oracle::PYTH_SOL,
            usdc_account: oracle::PYTH_USDC, sol_feed: oracle::SOL_FEED, usdc_feed: oracle::USDC_FEED,
            max_age_seconds: 120, max_confidence_bps: 100, cross_check_deviation_bps: 50,
            max_slippage_bps: 100, reference_mode: 0, stock_enabled: false };
        let binding = [2; 32]; let fund = Pubkey::new_unique();
        let domain = QuoteDomain { chain_id: 42161, verifying_contract: [3; 20], program: crate::ID };
        let expected = digest(&policy, &binding, &fund, &domain).unwrap();
        assert_ne!(expected, digest(&policy, &[4; 32], &fund, &domain).unwrap());
        assert_ne!(expected, digest(&policy, &binding, &Pubkey::new_unique(), &domain).unwrap());
        policy.max_age_seconds += 1;
        assert_ne!(expected, digest(&policy, &binding, &fund, &domain).unwrap());
        policy.max_age_seconds -= 1; policy.api_signer[0] ^= 1;
        assert_ne!(expected, digest(&policy, &binding, &fund, &domain).unwrap());
        policy.api_signer[0] ^= 1; policy.stock_enabled = true;
        assert_ne!(expected, digest(&policy, &binding, &fund, &domain).unwrap());
    }
}
