// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {SafeERC20Lib, IERC20 as IERC20_Euler} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {IErrors} from "src/interfaces/IErrors.sol";

interface IWETH {
    function deposit() external payable;
}

/// @title ReferenceEulerWrapper - Old implementation for comparison
contract ReferenceEulerWrapper is EVCUtil, IErrors {
    using SafeERC20 for IERC20;

    address internal constant permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal immutable WETH;

    /// @param _evc address of EVC deployed by Twyne
    constructor(address _evc, address _WETH) EVCUtil(_evc) {
        WETH = _WETH;
    }

    /// @notice Deposits underlying token into Euler vault, then deposits the resulting shares into intermediate vault
    /// @param intermediateVault The intermediate vault to deposit the Euler vault shares into
    /// @param amount The amount of underlying token to deposit
    /// @return sharesReceived The amount of shares received from the intermediate vault
    function depositUnderlyingToIntermediateVault(
        IEVault intermediateVault,
        uint256 amount
    ) external callThroughEVC returns (uint256 sharesReceived) {
        address msgSender = _msgSender();

        IEVault eulerVault = IEVault(intermediateVault.asset());
        address underlyingToken = eulerVault.asset();

        // Transfer underlying token from caller to this contract
        SafeERC20Lib.safeTransferFrom(IERC20_Euler(underlyingToken), msgSender, address(this), amount, permit2);

        // Approve Euler vault to spend underlying token
        IERC20(underlyingToken).forceApprove(address(eulerVault), amount);

        // Deposit underlying token into Euler vault and receive Euler vault shares
        uint256 eulerShares = eulerVault.deposit(amount, address(this));

        // Approve intermediate vault to spend Euler vault shares
        IERC20(address(eulerVault)).approve(address(intermediateVault), eulerShares);

        // Deposit Euler vault shares into intermediate vault
        sharesReceived = intermediateVault.deposit(eulerShares, msgSender);
    }

    /// @notice Deposits ETH into Euler vault (wrapping to WETH first), then deposits the resulting shares into intermediate vault
    /// @param intermediateVault The intermediate vault to deposit the Euler vault shares into (must accept WETH-based Euler vault shares)
    /// @return sharesReceived The amount of shares received from the intermediate vault
    function depositETHToIntermediateVault(
        IEVault intermediateVault
    ) external payable callThroughEVC returns (uint256 sharesReceived) {
        address msgSender = _msgSender();
        uint256 ethAmount = msg.value;

        IEVault eulerVault = IEVault(intermediateVault.asset());
        address underlyingToken = eulerVault.asset();

        require(underlyingToken == WETH, OnlyWETH());
        IWETH(WETH).deposit{value: ethAmount}();

        IERC20(WETH).approve(address(eulerVault), ethAmount);

        uint256 eulerShares = eulerVault.deposit(ethAmount, address(this));
        IERC20(address(eulerVault)).approve(address(intermediateVault), eulerShares);
        sharesReceived = intermediateVault.deposit(eulerShares, msgSender);
    }
}