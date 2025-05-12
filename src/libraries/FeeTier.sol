// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

library FeeTier {
    function getFee(uint256 priceRange, uint256 value) internal pure returns (uint256 feeAmount) {
        uint8 tier;
        uint8 minFee = 1; // 0.001%
        uint8 maxFee = 250; // 0.25%
        uint256 priceRangeAtMinFee = 15;
        uint256 priceRangeAtMaxFee = 255;

        if (priceRange <= priceRangeAtMinFee) {
            tier = minFee;
        } else if (priceRange >= priceRangeAtMaxFee) {
            tier = maxFee;
        } else {
            // Linear interpolation:
            // tier = y0 + (x - x0) * (y1 - y0) / (x1 - x0)
            // tier = minFee + (priceRange - priceRangeAtMinFee) * (maxFee - minFee) / (priceRangeAtMaxFee - priceRangeAtMinFee)
            // Perform calculations using uint256 for intermediate products to prevent overflow, then cast to uint16.
            tier =
                minFee +
                uint8(
                    (((priceRange - priceRangeAtMinFee) * (maxFee - minFee)) /
                        (priceRangeAtMaxFee - priceRangeAtMinFee))
                ); // won't overflow
        }
        feeAmount = ((value * tier) / 100_000);
    }
}
