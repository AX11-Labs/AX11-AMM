// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

interface IPool {
    error NOT_OWNER();
    error INVALID_AMOUNT();
    error SLIPPAGE_EXCEEDED();
    error FLASH_INSUFFICIENT_PAYBACK();
    error MINT_INSUFFICIENT_PAYBACK();
    error BURN_INSUFFICIENT_PAYBACK();
    error INSUFFICIENT_LIQUIDITY();
    error INVALID_ARRAY_LENGTH();
    error INSUFFICIENT_BALANCE();

    /// @notice Emitted when a new pool is created
    /// @param tokenX The first token of the pool (lower address)
    /// @param tokenY The second token of the pool (higher address)
    /// @param poolId The poolId of the newly created pool
    event PoolCreated(address indexed tokenX, address indexed tokenY, uint256 poolId);

    // ---------- Storage struct ----------

    struct PoolInfo {
        // token info
        address tokenX;
        address tokenY;
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
        int24 tickX;
        int24 tickY;
        // twab
        int80 twabCumulative;
        uint56 lastTimestamp;
        // 7-days twab
        int80 last7daysCumulative;
        uint56 last7daysTimestamp;
        // ALM target timestamp
        uint56 almTargetTimestamp;
    }

    struct BinInfo {
        uint232 binShare;
        int24 lastBinId;
    }

    // ---------- Function input struct ----------

    struct LiquidityOption {
        address recipient;
        address callback;
        uint256 poolId;
        uint256 amountForLongX;
        uint256 amountForLongY;
        uint256 amountForShortX;
        uint256 amountForShortY;
        int24 minActiveId; // slippage
        int24 maxActiveId; // slippage
        uint256 deadline;
    }

    function owner() external returns (address);
    function setOwner(address newOwner) external;
    function totalPools() external view returns (uint256);
    function createPool(address tokenX, address tokenY, int24 activeId) external returns (uint256 poolId);
    function getPoolInfo(uint256 poolId) external view returns (PoolInfo memory);
    function getPoolId(address tokenX, address tokenY) external view returns (uint256);

    function flash(
        address[] calldata recipients,
        address[] calldata tokens,
        uint256[] calldata amounts,
        address callback,
        uint256 deadline
    ) external;

    function mint(
        LiquidityOption calldata option
    ) external returns (uint256 LPXLong, uint256 LPYLong, uint256 LPXShort, uint256 LPYShort);
    function burn(LiquidityOption calldata option) external returns (uint256 amountX, uint256 amountY);
    function sweep(address[] calldata tokens, uint256[] calldata amounts, address[] calldata recipients) external;
    function getSweepable(address token) external view returns (uint256);
}
