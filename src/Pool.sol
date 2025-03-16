// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {LpToken} from "./abstracts/LpToken.sol";
import {IPool} from "./interfaces/IPool.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

contract Pool is LpToken, IPool {
    address public immutable override factory;
    address public immutable override token0;
    address public immutable override token1;
    uint8 public constant binStep = 10;
    int24 public constant MIN_PRICE_ID = -65536;
    int24 public constant MAX_PRICE_ID = 65535;

    uint256 public reserve0;
    uint256 public reserve1;
    uint8 public override fee;

    int24 public activeBin;
    int24 public minAvailableBin;
    int24 public maxAvailableBin;
    int24 public tickUpper;
    int24 public tickLower;

    address public initializer;

    mapping(int24 binId => BinInfo) public bins;
    // mapping(uint16 groupsId => GroupInfo) public override binGroups;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    constructor(
        address _token0,
        address _token1,
        string memory name,
        string memory symbol
    ) LpToken(name, symbol) {
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
    }

    function changeInitializer(address newInitializer) external {
        require(msg.sender == initializer, "NOT_INITIALIZER");
        initializer = newInitializer;
    }

    function initialize(int24 _activeBin) public payable {
        require(reserve0 == 0 && reserve1 == 0, "INITIALIZED");
        require(msg.sender == factory, "ONLY_OWNER");
        require(
            _activeBin >= -65024 && _activeBin <= 65023,
            "INVALID_INIT_PRICE"
        );
        fee = 50;
        activeBin = _activeBin;
        minAvailableBin = _activeBin - 512;
        maxAvailableBin = _activeBin + 512;
        tickUpper = _activeBin - 256;
        tickLower = _activeBin + 256;
        mint(512, 512, address(0), block.timestamp);

        bins[_activeBin] = BinInfo({
            bin_share0: 1,
            bin_share1: 1,
            tilLower: _activeBin - 512,
            tilUpper: _activeBin + 512
        });

        initializer = msg.sender;
    }

    function mint(
        uint256 amount0,
        uint256 amount1,
        address recipient,
        uint256 deadline
    )
        public
        payable
        ensure(deadline)
        returns (uint256 amountA, uint256 amountB)
    {
        if (token0 == address(0)) {
            amount0 = msg.value;
        } else {
            TransferHelper.safeTransferFrom(
                token0,
                recipient,
                address(this),
                amount0
            );
        }

        TransferHelper.safeTransferFrom(
            token1,
            recipient,
            address(this),
            amount1
        );

        if (reserve0 == 0 && reserve1 == 0) {} else {
            reserve0 += amount0;
            reserve1 += amount1;
        }

        _mint(recipient, 0, amount0);
        _mint(recipient, 1, amount1);
    }

    //function burn
    //function swap
    //function flash
}
