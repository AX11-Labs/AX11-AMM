// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {Uint256x256Math} from "./Math/Uint256x256Math.sol";
import {Constants} from "./Constants.sol";

/**
 * @title Price Helper Library
 * @author Ax11
 * @notice This library contains functions to calculate prices, modified from Trader Joe's Liquidity Book
 */
library PriceHelper {
    using Uint256x256Math for uint256;
    /**
     * @dev Converts a price with 18 decimals to a 128.128-binary fixed-point number
     * @param price The price with 18 decimals
     * @return price128x128 The 128.128-binary fixed-point number
     */

    function convertDecimalPriceTo128x128(uint256 price) internal pure returns (uint256) {
        return price.shiftDivRoundDown(Constants.SCALE_OFFSET, Constants.PRECISION);
    }

    /**
     * @dev Converts a 128.128-binary fixed-point number to a price with 18 decimals
     * @param price128x128 The 128.128-binary fixed-point number
     * @return price The price with 18 decimals
     */
    function convert128x128PriceToDecimal(uint256 price128x128) internal pure returns (uint256) {
        return price128x128.mulShiftRoundDown(Constants.PRECISION, Constants.SCALE_OFFSET);
    }
}
