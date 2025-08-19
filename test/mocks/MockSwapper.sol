// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract MockSwapper {
    function swap(
        address tokenIn,
        address tokenOut,
        uint amountIn,
        uint minAmountOut,
        address receiver
    ) external {
        IERC20(tokenOut).transfer(receiver, minAmountOut + 10);
    }

    function multicall(bytes[] memory calls) external {
        for (uint256 i; i < calls.length; i++) {
            (bool success, ) = address(this).call(calls[i]);
            require(success, "multicall reverted");
        }
    }
}