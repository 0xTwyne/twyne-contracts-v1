// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockSwapper is Test {
    function swap(
        address tokenIn,
        address tokenOut,
        uint amountIn,
        uint minAmountOut,
        address receiver
    ) external {
        deal(tokenOut, address(this), minAmountOut + 10);
        IERC20(tokenOut).transfer(receiver, minAmountOut + 10);
    }
}