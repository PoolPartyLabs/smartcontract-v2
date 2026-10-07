use anchor_lang::prelude::*;
use anchor_lang::solana_program::{keccak, secp256k1_recover::secp256k1_recover};

pub const QUOTE_TYPE: &str = "SolanaSwapRoute(bytes32 fund,bytes32 tokenIn,bytes32 tokenOut,bytes32 legsHash,uint256 quotedAmountIn,uint256 minAmountOut,uint256 deadline,uint256 nonce)";
const HALF_ORDER: [u8; 32] = [
    0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0x5d, 0x57, 0x6e, 0x73, 0x57, 0xa4, 0x50, 0x1d, 0xdf, 0xe9, 0x2f, 0x46, 0x68, 0x1b, 0x20, 0xa0,
];

#[error_code(offset = 7600)]
pub enum QuoteError {
    InvalidSignature,
    Expired,
    Replay,
    InvalidQuote,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct SignedQuote {
    pub fund: Pubkey,
    pub token_in: Pubkey,
    pub token_out: Pubkey,
    pub legs_hash: [u8; 32],
    pub quoted_amount_in: u64,
    pub min_amount_out: u64,
    pub deadline: u64,
    pub nonce: u64,
    pub signature: [u8; 65],
}

pub struct QuoteDomain {
    pub chain_id: u64,
    pub verifying_contract: [u8; 20],
    pub program: Pubkey,
}

fn word(value: u64) -> [u8; 32] {
    let mut encoded = [0u8; 32];
    encoded[24..].copy_from_slice(&value.to_be_bytes());
    encoded
}

/// DEC-202: preserve EVM route fields, with full-width mints and explicit Fund/nonce.
pub fn digest(quote: &SignedQuote, domain: &QuoteDomain) -> [u8; 32] {
    let mut contract = [0u8; 32];
    contract[12..].copy_from_slice(&domain.verifying_contract);
    // TODO(decision): approve the Solana EIP-712 domain extension; sealed at creation.
    let domain_hash = keccak::hash(&[
        keccak::hash(b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)").to_bytes(),
        keccak::hash(b"Pool Party Swap Adapter").to_bytes(),
        keccak::hash(b"2").to_bytes(), word(domain.chain_id), contract, domain.program.to_bytes(),
    ].concat()).to_bytes();
    let struct_hash = keccak::hash(&[
        keccak::hash(QUOTE_TYPE.as_bytes()).to_bytes(), quote.fund.to_bytes(),
        quote.token_in.to_bytes(), quote.token_out.to_bytes(), quote.legs_hash,
        word(quote.quoted_amount_in), word(quote.min_amount_out), word(quote.deadline), word(quote.nonce),
    ].concat()).to_bytes();
    keccak::hashv(&[b"\x19\x01", &domain_hash, &struct_hash]).to_bytes()
}

/// DEC-170, DEC-202: signer/domain/next_nonce come only from authenticated sealed state.
pub fn verify(
    quote: &SignedQuote, domain: &QuoteDomain, signer: &[u8; 20], fund: &Pubkey,
    route_hash: &[u8; 32], next_nonce: u64, now: i64,
) -> Result<u64> {
    require!(now >= 0 && now as u64 <= quote.deadline, QuoteError::Expired);
    require!(quote.nonce == next_nonce, QuoteError::Replay);
    require!(*signer != [0; 20] && quote.fund == *fund && quote.legs_hash == *route_hash
        && quote.token_in != quote.token_out && quote.quoted_amount_in > 0
        && quote.min_amount_out > 0, QuoteError::InvalidQuote);
    let scalar: [u8; 32] = quote.signature[32..64].try_into().unwrap();
    require!(scalar != [0; 32] && scalar <= HALF_ORDER
        && matches!(quote.signature[64], 27 | 28), QuoteError::InvalidSignature);
    let recovered = secp256k1_recover(&digest(quote, domain), quote.signature[64] - 27, &quote.signature[..64])
        .map_err(|_| error!(QuoteError::InvalidSignature))?;
    require!(keccak::hash(&recovered.to_bytes()).to_bytes()[12..] == *signer, QuoteError::InvalidSignature);
    next_nonce.checked_add(1).ok_or_else(|| error!(QuoteError::Replay))
}

/// DEC-202: bind instruction bytes AND exact ordered CPI privileges, not only a pool label.
pub fn route_hash(data: &[u8], accounts: &[AccountInfo], vault: &Pubkey) -> [u8; 32] {
    let mut wire = Vec::with_capacity(8 + data.len() + accounts.len() * 34);
    wire.extend_from_slice(&(data.len() as u32).to_le_bytes());
    wire.extend_from_slice(data);
    wire.extend_from_slice(&(accounts.len() as u32).to_le_bytes());
    for account in accounts {
        wire.extend_from_slice(account.key.as_ref());
        wire.push(u8::from(account.key == vault));
        wire.push(u8::from(account.is_writable));
    }
    keccak::hash(&wire).to_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn vector() -> (SignedQuote, QuoteDomain, [u8; 20]) {
        let quote = SignedQuote::try_from_slice(include_bytes!("../../../../../tests/swap/fixtures/v2/api-quote.bin")).unwrap();
        let domain = QuoteDomain { chain_id: 42161, verifying_contract: [5; 20], program: Pubkey::new_from_array([77; 32]) };
        let recovered = secp256k1_recover(&digest(&quote, &domain), quote.signature[64] - 27, &quote.signature[..64]).unwrap();
        let signer = keccak::hash(&recovered.to_bytes()).to_bytes()[12..].try_into().unwrap();
        (quote, domain, signer)
    }
    #[test]
    fn api_signature_expiry_nonce_and_mutations() {
        let (quote, domain, signer) = vector();
        assert_eq!(signer, [0xb0, 0xe5, 0x86, 0x3d, 0x0d, 0xdf, 0x7e, 0x10, 0x5e, 0x40, 0x9f, 0xee, 0x0e, 0xcc, 0x01, 0x23, 0xa3, 0x62, 0xe1, 0x4b]);
        assert_eq!(verify(&quote, &domain, &signer, &quote.fund, &quote.legs_hash, 0, 2000).unwrap(), 1);
        assert!(verify(&quote, &domain, &signer, &quote.fund, &quote.legs_hash, 1, 1000).is_err());
        assert!(verify(&quote, &domain, &signer, &quote.fund, &quote.legs_hash, 0, 2001).is_err());
        assert!(verify(&quote, &domain, &[1; 20], &quote.fund, &quote.legs_hash, 0, 1000).is_err());
        for field in 0..8 {
            let mut changed = quote.clone();
            match field { 0 => changed.fund = Pubkey::new_unique(), 1 => changed.token_in = Pubkey::new_unique(),
                2 => changed.token_out = Pubkey::new_unique(), 3 => changed.legs_hash[0] ^= 1,
                4 => changed.quoted_amount_in += 1, 5 => changed.min_amount_out += 1,
                6 => changed.deadline += 1, _ => changed.nonce += 1 }
            assert!(verify(&changed, &domain, &signer, &quote.fund, &quote.legs_hash, 0, 1000).is_err());
        }
        let mut changed = quote.clone(); changed.signature[64] = 0;
        assert!(verify(&changed, &domain, &signer, &quote.fund, &quote.legs_hash, 0, 1000).is_err());
        changed = quote.clone(); changed.signature[32..64].fill(255);
        assert!(verify(&changed, &domain, &signer, &quote.fund, &quote.legs_hash, 0, 1000).is_err());
    }
}
