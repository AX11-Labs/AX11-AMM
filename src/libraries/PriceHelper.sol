// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {Uint128x128Math} from "./Math/Uint128x128Math.sol";
import {Uint256x256Math} from "./Math/Uint256x256Math.sol";
import {SafeCast} from "./Math/SafeCast.sol";
import {Constants} from "./Constants.sol";


/**
 * @title Price Helper Library
 * @author Ax11
 * @notice This library contains functions to calculate prices, modified from Trader Joe's Liquidity Book
 */
library PriceHelper {
    using Uint128x128Math for uint256;
    using Uint256x256Math for uint256;

    int256 private constant REAL_ID_SHIFT = 1 << 23;
    uint256  private constant BINSTEP = 10; // 0.01%

    /**
     * @dev Calculates the price from the id and the bin step
     * @param id The id
     * @return price The price as a 128.128-binary fixed-point number
     */
    function getPriceFromId(int id) internal pure returns (uint256 price) {
        uint256 base = getBase();
        price = base.pow(id);
    }

    /**
     * @dev Calculates the id from the price and the bin step
     * @param price The price as a 128.128-binary fixed-point number
     * @return id The id
     */
    function getIdFromPrice(uint256 price) internal pure returns (int id) {
        uint256 base = getBase();
        int256 realId = price.log2() / base.log2();
        id = SafeCast.toInt24(realId);
    }

    /**
     * @dev Calculates the base from the bin step, which is `1 + BINSTEP / BASIS_POINT_MAX`
     * @return base The base
     */
    function getBase() internal pure returns (uint256) {
        unchecked {
            return Constants.SCALE + (BINSTEP << Constants.SCALE_OFFSET) / Constants.BASIS_POINT_MAX;
        }
    }

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
