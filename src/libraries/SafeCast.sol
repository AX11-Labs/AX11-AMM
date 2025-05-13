// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/**
 * @title Liquidity Book Safe Cast Library
 * @author Trader Joe
 * @notice This library contains functions to safely cast uint256 to different uint types.
 */
library SafeCast {
    error SAFECAST_OVERFLOW();
    /**
     * @dev Returns x on uint128 and check that it does not overflow
     * @param x The value as an uint256
     * @return y The value as an uint128
     */

    function safe128(uint256 x) internal pure returns (uint128 y) {
        y = uint128(x);
        require(y == x, SAFECAST_OVERFLOW());
    }

    /**
     * @dev Returns the downcasted int24 from int256, reverting on overflow
     * @param x The value as an int256
     * @return y The value as an int24
     */
    function safeInt24(int256 x) internal pure returns (int24 y) {
        y = int24(x);
        require(y == x, SAFECAST_OVERFLOW());
    }
}
