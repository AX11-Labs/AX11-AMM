// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

/// @title IAx11FlashCallback
/// @notice Any contract that calls IPool.flash() must implement this interface
interface IAx11FlashCallback {
    /// @notice Callback function interface for flashloan implementation, required to payback the borrowed funds within this function
    /// @param feeX The fee amount in tokenX
    /// @param feeY The fee amount in tokenY
    function flashCallback(uint128 feeX, uint128 feeY) external;
}
