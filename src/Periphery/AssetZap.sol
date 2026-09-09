// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {IERC4626} from "openzeppelin-contracts/interfaces/IERC4626.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {SafeERC20Lib, IERC20 as IERC20_Euler} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";

interface ISwapper {
    function multicall(bytes[] memory calls) external;
}

/// @notice Zap any asset into a Twyne vault (intermediate or collateral) in a single transaction.
/// @dev Airdrop model: the zap acquires `vaultAsset` (the token the destination's `skim()` absorbs)
///      and transfers it straight to the destination address. It deliberately does NOT call the
///      destination — the EVC batch is responsible for calling `skim()` afterwards.
///
///      `vaultAsset` is always `destination.asset()` (derived internally, not a caller parameter):
///        - Euler IV / Aave CV / Euler CV: an ERC4626 (wrapper / inner vault). The swap route must
///          produce wrapper shares — e.g. a Generic-handler item that transfers the underlying to the
///          wrapper address and calls `wrapper.skim(type(uint).max, address(this))`.
///        - Morpho CV: a plain ERC20 (the collateral token). The swap route produces it directly.
///
///      The caller constructs the swap route so that `vaultAsset` lands at this contract. Three modes,
///      inferred from the inputs (no explicit flag):
///        - Direct: `tokenIn == vaultAsset`, empty swapData → pull and transfer.
///        - Swap: non-empty swapData → route `tokenIn` → `vaultAsset` via SWAPPER.
///        - Airdrop: `amountIn == 0` → skip the pull; transfer whatever this contract already holds
///          (e.g. delivered by a preceding value-carrying EVC batch item).
contract AssetZap is ReentrancyGuardTransient, EVCUtil, IErrors, IEvents {
    using SafeERC20 for IERC20;

    address internal constant permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address public immutable SWAPPER;

    constructor(address _evc, address _swapper) EVCUtil(_evc) {
        SWAPPER = _swapper;
    }

    /// @notice Zap any asset into a Twyne vault.
    /// @dev Only ERC-20 inputs are accepted. Native ETH must be wrapped upstream — e.g. by a value-carrying
    ///      EVC batch item calling `WstethHandler.wrapETH` to deliver WETH/wstETH to this contract — and then
    ///      zapped with `amountIn == 0` (airdrop mode).
    /// @param tokenIn Input token (ERC-20). When `tokenIn == vaultAsset` and swapData is empty, the zap
    ///        pulls and transfers directly (no swap, no wrapping).
    /// @param amountIn Amount of tokenIn to zap. `amountIn == 0` selects airdrop mode (skip pull).
    /// @param swapData SWAPPER.multicall payload. The route must deliver `vaultAsset` to this contract.
    ///        Empty when `tokenIn == vaultAsset` (direct transfer, no swap).
    /// @param destination Address of the vault (intermediate or collateral).
    /// @param minAmountOut Minimum amount of vaultAsset transferred to the destination.
    /// @return amountOut Amount of vaultAsset transferred to the destination.
    function zap(
        address tokenIn,
        uint amountIn,
        bytes[] calldata swapData,
        address destination,
        uint minAmountOut
    ) external nonReentrant returns (uint amountOut) {
        // vaultAsset is the token destination.skim() absorbs; always destination.asset().
        address vaultAsset = IERC4626(destination).asset();
        address sender = _msgSender();

        // 1. Pull input asset. amountIn == 0 skips the pull and uses whatever this contract already holds.
        if (amountIn != 0) {
            SafeERC20Lib.safeTransferFrom(IERC20_Euler(tokenIn), sender, address(this), amountIn, permit2);
        }

        // 2. Acquire vaultAsset via SWAPPER if a swap route is provided.
        if (swapData.length != 0) {
            require(tokenIn != vaultAsset, T_InputIsUnderlying());
            IERC20(tokenIn).safeTransfer(SWAPPER, IERC20(tokenIn).balanceOf(address(this)));
            ISwapper(SWAPPER).multicall(swapData);
        }

        // 3. Transfer the full vaultAsset balance to the destination (airdrop). The EVC batch calls skim.
        amountOut = IERC20(vaultAsset).balanceOf(address(this));
        IERC20(vaultAsset).safeTransfer(destination, amountOut);

        require(amountOut >= minAmountOut, T_MinAmountOut());

        // 4. Sweep residual input back to the caller.
        uint rest = IERC20(tokenIn).balanceOf(address(this));
        if (rest != 0) IERC20(tokenIn).safeTransfer(sender, rest);

        emit T_AssetZap(sender, destination, tokenIn, amountIn, amountOut);
    }

    /// @notice Zap a wrapper's underlying token into a Twyne vault in one call — no SWAPPER route needed.
    /// @dev Convenience for the common case where `tokenIn` is the underlying of `destination.asset()`
    ///      (the wrapper / inner vault). Pulls (or, in airdrop mode, uses a pre-funded balance of) `tokenIn`,
    ///      deposits it into the wrapper to mint wrapper shares at this contract, and airdrops those shares
    ///      to the destination — same model as `zap`, with the wrap done internally instead of via SWAPPER.
    ///      The EVC batch then calls `destination.skim()` to mint vault shares.
    ///      `vaultAsset = destination.asset()` must be an ERC4626 whose `asset()` is `tokenIn`
    ///      (reverts with T_NotUnderlying otherwise). Only ERC-20 inputs; native ETH must be wrapped
    ///      upstream and zapped with `amountIn == 0`.
    /// @param tokenIn The wrapper's underlying token (e.g. WETH, wstETH). NOT the wrapper itself.
    /// @param amountIn Amount of tokenIn to zap. `0` selects airdrop mode (skip the pull).
    /// @param destination Address of the vault (intermediate or collateral) whose `asset()` is the wrapper.
    /// @param minAmountOut Minimum wrapper shares transferred to the destination.
    /// @return amountOut Wrapper shares transferred to the destination.
    function zapUnderlying(
        address tokenIn,
        uint amountIn,
        address destination,
        uint minAmountOut
    ) external nonReentrant returns (uint amountOut) {
        address vaultAsset = IERC4626(destination).asset();
        require(IERC4626(vaultAsset).asset() == tokenIn, T_NotUnderlying());
        address sender = _msgSender();

        // 1. Pull input asset (airdrop mode when amountIn == 0).
        if (amountIn != 0) {
            SafeERC20Lib.safeTransferFrom(IERC20_Euler(tokenIn), sender, address(this), amountIn, permit2);
        }

        // 2. Wrap the full underlying balance into wrapper shares at this contract.
        uint balance = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(vaultAsset, balance);
        IERC4626(vaultAsset).deposit(balance, address(this));

        // 3. Airdrop wrapper shares to the destination; the EVC batch calls skim.
        amountOut = IERC20(vaultAsset).balanceOf(address(this));
        IERC20(vaultAsset).safeTransfer(destination, amountOut);
        require(amountOut >= minAmountOut, T_MinAmountOut());

        emit T_AssetZap(sender, destination, tokenIn, amountIn, amountOut);
    }
}
