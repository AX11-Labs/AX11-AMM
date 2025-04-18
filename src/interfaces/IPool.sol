// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

interface IPool {
    error INVALID_ADDRESS();
    error INVALID_BIN_ID();
    error INVALID_AMOUNT();
    error INSUFFICIENT_LIQUIDITY();

    struct PoolInfo {
        uint128 balance0Long;
        uint128 balance1Long;
        uint128 balance0Short;
        uint128 balance1Short;
        uint256 LPShareXLong;
        uint256 LPShareYLong;
        uint256 LPShareXShort;
        uint256 LPShareYShort;
    }

    struct PriceInfo {
        int24 activeId;
        int24 minId;
        int24 maxId;
        int24 tickUpper;
        int24 tickLower;
        uint8 fee;
    }

    struct BinInfo {
        uint256 balance0;
        uint256 balance1;
    }

    struct LiquidityOption {
        uint256 amount0;
        uint256 amount1;
        address recipient;
        uint256 deadline;
        uint256 longX;
        uint256 longY;
        uint256 shortX;
        uint256 shortY;
    }

    function poolInfo() external view returns (PoolInfo memory);

    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function initiator() external view returns (address);
    function sweep(address recipient, bool zeroOrOne, uint256 amount) external returns (uint256 available);

    function setInitiator(address _initiator) external;
    function mint(LiquidityOption calldata option) external payable returns (uint256 amountA, uint256 amountB);
}
