// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

/// @title MockMorphoOracle
/// @notice Mock oracle for Morpho Blue tests
/// @dev Implements IOracle interface - returns price of collateral in loan token terms
contract MockMorphoOracle {
    uint256 internal _price;

    function setPrice(uint256 newPrice) external {
        _price = newPrice;
    }

    /// @notice Returns the price of 1 asset of collateral token quoted in 1 asset of loan token, scaled by 1e36.
    function price() external view returns (uint256) {
        return _price;
    }
}
