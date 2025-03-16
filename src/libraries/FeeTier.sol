// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

library FeeTier {
    function getFee(
        uint256 priceRange,
        uint256 value
    ) internal pure returns (uint256 feeAmount) {
        if (priceRange < 65) {
            feeAmount = value * 10;
        } else if (priceRange < 129) {
            feeAmount = value * 15;
        } else if (priceRange < 193) {
            feeAmount = value * 20;
        } else if (priceRange < 257) {
            feeAmount = value * 25;
        } else if (priceRange < 321) {
            feeAmount = value * 30;
        } else if (priceRange < 385) {
            feeAmount = value * 35;
        } else if (priceRange < 449) {
            feeAmount = value * 40;
        } else if (priceRange < 513) {
            feeAmount = value * 45;
        } else {
            feeAmount = value * 50;
        }
        feeAmount /= 10000;
    }
}
