// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

/// @title Minimal ERC20 interface with metadata
/// @notice Contains a subset of the full ERC20 interface
interface IERC20Metadata {
    /// @notice Returns the name of the token
    /// @return The name of the token as a string
    function name() external view returns (string memory);

    /// @notice Returns the symbol of the token
    /// @return The symbol of the token as a string
    function symbol() external view returns (string memory);

    /// @notice Returns the number of decimals the token uses
    /// @return The number of decimals used by the token
    function decimals() external view returns (uint8);
}
