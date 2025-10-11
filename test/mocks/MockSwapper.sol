// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20Lib, IERC20 as IERC20_Euler} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";

contract MockSwapper {
    function swap(
        address tokenIn,
        address tokenOut,
        uint amountIn,
        uint minAmountOut,
        address receiver
    ) external {
        SafeERC20Lib.safeTransfer(IERC20_Euler(tokenOut), receiver, minAmountOut + 10);
    }

    function sweep(address token, uint256 amountMin, address to) external {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance >= amountMin) {
            SafeERC20Lib.safeTransfer(IERC20_Euler(token), to, balance);
        }
    }

    function multicall(bytes[] memory calls) external {
        for (uint256 i; i < calls.length; i++) {
            (bool success, ) = address(this).call(calls[i]);
            require(success, "multicall reverted");
        }
    }
}