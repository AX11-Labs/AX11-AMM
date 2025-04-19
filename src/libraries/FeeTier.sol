// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

library FeeTier {
    function getFee(uint256 priceRange, uint128 value) internal pure returns (uint128 feeAmount) {
        uint8 tier;
        if (priceRange < 65) {
            tier = 10;
        } else if (priceRange < 129) {
            tier = 15;
        } else if (priceRange < 193) {
            tier = 20;
        } else if (priceRange < 257) {
            tier = 25;
        } else if (priceRange < 321) {
            tier = 30;
        } else if (priceRange < 385) {
            tier = 35;
        } else if (priceRange < 449) {
            tier = 40;
        } else if (priceRange < 513) {
            tier = 45;
        } else {
            tier = 50;
        }
        feeAmount = (value * tier) / 10_000;
    }
}
