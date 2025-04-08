// SPDX-License-Identifier: GPL-3.0-or-later

import {IERC20} from "./IERC20.sol";

pragma solidity 0.8.28;

interface IFactory {
    event PoolCreated(IERC20 indexed token0, IERC20 indexed token1, address pool);

    struct PoolInfo {
        IERC20 token0;
        IERC20 token1;
    }

    function getPool(IERC20 token0, IERC20 token1) external view returns (address pool);

    function getTokens(address pool) external view returns (IERC20 token0, IERC20 token1);

    function createPool(IERC20 token0, IERC20 token1) external payable returns (address pool);

    function setOwner(address _owner) external;
    function setFeeTo(address _feeTo) external;
}
