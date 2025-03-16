// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {IFactory} from "./interfaces/IFactory.sol";
import {PoolHelper} from "./libraries/PoolHelper.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {Pool} from "./Pool.sol";
import {IERC20Metadata} from "./interfaces/IERC20Metadata.sol";
contract Factory is IFactory {
    /// token0 => token1 => poolAddress
    ///@notice token0 and token1 must be sorted
    mapping(address token0 => mapping(address token1 => address pool))
        public
        override getPool;

    /// poolAddress => token0,token1
    ///@notice return in sorted order
    mapping(address => PoolInfo) public override getTokens;

    address public ownerRevenue;
    address public owner;

    constructor() {
        owner = msg.sender;
        emit OwnerChanged(address(0), msg.sender);
    }

    function createPool(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        int24 activePriceId
    ) external payable override returns (address pool) {
        address sender = msg.sender;
        (token0, token1) = PoolHelper.sortToken(token0, token1);
        require(getPool[token0][token1] == address(0), "INITIALIZED");
        require(
            activePriceId > -65025 && activePriceId < 65024,
            "INVALID_INIT_PRICE"
        );
        // We dont need this line because we have line 70-71.
        // require(amount0 >= 512 && amount1 >= 512, "INSUFFICIENT_FUND");

        if (token0 == address(0)) {
            amount0 = msg.value;
        }

        amount0 -= 512; // will revert if amount0<512
        amount1 -= 512; // will revert if amount1<512
        string memory _name = string.concat(
            "Ax11 Liquidity [",
            IERC20Metadata(token0).name(),
            "/",
            IERC20Metadata(token1).name(),
            "]"
        );
        string memory _symbol = string.concat(
            "Ax11-LP [",
            IERC20Metadata(token0).symbol(),
            "/",
            IERC20Metadata(token1).symbol(),
            "]"
        );
        pool = address(
            new Pool{salt: keccak256(abi.encodePacked(token0, token1))}(
                token0,
                token1,
                _name,
                _symbol,
                activePriceId
            )
        );
        Pool(pool).mint(sender, amount0, amount1, block.timestamp);

        getPool[token0][token1] = pool;
        getTokens[pool] = PoolInfo({token0: token0, token1: token1});

        emit PoolCreated(token0, token1, pool);
    }

    function setOwner(address _owner) external override {
        require(msg.sender == owner);
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }

    function setOwnerRevenue(address _ownerRevenue) external override {
        require(msg.sender == owner);
        ownerRevenue = _ownerRevenue;
    }
}
