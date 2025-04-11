// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {IERC20Metadata} from "./IERC20Metadata.sol";

/// @title Interface for Ax11 LP Token
/// @notice This interface defines the core functionality for the Ax11 LP token, including ERC20-like operations
/// with support for long and short positions
interface IAx11Lp is IERC20Metadata {
    /// @notice Error thrown when attempting to transfer tokens without sufficient allowance
    error INSUFFICIENT_ALLOWANCE();

    /// @notice Error thrown when attempting to transfer tokens to the LP token itself
    error INVALID_ADDRESS();

    /// @notice Error thrown when attempting to use a signature that has expired
    error EXPIRED();

    /// @notice Structure representing LP token information
    /// @param longX Amount of long position X tokens
    /// @param longY Amount of long position Y tokens
    /// @param shortX Amount of short position X tokens
    /// @param shortY Amount of short position Y tokens
    struct LpInfo {
        uint256 longX;
        uint256 longY;
        uint256 shortX;
        uint256 shortY;
    }
    /// @notice Event emitted when the approval amount for the spender of a given owner's tokens changes.
    /// @param owner The account that approved spending of its tokens
    /// @param spender The account for which the spending allowance was modified
    /// @param value true = allow, false = disallow/revoke

    event Approval(address indexed owner, address indexed spender, bool value);

    /// @notice Event emitted when LP tokens are transferred between accounts
    /// @param from The account from which the LP tokens were sent
    /// @param to The account to which the LP tokens were sent
    /// @param longX The amount of long position X tokens transferred
    /// @param longY The amount of long position Y tokens transferred
    /// @param shortX The amount of short position X tokens transferred
    /// @param shortY The amount of short position Y tokens transferred
    event Transfer(
        address indexed from, address indexed to, uint256 longX, uint256 longY, uint256 shortX, uint256 shortY
    );

    /// @notice Returns the total supply of LP tokens
    /// @return longX The total amount of long position X tokens
    /// @return longY The total amount of long position Y tokens
    /// @return shortX The total amount of short position X tokens
    /// @return shortY The total amount of short position Y tokens
    function totalSupply() external view returns (uint256 longX, uint256 longY, uint256 shortX, uint256 shortY);

    /// @notice Returns the LP token balance of an account
    /// @param account The address to query the balance of
    /// @return longX The amount of long position X tokens held by the account
    /// @return longY The amount of long position Y tokens held by the account
    /// @return shortX The amount of short position X tokens held by the account
    /// @return shortY The amount of short position Y tokens held by the account
    function balanceOf(address account)
        external
        view
        returns (uint256 longX, uint256 longY, uint256 shortX, uint256 shortY);

    /// @notice Returns the current allowance status between owner and spender
    /// @param owner The address of the token owner
    /// @param spender The address of the token spender
    /// @return The current allowance status (true = allowed, false = not allowed)
    function allowance(address owner, address spender) external view returns (bool);

    /// @notice Approves or revokes permission for a spender to transfer tokens
    /// @param spender The address to approve or revoke permission for
    /// @param value true to approve, false to revoke
    /// @return A boolean indicating whether the operation succeeded
    function approve(address spender, bool value) external returns (bool);

    /// @notice Transfers LP tokens to another address
    /// @param to The address to transfer tokens to
    /// @param longX The amount of long position X tokens to transfer
    /// @param longY The amount of long position Y tokens to transfer
    /// @param shortX The amount of short position X tokens to transfer
    /// @param shortY The amount of short position Y tokens to transfer
    /// @return A boolean indicating whether the transfer succeeded
    function transfer(address to, uint256 longX, uint256 longY, uint256 shortX, uint256 shortY)
        external
        returns (bool);

    /// @notice Transfers LP tokens from one address to another
    /// @param from The address to transfer tokens from
    /// @param to The address to transfer tokens to
    /// @param longX The amount of long position X tokens to transfer
    /// @param longY The amount of long position Y tokens to transfer
    /// @param shortX The amount of short position X tokens to transfer
    /// @param shortY The amount of short position Y tokens to transfer
    /// @return A boolean indicating whether the transfer succeeded
    function transferFrom(address from, address to, uint256 longX, uint256 longY, uint256 shortX, uint256 shortY)
        external
        returns (bool);

    /// @notice Approves a spender to transfer tokens using a signature
    /// @param owner The address of the token owner
    /// @param spender The address to approve or revoke permission for
    /// @param value true to approve, false to revoke
    /// @param deadline The time at which the signature expires
    /// @param v The recovery byte of the signature
    /// @param r Half of the ECDSA signature pair
    /// @param s Half of the ECDSA signature pair
    /// @return A boolean indicating whether the operation succeeded
    function permit(address owner, address spender, bool value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        returns (bool);

    /// @notice Returns the current nonce for an owner
    /// @param owner The address to query the nonce of
    /// @return The current nonce of the owner
    function nonces(address owner) external view returns (uint256);

    /// @notice Returns the domain separator used in the permit signature
    /// @return The domain separator
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
