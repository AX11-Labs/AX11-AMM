// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {Ax11Lp} from "./abstracts/Ax11Lp.sol";
import {IPool} from "./interfaces/IPool.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {ReentrancyGuard} from "./abstracts/ReentrancyGuard.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {Deadline} from "./abstracts/Deadline.sol";
import {PriceMath} from "./libraries/PriceMath.sol";

contract Pool is Ax11Lp, IPool, ReentrancyGuard, Deadline {
    mapping(uint256 => BinInfo) public bins;
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

    function setInitiator(address _initiator) external override {
        require(msg.sender == initiator, INVALID_ADDRESS());
        initiator = _initiator;
    }


function getBase() private pure returns (uint256) {
    unchecked {
        return (1001 << 128) / 1000;
    }
}

    /// @notice _activePrice must be in 128.128 fixed point
    function initialize(uint256 _activePrice, address _initiator) private {
        TransferHelper.safeTransferFrom(token0, _initiator, address(this), 512);
        TransferHelper.safeTransferFrom(token1, _initiator, address(this), 512);

        PoolInfo storage _poolInfo = poolInfo;
        PriceInfo storage _priceInfo = priceInfo;
        uint256 _share = 512 << 128; // scaling as 128.128 fixed point
        uint256 scale = type(uint128).max+1;

        // Calculate price range using 512 bins with 0.1% (1.001) price changes
        uint256 base = getBase().pow(512); // 1.001 in 128.128 fixed point
        uint256 lowerPrice = PriceMath.fullMulDiv(_activePrice, scale, base);
        uint256 upperPrice = PriceMath.fullMulDiv(_activePrice, base, scale);

        bins[_activePrice] = BinInfo({
            binShare0: _share,
            binShare1: _share,
            nextPriceLower: lowerPrice,
            nextPriceUpper: upperPrice
        });

        priceInfo = PriceInfo({
            activePrice: _activePrice,
            minPrice: lowerPrice,
            maxPrice: upperPrice,
            tickUpper: (_activePrice + upperPrice) >> 1,
            tickLower: (_activePrice + lowerPrice) >> 1,
            fee: 30
        });

        poolInfo = PoolInfo({totalShare0: _share, totalShare1: _share});
        _share >>= 1;
        _mint(address(0), _share, _share, _share, _share);

        initiator = _initiator;
    }

    function getAmountFromShare(uint256 share, uint256 totalShare, uint256 totalAmount)
        private
        pure
        returns (uint256)
    {
        return (share * totalAmount) / totalShare;
    }

    function swap(address recipient, bool xInYOut, uint256 amountIn)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        (address tokenIn, address tokenOut) = xInYOut ? (token0, token1) : (token1, token0);

        uint256 balInBefore = IERC20(tokenIn).balanceOf(address(this));
        TransferHelper.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        uint256 balInAfter = IERC20(tokenIn).balanceOf(address(this));
        uint256 balOut = IERC20(tokenOut).balanceOf(address(this));
        uint256 remainingAmount = balInAfter - balInBefore; // actual amountIn

        amountOut = 0;
        uint256 binId = priceInfo.activePrice;
        uint256 binShareRemoved;
        uint256 swappable;

        while (remainingAmount != 0) {
            BinInfo storage _bin = bins[binId];
            PoolInfo storage _pool = poolInfo;
            (uint256 binShareIn, uint256 binShareOut, uint256 totalShareIn, uint256 totalShareOut) = xInYOut
                ? (_bin.binShare0, _bin.binShare1, _pool.totalShare0, _pool.totalShare1)
                : (_bin.binShare1, _bin.binShare0, _pool.totalShare1, _pool.totalShare0);
            swappable = getAmountFromShare(binShareOut, totalShareOut, balOut, binId);

            if (swappable == 0) {
                if (remainingAmount != 0) {
                    TransferHelper.safeTransfer(tokenIn, recipient, remainingAmount); // refund
                }
                break;
            } else if (remainingAmount > swappable) {
                //do something
            } else {
                amountToSwap = remainingAmount;
            }
            uint256 amountOutWithFee = (amountToSwap * (10000 - priceInfo.fee)) / 10000;
            amountOut += amountOutWithFee;
            remainingAmount -= amountToSwap;

            if (xInYOut) {
                bin.binShare0 -= amountToSwap;
                bin.binShare1 += amountOutWithFee;
            } else {
                bin.binShare1 -= amountToSwap;
                bin.binShare0 += amountOutWithFee;
            }

            binId = xInYOut ? bin.nextPriceUpper : bin.nextPriceLower;
        }

        TransferHelper.safeTransfer(tokenOut, recipient, amountOut);
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
