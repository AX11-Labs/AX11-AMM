// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

/// @title IAX11Callback
/// @notice Any contract that calls any action in Pool.sol must implement this callback action
interface IAX11Callback {
    /// @notice Callback function interface for flashloan implementation
    /// @param paybackAmounts The amount of the token to be paid back, fee included.
    function flashCallback(uint256[] memory paybackAmounts) external;

    function mintCallback(uint256 payBackAmountX, uint256 payBackAmountY) external;

    function burnCallback(
        uint256 payBackLongXAmount,
        uint256 payBackLongYAmount,
        uint256 payBackShortXAmount,
        uint256 payBackShortYAmount
    ) external;
}
