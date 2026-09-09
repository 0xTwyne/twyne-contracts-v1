// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IErrors} from "src/interfaces/IErrors.sol";

interface IWETH {
    function withdraw(uint wad) external;
}

/// @notice Converts ETH/WETH to a wrapped receipt token and transfers it to a receiver.
///         Swap handlers for Zappers:
///         - `wrapETH`: a value-carrying EVC batch item preceding the zap. The batch wraps ETH to the
///           caller-specified `wrapper` (e.g. WETH or WSTETH, any contract that accepts ETH via its fallback
///           and mints an ERC-20 balance to the caller) and transfers it to AssetZap; the next batch item
///           calls `zap` with `amountIn == 0` to deposit it.
///         - `wrapWETH`: a Generic-handler target for the EVK Swapper to swap WETH to WSTETH.
contract WstethHandler is IErrors {
    address public immutable WETH;
    address public immutable WSTETH;

    constructor(address _weth, address _wsteth) {
        WETH = _weth;
        WSTETH = _wsteth;
    }

    /// @notice Wraps ETH to `wrapper` and transfers the minted tokens to `to`.
    /// @dev `wrapper` must accept ETH via its fallback and mint an ERC-20 balance to the caller (e.g. WETH,
    ///      WSTETH). Usable as a value-carrying EVC batch item: `{target: handler, value: X, data: wrapETH(zap, wrapper)}`.
    /// @return amount tokens transferred to `to`
    function wrapETH(address to, address wrapper) external payable returns (uint amount) {
        require(wrapper == WETH || wrapper == WSTETH, T_InvalidWrapper());
        (bool success,) = wrapper.call{value: msg.value}("");
        require(success, T_StakeFailed());
        amount = IERC20(wrapper).balanceOf(address(this));
        IERC20(wrapper).transfer(to, amount);
    }

    /// @notice Converts WETH to WSTETH and transfers it to `to`.
    /// @dev Generic-handler payload: `abi.encodeCall(this.wrapWETH, (amountIn, address(zap)))`.
    /// @return amount wstETH transferred
    function wrapWETH(uint amountIn, address to) external returns (uint amount) {
        IERC20(WETH).transferFrom(msg.sender, address(this), amountIn);
        IWETH(WETH).withdraw(amountIn);
        (bool success,) = WSTETH.call{value: amountIn}("");
        require(success, T_StakeFailed());
        amount = IERC20(WSTETH).balanceOf(address(this));
        IERC20(WSTETH).transfer(to, amount);
    }

    /// @dev for WETH.withdraw
    receive() external payable {}
}
