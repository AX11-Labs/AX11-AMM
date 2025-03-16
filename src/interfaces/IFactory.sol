// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

interface IFactory {
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event PoolCreated(
        address indexed token0,
        address indexed token1,
        address pool
    );

    // struct PoolInfo {
    //     address token0;
    //     address token1;
    //     uint256 reserve0;
    //     uint256 reserve1;
    //     uint24 activePriceId;
    //     uint24 minPriceId;
    //     uint24 maxPriceId;
    //     address lpToken;
    // }

    struct PoolInfo {
        address token0;
        address token1;
    }

    // struct TWAD {
    //     uint256 avgPrice;
    //     uint256 avgReserve0;
    //     uint256 avgReserve1;
    // }

    // struct PriceSetInfo {
    //     uint128 reserve0;
    //     uint128 reserve1;
    // }

    // struct PriceInfo {
    //     uint128 reserve0;
    //     // uint128 reserve1;
    // }
    function getPool(
        address token0,
        address token1
    ) external view returns (address pool);

    function getTokens(
        address pool
    ) external view returns (address token0, address token1);

    function createPool(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        int24 activePriceId;
    ) external payable returns (address pool);

    function setOwner(address _owner) external;
    function setOwnerRevenue(address _ownerRevenue) external;
}
