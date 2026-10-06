pub mod send_to_hub;
pub use send_to_hub::SendToHub;
pub(crate) use send_to_hub::__client_accounts_send_to_hub;
pub mod receive_and_credit;
pub use receive_and_credit::ReceiveAndCredit;
pub(crate) use receive_and_credit::__client_accounts_receive_and_credit;
pub mod retry_receive;
pub use retry_receive::RetryReceive;
pub(crate) use retry_receive::__client_accounts_retry_receive;
pub mod recognize_refund;
pub use recognize_refund::RecognizeRefund;
pub(crate) use recognize_refund::__client_accounts_recognize_refund;
pub mod cpi;
pub mod wire;

use anchor_lang::prelude::*;

#[error_code]
pub enum CctpError {
    #[msg("Malformed CCTP instruction payload")]
    InvalidPayload,
    #[msg("CCTP route is not sealed against this Fund Mandate")]
    UnsealedRoute,
    #[msg("Manager authorization required")]
    Unauthorized,
    #[msg("Invalid or overflowing CCTP amount")]
    InvalidAmount,
    #[msg("CCTP fee exceeds the sealed ceiling")]
    FeeCapExceeded,
    #[msg("Invalid CCTP message version, domain, length, nonce or finality")]
    InvalidMessage,
    #[msg("Wrong CCTP message sender")]
    WrongSender,
    #[msg("Wrong CCTP recipient")]
    WrongRecipient,
    #[msg("Wrong destination caller")]
    WrongCaller,
    #[msg("Wrong native USDC mint")]
    WrongMint,
    #[msg("Invalid Fund business transit hook")]
    InvalidHook,
    #[msg("Invalid Circle CPI account relation")]
    InvalidAccount,
    #[msg("Mint or burn delta does not match the authenticated message")]
    WrongDelta,
    #[msg("Insufficient recognized principal")]
    InsufficientPrincipal,
}

#[event]
pub struct CctpTransitRecorded {
    pub fund: Pubkey,
    pub transit_id: [u8; 32],
    pub outbound: bool,
    pub amount: u64,
    pub max_fee: u64,
    pub credited: u64,
}
