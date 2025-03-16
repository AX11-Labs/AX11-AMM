// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

interface IPool {
    struct BinInfo {
        uint104 bin_share0;
        uint104 bin_share1;
        int24 tilLower;
        int24 tilUpper;
    }

    // struct GroupInfo {
    //     uint104 group_share0;
    //     uint104 group_share1;
    //     int24 til0;
    //     int24 til1;
    // }

    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint8);
    // function bins(
    //     uint24 binId
    // ) external view returns (uint104 reserve0, uint104 reserve1);
    // function binGroups(
    //     uint16 groupsId
    // ) external view returns (uint24 avgBin, uint128 reserve0, uint128 reserve1);

    function mint(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        uint256 deadline
    ) external payable returns (uint256 amountA, uint256 amountB);
}
