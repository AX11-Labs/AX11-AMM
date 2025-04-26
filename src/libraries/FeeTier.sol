// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

library FeeTier {
    function getFee(uint256 priceRange, uint128 value) internal pure returns (uint128 feeAmount) {
        uint128 tier;
        if (priceRange <= 32) {
            tier = 5; // 0.005%
        } else if (priceRange <= 64) {
            tier = 10; // 0.01%
        } else if (priceRange <= 128) {
            tier = 50; // 0.05%
        } else if (priceRange <= 256) {
            tier = 100; // 0.1%
        } else if (priceRange <= 512) {
            tier = 200; // 0.2%
        } else if (priceRange <= 1024) {
            tier = 300; // 0.3%
        } else {
            tier = 500; // 0.5%
        }
        feeAmount = (value * tier) / 100_000;
    }
}
