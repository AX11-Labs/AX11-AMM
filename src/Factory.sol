// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {IFactory} from "./interfaces/IFactory.sol";
import {Pool} from "./Pool.sol";
import {IERC20Metadata} from "./interfaces/IERC20Metadata.sol";

contract Factory is IFactory {
    mapping(address token0 => mapping(address token1 => address pool)) public override getPool;
    mapping(address => PoolInfo) public override getTokens;

    uint256 public override totalPools;
    address public override feeTo;
    address public override owner;

    constructor() {
        owner = msg.sender;
    }

    function createPool(address token0, address token1, int24 activeId) external override returns (address pool) {
        if (token0 == token1) {
            revert INVALID_ADDRESS();
        } else if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        require(getPool[token0][token1] == address(0), CREATED());

        string memory _name =
            string.concat("Ax11 Pool [", IERC20Metadata(token0).name(), "/", IERC20Metadata(token1).name(), "]");
        string memory _symbol =
            string.concat("Ax11-LP [", IERC20Metadata(token0).symbol(), "/", IERC20Metadata(token1).symbol(), "]");
        pool = address(new Pool{salt: keccak256(abi.encodePacked(token0, token1))}(token0, token1, activeId, _name, _symbol));

        getPool[token0][token1] = pool;
        getPool[token1][token0] = pool; // populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses
        getTokens[pool] = PoolInfo({token0: token0, token1: token1});

        totalPools++;

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
