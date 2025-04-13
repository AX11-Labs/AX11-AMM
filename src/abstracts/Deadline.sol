// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

/// @title Deadline Validation Contract
/// @notice Abstract contract providing deadline validation functionality
/// @dev This contract is used to ensure operations are performed before a specified deadline
abstract contract Deadline {
    /// @notice Error thrown when attempting to perform an operation after the deadline has passed
    /// @dev This error is used to enforce time-sensitive operations
    error Expired();

    /// @notice Modifier to ensure an operation is performed before the deadline
    /// @param deadline The timestamp after which the operation is no longer valid
    /// @dev Reverts with Expired() if the current block timestamp is greater than the deadline
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, Expired());
        _;
    }
}
