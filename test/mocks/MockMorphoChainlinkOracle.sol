// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

contract MockMorphoChainlinkOracle {
    uint public price;

    function setPrice(uint _price) external {
        price = _price;
    }
}
