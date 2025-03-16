// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {LpToken} from "./abstracts/LpToken.sol";
import {IPool} from "./interfaces/IPool.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {IERC20} from "./interfaces/IERC20.sol";

contract Pool is LpToken, IPool {
    address public immutable override factory;
    IERC20 public immutable override token0;
    IERC20 public immutable override token1;
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

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    constructor(IERC20 _token0, IERC20 _token1, string memory name, string memory symbol) LpToken(name, symbol) {
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
    }

    function setInitializer(address _initializer) external {
        require(msg.sender == initializer, "NOT_INITIALIZER");
        initializer = _initializer;
    }

    function initialize(int24 _activeBin) external {
        address sender = msg.sender;
        require(reserve0 == 0 && reserve1 == 0, "INITIALIZED");
        require(_activeBin >= -65024 && _activeBin <= 65023, "INVALID_INIT_PRICE");
        TransferHelper.safeTransferFrom(token0, sender, address(this), 512);
        TransferHelper.safeTransferFrom(token1, sender, address(this), 512);

        fee = 50;
        activeBin = _activeBin;
        minAvailableBin = _activeBin - 512;
        maxAvailableBin = _activeBin + 512;
        tickUpper = _activeBin - 256;
        tickLower = _activeBin + 256;

        bins[_activeBin] =
            BinInfo({liquidity0: 512, liquidity1: 512, tilLower: _activeBin - 512, tilUpper: _activeBin + 512});

        reserve0 = 512;
        reserve1 = 512;

        _mint(address(0), 0, 512);
        _mint(address(0), 1, 512);

        initializer = sender;
    }

    function mint(uint256 amount0, uint256 amount1, address recipient, uint256 deadline)
        public
        payable
        ensure(deadline)
        returns (uint256 amountA, uint256 amountB)
    {
        if (token0 == address(0)) {
            amount0 = msg.value;
        } else {
            TransferHelper.safeTransferFrom(token0, recipient, address(this), amount0);
        }

        TransferHelper.safeTransferFrom(token1, recipient, address(this), amount1);

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
