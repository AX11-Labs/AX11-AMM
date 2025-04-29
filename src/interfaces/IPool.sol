// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

interface IPool {
    error INVALID_BIN_ID();
    error INVALID_AMOUNT();
    error SLIPPAGE_EXCEEDED();
    error INSUFFICIENT_PAYBACK();
    error MINIMUM_LIQUIDITY_EXCEEDED();

    // ---------- Storage struct ----------

    struct PoolInfo {
        // token info
        address tokenX;
        address tokenY;
        // pool initiator
        address initiator;
        // total balance
        uint128 totalBalanceXLong;
        uint128 totalBalanceYLong;
        uint128 totalBalanceXShort;
        uint128 totalBalanceYShort;
        // total bin share
        uint256 totalBinShareX; // 128.128 fixed point
        uint256 totalBinShareY; // 128.128 fixed point
        // market bin share
        uint256 activeBinShareX; //128.128 fixed point
        uint256 activeBinShareY; //128.128 fixed point
        // price info
        int24 activeId;
        int24 lowestId;
        int24 highestId;
        int24 tickXUpper;
        int24 tickYUpper;
        int24 tickXLower;
        int24 tickYLower;
        uint8 volatilityLevel;
        uint40 volatilityTimestamp;
        uint40 targetTimestamp;
    }

    // ---------- Function input struct ----------

    struct LiquidityOption {
        address recipient;
        int24 minActiveId;
        int24 maxActiveId;
        uint256 amountForLongX;
        uint256 amountForLongY;
        uint256 amountForShortX;
        uint256 amountForShortY;
        uint256 deadline;
    }

    function factory() external view returns (address);
    function getPoolInfo() external view returns (PoolInfo memory);
    function setInitiator(address _initiator) external;
    function mint(LiquidityOption calldata option)
        external
        returns (uint256 LPXLong, uint256 LPYLong, uint256 LPXShort, uint256 LPYShort);
    function burn(LiquidityOption calldata option) external returns (uint256 amountX, uint256 amountY);
}
