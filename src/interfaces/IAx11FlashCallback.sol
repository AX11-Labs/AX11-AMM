// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

/// @title IAX11FlashCallback
/// @notice Any contract that calls IPool.flash() must implement this interface
interface IAX11FlashCallback {
    /// @notice Callback function interface for flashloan implementation
    function AX11FlashCallback() external;
}
