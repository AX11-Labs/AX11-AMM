// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

/// @title Factory Interface for Ax11 AMM
/// @notice Interface for the factory contract that deploys and manages Ax11 liquidity pools
interface IFactory {
    /// @notice Error thrown when the caller is not the owner
    error NOT_OWNER();

    /// @notice Error thrown when an invalid address is provided (zero address or identical tokens)
    error INVALID_ADDRESS();

    /// @notice Error thrown when attempting to create a pool that already exists
    error CREATED();

    /// @notice Emitted when a new pool is created
    /// @param token0 The first token of the pool (lower address)
    /// @param token1 The second token of the pool (higher address)
    /// @param pool The address of the newly created pool
    event PoolCreated(address indexed token0, address indexed token1, address pool);

    /// @notice Structure containing information about a pool
    /// @param token0 The address of the first token in the pool (lower address)
    /// @param token1 The address of the second token in the pool (higher address)
    struct PoolInfo {
        address token0;
        address token1;
    }

    /// @notice Returns the total number of pools created
    /// @return The number of pools deployed by this factory
    function totalPools() external view returns (uint256);

    /// @notice Returns the address that receives protocol fees
    /// @return The address where protocol fees are sent
    function feeTo() external view returns (address);

    /// @notice Returns the address of the factory owner
    /// @return The address of the current owner
    function owner() external view returns (address);

    /// @notice Fetches the pool address for a given pair of tokens
    /// @dev The order of token0 and token1 doesn't matter, as the factory handles sorting
    /// @param token0 The address of the first token
    /// @param token1 The address of the second token
    /// @return pool The address of the pool for the token pair, or address(0) if it doesn't exist
    function getPool(address token0, address token1) external view returns (address pool);

    /// @notice Retrieves the tokens associated with a pool
    /// @param pool The address of the pool
    /// @return token0 The address of the first token (lower address)
    /// @return token1 The address of the second token (higher address)
    function getTokens(address pool) external view returns (address token0, address token1);

    /// @notice Creates a new pool for a pair of tokens
    /// @dev Tokens are automatically sorted so token0 is always the lower address
    /// @param token0 The address of the first token
    /// @param token1 The address of the second token
    /// @param activeId The active bin of the pool
    /// @return pool The address of the newly created pool
    function createPool(address token0, address token1, int24 activeId) external returns (address pool);

    /// @notice Updates the owner of the factory
    /// @dev Can only be called by the current owner
    /// @param _owner The address of the new owner
    function setOwner(address _owner) external;

    /// @notice Updates the fee recipient address
    /// @dev Can only be called by the current owner
    /// @param _feeTo The new address to receive protocol fees
    function setFeeTo(address _feeTo) external;
}
