// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {Ax11Lp} from "./abstracts/Ax11Lp.sol";
import {IPool} from "./interfaces/IPool.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {ReentrancyGuard} from "./abstracts/ReentrancyGuard.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {Deadline} from "./abstracts/Deadline.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {Uint256x256Math} from "./libraries/Math/Uint256x256Math.sol";
import {Uint128x128Math} from "./libraries/Math/Uint128x128Math.sol";
import {FeeTier} from "./libraries/FeeTier.sol";

contract Pool is Ax11Lp, IPool, ReentrancyGuard, Deadline {
    mapping(int24 => BinInfo) public bins;
    PoolInfo public override poolInfo;
    PriceInfo public override priceInfo;
    PriceInfo public override prevPriceInfo;

    address public immutable override factory;
    address public immutable override token0;
    address public immutable override token1;
    address public override initiator;

    int24 private constant MAX_BIN_ID = 88767;
    int24 private constant MIN_BIN_ID = -88767;

    constructor(
        address _token0,
        address _token1,
        int24 _activeId,
        address _initiator,
        string memory name,
        string memory symbol
    ) Ax11Lp(name, symbol) {
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
        initialize(_activeId, _initiator);
    }

    function setInitiator(address _initiator) external override {
        require(msg.sender == initiator, INVALID_ADDRESS());
        initiator = _initiator;
    }

    /// @dev equivalent to (1001>>128)/1000, which is 1.001 in 128.128 fixed point
    function getBase() private pure returns (uint256) {
        return 340622649287859401926837982039199979667;
    }

    function initialize(int24 _activeId, address _initiator) private {
        TransferHelper.safeTransferFrom(token0, _initiator, address(this), 1024);
        TransferHelper.safeTransferFrom(token1, _initiator, address(this), 1024);

        PoolInfo storage _poolInfo = poolInfo;

        uint256 _share = 512 << 128; // scaling as 128.128 fixed point

        int24 lowerBin = _activeId - 511;
        int24 upperBin = _activeId + 511;
        require(lowerBin >= MIN_BIN_ID && upperBin <= MAX_BIN_ID, INVALID_BIN_ID());

        bins[_activeId] = BinInfo({binShare0: _share, binShare1: _share});

        poolInfo =
            PoolInfo({totalTokenShare0: _share, totalTokenShare1: _share, totalLPShareX: _share, totalLPShareY: _share});

        priceInfo = PriceInfo({
            activeId: _activeId,
            minPrice: lowerBin,
            maxPrice: upperBin,
            tickUpper: (_activeId + upperBin) >> 1, // round down
            tickLower: (_activeId + lowerBin) >> 1, // round down
            fee: 30
        });

        prevPriceInfo = priceInfo;

        _share >>= 1;

        _mint(address(0), _share, _share, _share, _share);

        initiator = _initiator;
    }

    function sweep(address recipient, bool zeroOrOne, uint256 amount) external override returns (uint256 available) {
        require(msg.sender == factory.owner(), INVALID_ADDRESS());
        address token = zeroOrOne ? token0 : token1;
        uint256 totalBalance = zeroOrOne
            ? (poolInfo.totalBalance0Long + poolInfo.totalBalance0Short)
            : (poolInfo.totalBalance1Long + poolInfo.totalBalance1Short);

        available = IERC20(token).balanceOf(address(this)) - totalBalance;
        available -= amount;
        TransferHelper.safeTransfer(token, recipient, amount);
    }

    /// @notice EXCLUDING FEE
    /// @notice This is only for calculating the amountOut within a single bin.
    function _getAmountFromBin(
        bool xInYOut,
        int24 binId,
        uint256 binShareOut,
        uint256 totalShareOut,
        uint256 totalAmountOut
    ) private pure returns (uint256 amountOut, uint256 maxAmountIn) {
        amountOut = PriceMath.fullMulDiv(totalAmountOut, binShareOut, totalShareOut); // won't overlow as binShareOut <= totalShareOut
        maxAmountIn = xInYOut
            ? Uint256x256Math.shiftDivRoundUp(amountOut, 128, Uint128x128Math.pow(getBase(), binId)) // getBase().pow(binId) = price128.128
            : Uint256x256Math.mulShiftRoundUp(amountOut, Uint128x128Math.pow(getBase(), binId), 128); // getBase().pow(binId) = price128.128
    }

    function swap(address recipient, bool xInYOut, uint256 amountIn)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        require(amountIn != 0, INVALID_AMOUNT());
        uint256 totalBal0 = poolInfo.totalBalance0Long + poolInfo.totalBalance0Short;
        uint256 totalBal1 = poolInfo.totalBalance1Long + poolInfo.totalBalance1Short;

        (address tokenIn, address tokenOut) = xInYOut ? (token0, token1) : (token1, token0);
        TransferHelper.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);

        PoolInfo storage _pool = poolInfo;
        PriceInfo storage _priceInfo = priceInfo;
        int24 binId = _priceInfo.activeId;
        (uint256 totalShareIn, uint256 totalShareOut) = xInYOut
            ? (_pool.totalTokenShare0, _pool.totalTokenShare1)
            : (_pool.totalTokenShare1, _pool.totalTokenShare0);

        uint256 binShareIn;
        uint256 binShareOut;
        uint256 available;
        uint256 feeAmount;
        uint256 additionalShareIn;
        uint256 maxAmountIn;

        while (true) {
            BinInfo storage _bin = bins[binId];
            (binShareIn, binShareOut) = xInYOut ? (_bin.binShare0, _bin.binShare1) : (_bin.binShare1, _bin.binShare0);
            (available, maxAmountIn) = _getAmountFromBin(xInYOut, binId, binShareOut, totalShareOut, totalBalOut);

            if (available == 0) {
                if (amountOut != 0) {
                    TransferHelper.safeTransfer(tokenIn, recipient, amountIn); // refund
                    maxAmountIn = 0;
                    amountIn = 0;
                }
            } else if (amountIn >= maxAmountIn) {
                amountIn -= maxAmountIn;
                amountOut += available;
                totalShareOut -= binShareOut;
                binShareOut = 0;
            } else {
                uint256 useAmountOut = PriceMath.fullMulDiv(amountIn, available, maxAmountIn); // won't overlow as remainingAmount < balIn
                amountOut += useAmountOut;
                uint256 removedShareOut = PriceMath.fullMulDiv(binShareOut, useAmountOut, available); // won't overlow as useAmountOut < available
                binShareOut -= removedShareOut;
                totalShareOut -= removedShareOut;
                maxAmountIn = amountIn;
                amountIn = 0;
            }

            // Unified share calculation and update
            additionalShareIn = PriceMath.fullMulDiv(maxAmountIn, totalShareIn, balInBefore);
            binShareIn += additionalShareIn;
            totalShareIn += additionalShareIn;

            _bin.binShare0 = xInYOut ? binShareIn : binShareOut;
            _bin.binShare1 = xInYOut ? binShareOut : binShareIn;

            if (amountIn == 0) break;
            /// @dev in case of a perfect drain, we don't increase binShareOut and it's fine
            /// because we already scaled the share by 128 bits, so no oveflow is expected in this lifetime.
            // feeShare does not need to be updated, and so the feeAmount will be portionally shared by all bins available

            bool crossTick;
            if (xInYOut) {
                require(binId > MIN_BIN_ID, INVALID_BIN_ID());
                binId--;
                if (binId < _pool.tickLower) {
                    crossTick = true;
                }
            } else {
                require(binId < MAX_BIN_ID, INVALID_BIN_ID());
                binId++;
                if (binId > _pool.tickUpper) {
                    crossTick = true;
                }
            }

            if (crossTick) {
                //activate ALC expansion here
            }
            crossTick = false;
        }

        _pool.totalTokenShare0 = xInYOut ? totalShareIn : totalShareOut;
        _pool.totalTokenShare1 = xInYOut ? totalShareOut : totalShareIn;
        _priceInfo.activeId = binId;

        if (amountOut != 0) {
            uint256 fee = FeeTier.getFee(_priceInfo.maxId - _priceInfo.minId, amountOut);
            //fee needs to be in the while loop if we want to update the fee based on ALC
            amountOut -= fee;
            if (xInYOut) {}
            TransferHelper.safeTransfer(tokenOut, recipient, amountOut);
        } else {
            revert INSUFFICIENT_LIQUIDITY();
        }

        return amountOut;
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
