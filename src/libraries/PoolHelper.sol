// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

library PoolHelper {
    error INVALID_ADDRESS();

    function sortToken(address token0, address token1) internal pure returns (address tokenA, address tokenB) {
        if (token0 < token1) {
            tokenA = token0;
            tokenB = token1;
        } else if (token0 > token1) {
            tokenA = token1;
            tokenB = token0;
        } else {
            revert INVALID_ADDRESS();
        }
    }

    function hashToken(address token0, address token1) internal pure returns (uint256 pool) {
        pool = uint256(keccak256(abi.encodePacked(token0, token1)));
    }
}
