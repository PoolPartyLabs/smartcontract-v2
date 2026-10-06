use anchor_lang::prelude::*;

/// DEC-188, DEC-190: engineering seed convention; T1 owns final initialization validation.
pub const FUND_SEED: &[u8] = b"fund";
pub const VAULT_SEED: &[u8] = b"vault";
pub const EMITTER_SEED: &[u8] = b"emitter";
/// DEC-192: VAA wire consistency, not Wormhole post_message's enum input.
pub const WORMHOLE_FINALIZED_CONSISTENCY: u8 = 32;
pub const WORMHOLE_SOLANA_CHAIN: u16 = 1;
pub const WORMHOLE_ARBITRUM_CHAIN: u16 = 23;
pub const CCTP_SOLANA_DOMAIN: u32 = 5;
pub const CCTP_ARBITRUM_DOMAIN: u32 = 3;
/// DEC-196: retain the existing MVP cap; production correction belongs to a later change.
pub const MVP_MANAGEMENT_FEE_CAP_BPS: u16 = 500;

pub const USDC_MINT: Pubkey = pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
pub const TSLAX_MINT: Pubkey = pubkey!("XsDoVfqeBukxuZHWhdvWHBhgEHjGNst4MLodqsJHzoB");
pub const WSOL_MINT: Pubkey = pubkey!("So11111111111111111111111111111111111111112");
pub const TOKEN_PROGRAM: Pubkey = pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
pub const TOKEN_2022_PROGRAM: Pubkey = pubkey!("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");
pub const ASSOCIATED_TOKEN_PROGRAM: Pubkey =
    pubkey!("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
pub const RAYDIUM_CLMM_PROGRAM: Pubkey = pubkey!("CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK");
pub const RAYDIUM_TSLAX_USDC_POOL: Pubkey = pubkey!("8aDaBQkTrS6HVMjyc6EZebgdiaXhLYGriDWKWWp1NpFF");
pub const RAYDIUM_SOL_USDC_POOL: Pubkey = pubkey!("3ucNos4NbumPLZNWztqGHNFFgkHeRMBQAVemeeomsUxv");
pub const KAMINO_LEND_PROGRAM: Pubkey = pubkey!("KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD");
pub const KAMINO_MAIN_MARKET: Pubkey = pubkey!("7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF");
pub const KAMINO_USDC_RESERVE: Pubkey = pubkey!("D6q6wuQSrifJKZYpR1M8R4YawnLDtDsMmWM1NbBmgJ59");
pub const CCTP_MESSAGE_TRANSMITTER_PROGRAM: Pubkey =
    pubkey!("CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC");
pub const CCTP_TOKEN_MESSENGER_MINTER_PROGRAM: Pubkey =
    pubkey!("CCTPV2vPZJS2u2BBsUoscuikbYjnpFmbFsvVuJdgUMQe");
pub const WORMHOLE_CORE_PROGRAM: Pubkey = pubkey!("worm2ZoG2kUd4vFXhvjh93UUH596ayRfgQ2MgjNMTth");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fund_and_vault_addresses_are_isolated() {
        let first_core = [1u8; 20];
        let second_core = [2u8; 20];
        let first_index = 0u16.to_le_bytes();
        let second_index = 1u16.to_le_bytes();
        let (first, _) =
            Pubkey::find_program_address(&[FUND_SEED, &first_core, &first_index], &crate::ID);
        let (second, _) =
            Pubkey::find_program_address(&[FUND_SEED, &second_core, &first_index], &crate::ID);
        let (third, _) =
            Pubkey::find_program_address(&[FUND_SEED, &first_core, &second_index], &crate::ID);
        assert_ne!(first, second);
        assert_ne!(first, third);
        let (vault, _) = Pubkey::find_program_address(&[VAULT_SEED, first.as_ref()], &crate::ID);
        assert_ne!(first, vault);
        assert!(!vault.is_on_curve());
    }

    #[test]
    fn protocol_namespaces_and_mvp_cap_are_distinct() {
        assert_eq!(WORMHOLE_FINALIZED_CONSISTENCY, 32);
        assert_ne!(u32::from(WORMHOLE_SOLANA_CHAIN), CCTP_SOLANA_DOMAIN);
        assert_eq!(MVP_MANAGEMENT_FEE_CAP_BPS, 500);
    }
}
