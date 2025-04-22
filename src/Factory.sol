// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {IFactory} from "./interfaces/IFactory.sol";
import {Pool} from "./Pool.sol";
import {IERC20Metadata} from "./interfaces/IERC20Metadata.sol";
import {NoDelegateCall} from "./abstracts/NoDelegateCall.sol";

contract Factory is IFactory, NoDelegateCall {
    mapping(address tokenX => mapping(address tokenY => address pool)) public override getPool;
    mapping(address => PoolInfo) public override getTokens;

    uint256 public override totalPools;
    address public override feeTo;
    address public override owner;

    constructor() {
        owner = msg.sender;
        feeTo = msg.sender;
    }

    function createPool(address tokenX, address tokenY, int24 activeId) external override NoDelegateCall returns (address pool) {
        if (tokenX == tokenY) {
            revert INVALID_ADDRESS();
        } else if (tokenX > tokenY) {
            (tokenX, tokenY) = (tokenY, tokenX);
        }

        require(getPool[tokenX][tokenY] == address(0), CREATED());

        string memory _name =
            string.concat("Ax11 Pool [", IERC20Metadata(tokenX).name(), "/", IERC20Metadata(tokenY).name(), "]");
        string memory _symbol =
            string.concat("Ax11-LP [", IERC20Metadata(tokenX).symbol(), "/", IERC20Metadata(tokenY).symbol(), "]");
        pool = address(
            new Pool{salt: keccak256(abi.encodePacked(tokenX, tokenY))}(
                tokenX, tokenY, activeId, msg.sender, _name, _symbol
            )
        );

        getPool[tokenX][tokenY] = pool;
        getPool[tokenY][tokenX] = pool; // populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses
        getTokens[pool] = PoolInfo({tokenX: tokenX, tokenY: tokenY});

        totalPools++;

        emit PoolCreated(tokenX, tokenY, pool);
    }

    function setOwner(address _owner) external override {
        require(msg.sender == owner, NOT_OWNER());
        owner = _owner;
    }

    function setFeeTo(address _feeTo) external override {
        require(msg.sender == owner, NOT_OWNER());
        feeTo = _feeTo;
    }
}
