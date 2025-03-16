// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

interface ILpToken {
    event Transfer(address sender, address recipient, uint256 tokenId, uint256 amount);

    event Approval(address owner, address spender, uint256 tokenId, uint256 amount);

    function totalSupply(uint256 tokenId) external view returns (uint256);

    function balanceOf(address account, uint256 tokenId) external view returns (uint256);

    function allowance(address owner, address spender, uint256 tokenId) external view returns (uint256);

    function approve(address spender, uint256 tokenId, uint256 value) external returns (bool);

    function transfer(address to, uint256 tokenId, uint256 value) external returns (bool);

    function transferFrom(address from, address to, uint256 tokenId, uint256 value) external returns (bool);

    function permit(
        address owner,
        address spender,
        uint256 tokenId,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (bool);

    function nonces(address owner, uint256 tokenId) external returns (uint256);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
