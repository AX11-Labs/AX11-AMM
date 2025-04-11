// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {Ax11Lp} from "./abstracts/Ax11Lp.sol";
import {IPool} from "./interfaces/IPool.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {ReentrancyGuard} from "./abstracts/ReentrancyGuard.sol";
import {IERC20} from "./interfaces/IERC20.sol";

contract Pool is Ax11Lp, IPool, ReentrancyGuard {
    mapping(uint256 binId => BinInfo) public bins;
    PoolInfo public override poolInfo;
    PriceInfo public override priceInfo;

    address public immutable override factory;
    address public immutable override token0;
    address public immutable override token1;
    address public override initiator;

    constructor(
        address _token0,
        address _token1,
        uint256 _activePrice,
        address _initiator,
        string memory name,
        string memory symbol
    ) Ax11Lp(name, symbol) {
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
        initialize(_activePrice, _initiator);
    }

    function setInitiator(address _initiator) external override{
        require(msg.sender == initiator, INVALID_ADDRESS());
        initiator = _initiator;
    }

    function initialize(uint256 _activePrice, address _initiator) private {
        TransferHelper.safeTransferFrom(token0, _initiator, address(this), 512);
        TransferHelper.safeTransferFrom(token1, _initiator, address(this), 512);

        PoolInfo storage _poolInfo = poolInfo;
        PriceInfo storage _priceInfo = priceInfo;
        uint256 _share = 512 << 128; // scaling as 128.128 fixed point

        bins[_activePrice] = BinInfo({
            binShare0: _share,
            binShare1: _share,
            nextPriceLower: _activePrice - 512,
            nextPriceUpper: _activePrice + 512
        });

        priceInfo = PriceInfo({
            activePrice: _activePrice,
            minPrice: _activePrice - 512,
            maxPrice: _activePrice + 512,
            tickUpper: _activePrice - 256,
            tickLower: _activePrice + 256,
            fee: 50
        });

        poolInfo = PoolInfo({totalShare0: _share, totalShare1: _share});
        _share /= 2;

        _mint(address(0), _share, _share, _share, _share);

        initiator = _initiator;
    }

    function mint(LiquidityOption calldata option)
        external
        ensure(option.deadline)
        nonReentrant
        returns (uint256 amountA, uint256 amountB)
    {
        address sender = msg.sender;
        //require(amount0 != 0 && amount1 != 0, "ZERO_AMOUNT");

        uint256 balBefore0 = IERC20(token0).balanceOf(address(this));
        uint256 balBefore1 = IERC20(token1).balanceOf(address(this));
        if (amount0 != 0) {
            TransferHelper.safeTransferFrom(token0, sender, address(this), amount0);
        }
        if (amount1 != 0) {
            TransferHelper.safeTransferFrom(token1, sender, address(this), amount1);
        }
        uint256 balAfter0 = IERC20(token0).balanceOf(address(this));
        uint256 balAfter1 = IERC20(token1).balanceOf(address(this));

        // amountA = ((balAfter0 - balBefore0) * (totalSupply(0))) / balBefore0;
        // amountB = ((balAfter1 - balBefore1) * (totalSupply(1))) / balBefore1;

        _mint(recipient, option.longX, option.longY, option.shortX, option.shortY);
    }

    function burn(uint256 amount0, uint256 amount1, address recipient, uint256 deadline)
        external
        ensure(deadline)
        nonReentrant
        returns (uint256 amountA, uint256 amountB)
    {
        address sender = msg.sender;
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
