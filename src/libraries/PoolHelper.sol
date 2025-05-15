// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

library PoolHelper {
    error INVALID_BIN_ID();

    function checkBinIdLimit(int24 value) internal pure {
        require(value >= -44405 && value <= 44405, INVALID_BIN_ID());
    }

    function computePoolId(address _tokenX, address _tokenY) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_tokenX, _tokenY)));
    }
}
