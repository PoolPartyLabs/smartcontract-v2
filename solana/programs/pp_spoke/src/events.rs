use anchor_lang::prelude::*;

/// DEC-190: emitted only after both Manager authorizations are verified by T1.
#[event]
pub struct FundInitialized {
    pub fund: Pubkey,
    pub mandate_hash: [u8; 32],
    pub manager_solana: Pubkey,
}

/// DEC-192: publishing is not evidence that guardians have finalized the VAA.
#[event]
pub struct ReportPublished {
    pub fund: Pubkey,
    pub sequence: u64,
    pub wormhole_sequence: u64,
}
