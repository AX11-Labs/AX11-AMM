// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

interface IPool {
    error INVALID_ADDRESS();
    error INVALID_PRICE();
    error INSUFFICIENT_LIQUIDITY();

    struct PoolInfo {
        uint256 totalTokenShare0;
        uint256 totalTokenShare1;
        uint256 totalLPShareX;
        uint256 totalLPShareY;
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
        uint256 binShare0;
        uint256 binShare1;
        int24 tilBinLower;
        int24 tilBinUpper;
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
    function priceInfo() external view returns (PriceInfo memory);

    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function initiator() external view returns (address);

    function setInitiator(address _initiator) external;
    function mint(LiquidityOption calldata option) external payable returns (uint256 amountA, uint256 amountB);
}
