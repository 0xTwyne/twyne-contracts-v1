// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

interface IAggregator {
    function decimals() external view returns (uint8);
    function latestAnswer() external view returns (int256);
}


contract MockAaveFeed is IAggregator {

    uint price;

    function setPrice(uint _price) external {
        price = _price;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestAnswer() external view returns (int) {
        return int(price);
    }

}