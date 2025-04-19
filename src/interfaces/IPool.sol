// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

interface IPool {
    error INVALID_BIN_ID();
    error INVALID_AMOUNT();
    error SLIPPAGE_EXCEEDED();

    struct PoolInfo {
        uint128 balanceXLong;
        uint128 balanceYLong;
        uint128 balanceXShort;
        uint128 balanceYShort;
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
        uint128 balanceX;
        uint128 binShareY;
    }

    struct LiquidityOption {
        address recipient;
        int24 minActiveId;
        int24 maxActiveId;
        uint128 amountForLongX;
        uint128 amountForLongY;
        uint128 amountForShortX;
        uint128 amountForShortY;
        uint128 deadline;
    }

    function factory() external view returns (address);
    function tokenX() external view returns (address);
    function tokenY() external view returns (address);
    function initiator() external view returns (address);
    function sweep(address recipient, bool zeroOrOne, uint256 amount) external returns (uint256 available);

    function setInitiator(address _initiator) external;
    function mint(LiquidityOption calldata option)
        external
        returns (uint256 LPXLong, uint256 LPYLong, uint256 LPXShort, uint256 LPYShort);
    function burn(LiquidityOption calldata option) external returns (uint256 amountX, uint256 amountY);
}
