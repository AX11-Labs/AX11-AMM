// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

library FeeTier {
    function getFee(uint256 priceRange, uint128 value) internal pure returns (uint128 feeAmount) {
        uint128 tier;
        if (priceRange < 63) {
            // 32x32
            tier = 5; // 0.005%
        } else if (priceRange < 127) {
            // 64x64
            tier = 10; // 0.01%
        } else if (priceRange < 255) {
            // 128x128
            tier = 50; // 0.05%
        } else if (priceRange < 511) {
            // 256x256
            tier = 100; // 0.1%
        } else {
            // 512x512
            tier = 250; // 0.25%
        }
        feeAmount = (value * tier) / 100_000;
    }
}
