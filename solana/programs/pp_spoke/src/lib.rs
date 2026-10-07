#![allow(unexpected_cfgs)]

use anchor_lang::prelude::*;

pub mod constants;
pub mod errors;
pub mod events;
pub mod instructions;
pub mod state;
pub use instructions::cctp::*;
pub use instructions::core::*;
pub use instructions::kamino::*;
pub use instructions::raydium::*;
pub use instructions::report::*;
pub use instructions::swap::*;

declare_id!("Fg6PaFpoGXkYsidMpWxTWqkZ7FEfcYkgMQHGfVNLusVw");

#[program]
pub mod pp_spoke {
    use super::*;

    /// DEC-188, DEC-190, DEC-195: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn initialize_fund(ctx: Context<InitializeFund>, payload: Vec<u8>) -> Result<()> {
        instructions::core::initialize_fund::handler(ctx, payload)
    }

    /// DEC-190, DEC-193: materialize only a sealed adapter admission.
    pub fn initialize_adapter(ctx: Context<InitializeAdapter>, payload: Vec<u8>) -> Result<()> {
        instructions::core::initialize_adapter::handler(ctx, payload)
    }

    /// DEC-188, DEC-190, DEC-195: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn sweep_excess(ctx: Context<SweepExcess>, payload: Vec<u8>) -> Result<()> {
        instructions::core::sweep_excess::handler(ctx, payload)
    }

    /// DEC-188, DEC-190, DEC-195: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn collect_income_all(ctx: Context<CollectIncomeAll>, payload: Vec<u8>) -> Result<()> {
        instructions::core::collect_income_all::handler(ctx, payload)
    }

    /// DEC-188, DEC-190, DEC-195: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn refresh_income_results(
        ctx: Context<RefreshIncomeResults>,
        payload: Vec<u8>,
    ) -> Result<()> {
        instructions::core::refresh_income_results::handler(ctx, payload)
    }

    /// DEC-191: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn send_to_hub(ctx: Context<SendToHub>, payload: Vec<u8>) -> Result<()> {
        instructions::cctp::send_to_hub::handler(ctx, payload)
    }

    /// DEC-191: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn receive_and_credit(ctx: Context<ReceiveAndCredit>, payload: Vec<u8>) -> Result<()> {
        instructions::cctp::receive_and_credit::handler(ctx, payload)
    }

    /// DEC-191: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn retry_receive(ctx: Context<RetryReceive>, payload: Vec<u8>) -> Result<()> {
        instructions::cctp::retry_receive::handler(ctx, payload)
    }

    /// DEC-191: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn recognize_refund(ctx: Context<RecognizeRefund>, payload: Vec<u8>) -> Result<()> {
        instructions::cctp::recognize_refund::handler(ctx, payload)
    }

    /// DEC-093, DEC-120, DEC-121, DEC-122, DEC-192: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn build_report(ctx: Context<BuildReport>, payload: Vec<u8>) -> Result<()> {
        instructions::report::build_report::handler(ctx, payload)
    }

    /// DEC-093, DEC-120, DEC-121, DEC-122, DEC-192: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn publish_report(ctx: Context<PublishReport>, payload: Vec<u8>) -> Result<()> {
        instructions::report::publish_report::handler(ctx, payload)
    }

    /// DEC-093, DEC-120, DEC-121, DEC-122, DEC-192: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn execute_order(ctx: Context<ExecuteOrder>, payload: Vec<u8>) -> Result<()> {
        instructions::report::execute_order::handler(ctx, payload)
    }

    /// DEC-120/122/151: resume one authenticated command step without dropping pending custody.
    pub fn resume_command<'info>(ctx: Context<'_, '_, '_, 'info, ResumeCommand<'info>>, payload: Vec<u8>) -> Result<()> {
        instructions::report::resume_command::handler(ctx, payload)
    }

    /// DEC-093, DEC-120, DEC-121, DEC-122, DEC-192: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn execute_unwind_order<'info>(ctx: Context<'_, '_, '_, 'info, ExecuteUnwindOrder<'info>>, payload: Vec<u8>) -> Result<()> {
        instructions::report::execute_unwind_order::handler(ctx, payload)
    }

    /// DEC-093, DEC-120, DEC-121, DEC-122, DEC-192: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn execute_close_order<'info>(ctx: Context<'_, '_, '_, 'info, ExecuteCloseOrder<'info>>, payload: Vec<u8>) -> Result<()> {
        instructions::report::execute_close_order::handler(ctx, payload)
    }

    /// DEC-093, DEC-120, DEC-121, DEC-122, DEC-192: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn execute_collect_order<'info>(
        ctx: Context<'_, '_, '_, 'info, ExecuteCollectOrder<'info>>,
        payload: Vec<u8>,
    ) -> Result<()> {
        instructions::report::execute_collect_order::handler(ctx, payload)
    }

    /// DEC-068, DEC-193: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn kamino_supply(ctx: Context<KaminoSupply>, payload: Vec<u8>) -> Result<()> {
        instructions::kamino::kamino_supply::handler(ctx, payload)
    }

    /// DEC-068, DEC-193: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn kamino_redeem(ctx: Context<KaminoRedeem>, payload: Vec<u8>) -> Result<()> {
        instructions::kamino::kamino_redeem::handler(ctx, payload)
    }

    /// DEC-068, DEC-193: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn kamino_refresh(ctx: Context<KaminoRefresh>, payload: Vec<u8>) -> Result<()> {
        instructions::kamino::kamino_refresh::handler(ctx, payload)
    }

    /// DEC-068, DEC-193: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn kamino_collect_income(
        ctx: Context<KaminoCollectIncome>,
        payload: Vec<u8>,
    ) -> Result<()> {
        instructions::kamino::kamino_collect_income::handler(ctx, payload)
    }

    /// DEC-193, DEC-194: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn raydium_open_position(
        ctx: Context<RaydiumOpenPosition>,
        payload: Vec<u8>,
    ) -> Result<()> {
        instructions::raydium::raydium_open_position::handler(ctx, payload)
    }

    /// DEC-193, DEC-194: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn raydium_increase_position(
        ctx: Context<RaydiumIncreasePosition>,
        payload: Vec<u8>,
    ) -> Result<()> {
        instructions::raydium::raydium_increase_position::handler(ctx, payload)
    }

    /// DEC-193, DEC-194: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn raydium_decrease_position(
        ctx: Context<RaydiumDecreasePosition>,
        payload: Vec<u8>,
    ) -> Result<()> {
        instructions::raydium::raydium_decrease_position::handler(ctx, payload)
    }

    /// DEC-193, DEC-194: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn raydium_close_position(
        ctx: Context<RaydiumClosePosition>,
        payload: Vec<u8>,
    ) -> Result<()> {
        instructions::raydium::raydium_close_position::handler(ctx, payload)
    }

    /// DEC-193, DEC-194: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn raydium_collect_fees(ctx: Context<RaydiumCollectFees>, payload: Vec<u8>) -> Result<()> {
        instructions::raydium::raydium_collect_fees::handler(ctx, payload)
    }

    /// DEC-136, DEC-193: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn swap_exact_in(ctx: Context<SwapExactIn>, payload: Vec<u8>) -> Result<()> {
        instructions::swap::swap_exact_in::handler(ctx, payload)
    }

    /// DEC-136, DEC-193: fail-closed track-owned scaffold; payload is not a stable wire API.
    pub fn swap_to_ratio<'info>(ctx: Context<'_, '_, '_, 'info, SwapToRatio<'info>>, payload: Vec<u8>) -> Result<()> {
        instructions::swap::swap_to_ratio::handler(ctx, payload)
    }
}
