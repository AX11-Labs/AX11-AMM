// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

library FeeTier {
    function getFee(uint256 priceRange, uint128 value) internal pure returns (uint128 feeAmount) {
        uint128 tier;
        if (priceRange <= 32) {
            tier = 10;
        } else if (priceRange <= 64) {
            tier = 50;
        } else if (priceRange <= 128) {
            tier = 100;
        } else if (priceRange <= 256) {
            tier = 200;
        } else if (priceRange <= 512) {
            tier = 300;
        } else if (priceRange <= 1024) {
            tier = 400;
        } else {
            tier = 500;
        }
        feeAmount = (value * tier) / 100_000;
    }
}
