// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

interface IPool {
    error INVALID_BIN_ID();
    error INVALID_AMOUNT();
    error SLIPPAGE_EXCEEDED();

    struct PoolInfo {
        uint128 totalBalanceXLong;
        uint128 totalBalanceYLong;
        uint128 totalBalanceXShort;
        uint128 totalBalanceYShort;
        uint256 totalBinShareX; // 128.128 fixed point
        uint256 totalBinShareY; // 128.128 fixed point
        uint256 totalLPShareXLong; // 128.128 fixed point
        uint256 totalLPShareYLong; // 128.128 fixed point
        uint256 totalLPShareXShort; // 128.128 fixed point
        uint256 totalLPShareYShort; // 128.128 fixed point
    }

    struct PriceInfo {
        int24 activeId;
        int24 minId;
        int24 maxId;
        int24 tickUpper;
        int24 tickLower;
        uint8 fee;
    }

    struct MarketBin {
        uint256 shareX; //128.128 fixed point
        uint256 shareY; //128.128 fixed point
    }

    struct LiquidityOption {
        address recipient;
        int24 minActiveId;
        int24 maxActiveId;
        uint128 amountForLongX;
        uint128 amountForLongY;
        uint128 amountForShortX;
        uint128 amountForShortY;
        uint256 deadline;
    }

    function factory() external view returns (address);
    function tokenX() external view returns (address);
    function tokenY() external view returns (address);
    function initiator() external view returns (address);
    function getPoolInfo() external view returns (PoolInfo memory);
    function getPriceInfo() external view returns (PriceInfo memory);
    function getPrevPriceInfo() external view returns (PriceInfo memory);
    function setInitiator(address _initiator) external;
    function mint(LiquidityOption calldata option)
        external
        returns (uint256 LPXLong, uint256 LPYLong, uint256 LPXShort, uint256 LPYShort);
    function burn(LiquidityOption calldata option) external returns (uint256 amountX, uint256 amountY);
}
