// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {IFactory} from "./interfaces/IFactory.sol";
import {Pool} from "./Pool.sol";
import {IERC20} from "./interfaces/IERC20.sol";

contract Factory is IFactory {
    error INVALID_ADDRESS();
    /// token0 => token1 => poolAddress
    ///@notice token0 and token1 must be sorted

    mapping(IERC20 token0 => mapping(IERC20 token1 => address pool)) public override getPool;

    /// poolAddress => token0,token1
    ///@notice return in sorted order
    mapping(address => PoolInfo) public override getTokens;

    uint256 public override totalPools;
    address public override feeTo;
    address public override owner;

    constructor() {
        owner = msg.sender;
    }

    function createPool(IERC20 token0, IERC20 token1) external override returns (address pool) {
        if (token0 == token1) {
            revert INVALID_ADDRESS();
        } else if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        require(getPool[token0][token1] == address(0), "CREATED");

        string memory _name = string.concat("Ax11 Liquidity [", token0.name(), "/", token1.name(), "]");
        string memory _symbol = string.concat("Ax11-LP [", token0.symbol(), "/", token1.symbol(), "]");
        pool = address(new Pool{salt: keccak256(abi.encodePacked(token0, token1))}(token0, token1, _name, _symbol));

        getPool[token0][token1] = pool;
        getPool[token1][token0] = pool;
        // populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses

        uint256 _totalPools = totalPools + 1;

        totalPools = _totalPools;
        getTokens[pool] = PoolInfo({token0: token0, token1: token1, poolId: _totalPools});

        emit PoolCreated(token0, token1, pool);
    }

    function setOwner(address _owner) external override {
        require(msg.sender == owner);
        owner = _owner;
    }

    function setFeeTo(address _feeTo) external override {
        require(msg.sender == owner);
        feeTo = _feeTo;
    }
}
