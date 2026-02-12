// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseAdapter} from "euler-price-oracle/src/adapter/BaseAdapter.sol";
import {USD} from "euler-price-oracle/test/utils/EthereumAddresses.sol";
import {IAaveV3ATokenWrapper} from "src/interfaces/IAaveV3ATokenWrapper.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {IERC20} from "euler-vault-kit/EVault/IEVault.sol";
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";
import {IAaveOracle} from "aave-v3/interfaces/IAaveOracle.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";

/// @title AaveV3ATokenWrapperOracle
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @notice PriceOracle adapter for AaveV3ATokenWrapper shares
contract AaveV3ATokenWrapperOracle is BaseAdapter, IErrors {
    string public constant name = "AaveV3WrapperOracle";
    uint public immutable tenPowQuoteDecimals;
    uint public immutable feedDecimals;
    address public immutable aavePool;

    constructor(uint _feedDecimals, address _aavePool) {
        tenPowQuoteDecimals = 10 ** uint(_getDecimals(USD));
        feedDecimals = _feedDecimals;
        aavePool = _aavePool;
    }

    /// @notice Checks if an AaveV3ATokenWrapper asset is supported by verifying the feed decimals match expected value.
    /// @param _base The AaveV3ATokenWrapper address to check for support.
    /// @return Returns true if the asset's feed decimals are correct.
    /// @dev Reverts if the feed decimals don't match the expected feedDecimals.
    function isAssetSupported(address _base) external view returns (bool) {
        address underlyingAsset = IAaveV3ATokenWrapper(_base).asset();

        address oracle = IAaveV3Pool(aavePool).ADDRESSES_PROVIDER().getPriceOracle();
        address feed = IAaveOracle(oracle).getSourceOfAsset(underlyingAsset);

        require(uint(IERC20(feed).decimals()) == feedDecimals, T_FeedDecimalsNotCorrect());
        return true;
    }

    /// @notice Get the quote from the AaveV3ATokenWrapper oracle.
    /// @dev Inpired from euler-price-oracle's ChainlinkOracle.sol
    /// @param inAmount The amount of `base` to convert.
    /// @param _base The token that is being priced (aave wrapper share).
    /// @param _quote The token that is the unit of account.
    /// @return The converted amount using the Chainlink feed.
    function _getQuote(uint inAmount, address _base, address _quote) internal view override returns (uint) {
        require(_quote == USD, T_QuoteNotUSD());
        uint baseDecimals = IERC20(_base).decimals();

        // int can be converted to uint safely since
        // wrapper converts uint to int before returning.
        uint price = uint(IAaveV3ATokenWrapper(_base).latestAnswer());
        // When inverse is false
        // amount * price * priceScale(= 10 ** quoteDecimals) / feedScale(= 10 ** (baseDecimals+feedDecimals))
        // Using fullMulDiv for overflow protection like ChainlinkOracle
        return FixedPointMathLib.fullMulDiv(inAmount, tenPowQuoteDecimals * price, 10**(feedDecimals + baseDecimals));
    }
}
