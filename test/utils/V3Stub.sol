// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../src/interfaces/IFundFactory.sol";
import {MockV3Factory, MockQuoterV2, MockSwapRouter02} from "../mocks/swap/MockV3.sol";

/// @title V3Stub
/// @notice Wires a fresh set of Uniswap V3 stand-ins (factory, SwapRouter02, QuoterV2, the router and the quoter
///         answering for that factory) into a factory test's protocol wiring, so `createFund` and `createSpoke` can
///         deploy each chain's `UniswapV3SwapAdapter` (DEC-136) without the network.
library V3Stub {
    function wire(IFundFactory.ProtocolWiring memory w) internal returns (MockV3Factory v3) {
        v3 = new MockV3Factory();
        w.uniswapV3Factory = address(v3);
        w.uniswapV3SwapRouter02 = address(new MockSwapRouter02(v3));
        w.uniswapV3QuoterV2 = address(new MockQuoterV2(v3));
    }
}
