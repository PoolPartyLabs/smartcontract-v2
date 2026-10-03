pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

library ClosureDust {
    function threshold(address token) internal view returns (uint256) {
        return 10 ** IERC20Metadata(token).decimals() / 2;
    }
}
