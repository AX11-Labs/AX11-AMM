// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

/// @title IAX11FlashCallback
/// @notice Any contract that calls IPool.flash() must implement this interface
interface IAX11FlashCallback {
    /// @notice Callback function interface for flashloan implementation
    /// @param paybackAmount The amount of the token to be paid back, fee included.
    function AX11FlashCallback(uint256 paybackAmount) external;
}
