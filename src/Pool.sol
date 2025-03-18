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

    uint256 public totalShare0;
    uint256 public totalShare1;
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

    function initialize(int24 _activeBin) external nonReentrant {
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

        bins[_activeBin] = BinInfo({
            share0: type(uint64).max,
            share1: type(uint64).max,
            tilLower: _activeBin - 512,
            tilUpper: _activeBin + 512
        });

        totalShare0 = 512 * type(uint64).max;
        totalShare1 = 512 * type(uint64).max;

        _mint(address(0), 0, 512 ** 2);
        _mint(address(0), 1, 512 ** 2);

        initializer = sender;
    }

    function mint(uint256 amount0, uint256 amount1, address recipient, uint256 deadline)
        external
        ensure(deadline)
        nonReentrant
        returns (uint256 amountA, uint256 amountB)
    {
        address sender = msg.sender;
        require(reserve0 != 0 && reserve1 != 0, "UNINITIALIZED");
        require(amount0 != 0 && amount1 != 0, "ZERO_AMOUNT");

        uint256 balBefore0 = token0.balanceOf(address(this));
        uint256 balBefore1 = token1.balanceOf(address(this));
        TransferHelper.safeTransferFrom(token0, sender, address(this), amount0);
        TransferHelper.safeTransferFrom(token1, sender, address(this), amount1);
        uint256 balAfter0 = token0.balanceOf(address(this));
        uint256 balAfter1 = token1.balanceOf(address(this));

        amountA = ((balAfter0 - balBefore0) * (totalSupply(0))) / balBefore0;
        amountB = ((balAfter1 - balBefore1) * (totalSupply(1))) / balBefore1;

        _mint(recipient, 0, amountA);
        _mint(recipient, 1, amountB);
    }

    function burn(uint256 amount0, uint256 amount1, address recipient, uint256 deadline)
        external
        ensure(deadline)
        nonReentrant
        returns (uint256 amountA, uint256 amountB)
    {
        address sender = msg.sender;
        require(reserve0 != 0 && reserve1 != 0, "UNINITIALIZED");
        require(amount0 != 0 && amount1 != 0, "ZERO_AMOUNT");

        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        _burn(sender, 0, amount0);
        _burn(sender, 1, amount1);

        amountA = (amount0 * bal0) / totalSupply(0);
        amountB = (amount1 * bal1) / totalSupply(1);

        TransferHelper.safeTransfer(token0, recipient, amountA);
        TransferHelper.safeTransfer(token1, recipient, amountB);
    }

    //function burn
    //function swap
    //function flash
}
