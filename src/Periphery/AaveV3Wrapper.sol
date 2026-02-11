// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
// Using IEVault to represent the Intermediate Vault interface (as it's used in the original structure)
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {SafeERC20Lib, IERC20 as IERC20_Euler} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
// Import Aave V3 Interfaces
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";
import {IAaveV3ATokenWrapper} from "src/interfaces/IAaveV3ATokenWrapper.sol";

// Interfaces needed for WETH interaction
interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title AaveV3Wrapper
contract AaveV3Wrapper is EVCUtil, IErrors {
    using SafeERC20 for IERC20;

    address internal constant permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address internal immutable WETH;

    /// @param _evc address of EVC deployed by Twyne
    /// @param _WETH WETH token address
    constructor(
        address _evc,
        address _WETH
    ) EVCUtil(_evc) {
        WETH = _WETH;
    }

    /// @notice Deposits underlying token into Aave V3 Pool, then deposits the resulting aToken shares into Twyne's Intermediate Vault
    /// @param intermediateVault The intermediate vault (IEVault) to deposit the aToken shares into
    /// @param amount The amount of underlying token to deposit
    /// @return sharesReceived The amount of shares received from the intermediate vault
    function depositUnderlyingToIntermediateVault(
        IEVault intermediateVault,
        uint amount
    ) external returns (uint sharesReceived) {
        address msgSender = _msgSender();

        address aTokenWrapper = intermediateVault.asset();
        address underlyingAsset = IAaveV3ATokenWrapper(aTokenWrapper).asset();

        SafeERC20Lib.safeTransferFrom(IERC20_Euler(underlyingAsset), msgSender, address(this), amount, permit2);
        IERC20(underlyingAsset).forceApprove(aTokenWrapper, amount);

        uint shares = IAaveV3ATokenWrapper(aTokenWrapper).deposit(amount, address(intermediateVault));
        sharesReceived = intermediateVault.skim(shares, msgSender);
    }

    /// @notice Deposits ETH into Aave Pool (wrapping to WETH first), then deposits the resulting aToken shares into intermediate vault
    /// @param intermediateVault The intermediate vault (IEVault) to deposit the aToken shares into (must accept aWETH)
    /// @return sharesReceived The amount of shares received from the intermediate vault
    function depositETHToIntermediateVault(
        IEVault intermediateVault
    ) external payable returns (uint sharesReceived) {
        address msgSender = _msgSender();
        uint ethAmount = msg.value;
        address aTokenWrapper = intermediateVault.asset();
        address underlyingAsset = IAaveV3ATokenWrapper(aTokenWrapper).asset();

        require(underlyingAsset == WETH, OnlyWETH());

        IWETH(WETH).deposit{value: ethAmount}();
        IERC20(WETH).forceApprove(aTokenWrapper, ethAmount);

        uint shares = IAaveV3ATokenWrapper(aTokenWrapper).deposit(ethAmount, address(intermediateVault));
        sharesReceived = intermediateVault.skim(shares, msgSender);
    }
}