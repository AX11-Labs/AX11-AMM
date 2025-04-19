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
    address public immutable override tokenX;
    address public immutable override tokenY;
    address public override initiator;

    int24 private constant MAX_BIN_ID = 88767;
    int24 private constant MIN_BIN_ID = -88767;

    constructor(
        address _tokenX,
        address _tokenY,
        int24 _activeId,
        address _initiator,
        string memory name,
        string memory symbol
    ) Ax11Lp(name, symbol) {
        factory = msg.sender;
        tokenX = _tokenX;
        tokenY = _tokenY;
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

    /// @notice Initialize the pool
    /// @param _activeId The active bin id
    /// @param _initiator The initiator of the pool
    /// @dev we assume the amount received by the pool is ALWAYS equal to transferFrom value of 512
    /// Note: meaning that we don't support fee-on-transfer tokens
    function initialize(int24 _activeId, address _initiator) private {
        TransferHelper.safeTransferFrom(tokenX, _initiator, address(this), 512);
        TransferHelper.safeTransferFrom(tokenY, _initiator, address(this), 512);

        PoolInfo storage _poolInfo = poolInfo;

        int24 _minId = _activeId - 511;
        int24 _maxId = _activeId + 511;
        require(_minId >= MIN_BIN_ID && _maxId <= MAX_BIN_ID, INVALID_BIN_ID());

        bins[_activeId] = BinInfo({balanceX: 1, binShareY: 1});
        int24 iteration = _activeId;
        while (iteration < _maxId) {
            iteration++;
            bins[iteration] = BinInfo({balanceX: 0, binShareY: 1});
        }
        iteration = _activeId;
        while (iteration > _minId) {
            iteration--;
            bins[iteration] = BinInfo({balanceX: 1, binShareY: 0});
        }

        uint256 _share = 256 << 128; // scaling as 128.128 fixed point

        poolInfo = PoolInfo({
            balanceXLong: 256,
            balanceYLong: 256,
            balanceXShort: 256,
            balanceYShort: 256,
            LPShareXLong: _share,
            LPShareYLong: _share,
            LPShareXShort: _share,
            LPShareYShort: _share
        });

        priceInfo = PriceInfo({
            activeId: _activeId,
            minId: _minId,
            maxId: _maxId,
            tickUpper: (_activeId + _maxId) >> 1, // round down
            tickLower: (_activeId + _minId) >> 1, // round down
            fee: 30
        });

        prevPriceInfo = priceInfo;
        initiator = _initiator;
        _mint(address(0), _share, _share, _share, _share);
    }

    /// @notice Recovers tokens that are accidentally sent to the contract
    /// @dev This function can only be called by the factory owner
    ///      It calculates the excess tokens by comparing actual balance with tracked pool balance (long + short)
    ///      The excess tokens can then be swept to a specified recipient
    ///      This is useful for recovering tokens that are not part of the pool's managed liquidity
    ///      Note: This function does not support fee-on-transfer tokens
    /// @param recipient The address to receive the swept tokens
    /// @param xOrY True for tokenX (tokenX), false for tokenY (tokenY)
    /// @param amount The amount of tokens to sweep
    /// @return available The amount of tokens available for sweeping after this operation
    function sweep(address recipient, bool xOrY, uint256 amount) external override returns (uint256 available) {
        require(msg.sender == factory.sweeper(), INVALID_ADDRESS());
        address _token = xOrY ? tokenX : tokenY;
        uint256 totalBalance =
            xOrY ? (poolInfo.balanceXLong + poolInfo.balanceXShort) : (poolInfo.balanceYLong + poolInfo.balanceYShort);

        available = IERC20(_token).balanceOf(address(this)) - totalBalance;
        available -= amount;
        TransferHelper.safeTransfer(_token, recipient, amount);
    }

    /// @notice EXCLUDING FEE
    /// @notice This is only for calculating the amountIn within a single bin.
    function _getAmountInFromBin(bool xInYOut, int24 binId, uint256 balance)
        private
        pure
        returns (uint256 maxAmountIn)
    {
        maxAmountIn = xInYOut
            ? Uint256x256Math.shiftDivRoundUp(balance, 128, Uint128x128Math.pow(getBase(), binId)) // getBase().pow(binId) = price128.128
            : Uint256x256Math.mulShiftRoundUp(balance, Uint128x128Math.pow(getBase(), binId), 128); // getBase().pow(binId) = price128.128
    }

    function swap(address recipient, bool xInYOut, uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        require(amountIn != 0 && minAmountOut != 0, INVALID_AMOUNT());
        uint256 totalBalX = poolInfo.balanceXLong + poolInfo.balanceXShort;
        uint256 totalBalY = poolInfo.balanceYLong + poolInfo.balanceYShort;

        (address tokenIn, address tokenOut) = xInYOut ? (tokenX, tokenY) : (tokenY, tokenX);
        TransferHelper.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);

        PoolInfo storage _pool = poolInfo;
        PriceInfo storage _priceInfo = priceInfo;

        int24 binId = _priceInfo.activeId;

        (uint256 totalBalIn, uint256 totalBalOut) = xInYOut ? (totalBalX, totalBalY) : (totalBalY, totalBalX);

        uint256 binBalanceIn;
        uint256 binBalanceOut;
        uint256 feeAmount;
        uint256 maxAmountIn;

        while (true) {
            BinInfo storage _bin = bins[binId];
            (binBalanceIn, binBalanceOut) = xInYOut ? (_bin.balanceX, _bin.balanceY) : (_bin.balanceY, _bin.balanceX);

            (maxAmountIn) = _getAmountInFromBin(xInYOut, binId, binBalanceOut);

            if (amountIn >= maxAmountIn) {
                amountIn -= maxAmountIn;
                amountOut += binBalanceOut;
                totalBalOut -= binBalanceOut;
                binBalanceOut = 0;
            } else {
                uint256 useAmountOut = PriceMath.fullMulDiv(amountIn, binBalanceOut, maxAmountIn); // won't overlow as remainingAmount < balIn
                amountOut += useAmountOut;
                binBalanceOut -= useAmountOut;
                totalBalOut -= useAmountOut;
                maxAmountIn = amountIn;
                amountIn = 0;
            }

            // Unified share calculation and update
            binBalanceIn += maxAmountIn;
            totalBalIn += maxAmountIn;

            _bin.balanceX = xInYOut ? binBalanceIn : binBalanceOut;
            _bin.balanceY = xInYOut ? binBalanceOut : binBalanceIn;

            if (amountIn == 0) break;
            // bool crossTick;
            // if (xInYOut) {
            //     require(binId > MIN_BIN_ID, INVALID_BIN_ID());
            //     binId--;
            //     if (binId < _pool.tickLower) {
            //         crossTick = true;
            //     }
            // } else {
            //     require(binId < MAX_BIN_ID, INVALID_BIN_ID());
            //     binId++;
            //     if (binId > _pool.tickUpper) {
            //         crossTick = true;
            //     }
            // }

            // if (crossTick) {
            //     //activate ALC expansion here
            // }
            // crossTick = false;
        }

        uint256 range = _priceInfo.maxId - _priceInfo.minId + 1; // we will come back to fix this because maxId and minId can be updated
        uint256 fee = FeeTier.getFee(range, amountOut);
        uint256 feeInAmountIn = FeeTier.getFee(range, amountIn);

        uint256 newBalXLong;
        uint256 newBalYLong;
        uint256 newBalXShort;
        uint256 newBalYShort;

        if (xInYOut) {
            newBalXLong = PriceMath.fullMulDiv(totalBalIn, _pool.balanceXLong, totalBalX);
            newBalYLong = PriceMath.fullMulDiv(totalBalOut, _pool.balanceYLong, totalBalY);
            newBalXShort = totalBalIn - newBalXLong;
            newBalYShort = totalBalOut - newBalYLong;

            if (newBalYShort + fee >= range) { // ensure sufficient liquidity
                newBalYShort -= fee;
                newBalYLong += fee;
            }
            newBalYLong += fee; // twice

            if (newBalXLong + fee >= range) { // ensure sufficient liquidity
                newBalXLong -= feeInAmountIn;
                newBalXShort += feeInAmountIn;
            }
        } else {
            newBalXLong = PriceMath.fullMulDiv(totalBalOut, _pool.balanceXLong, totalBalX);
            newBalYLong = PriceMath.fullMulDiv(totalBalIn, _pool.balanceYLong, totalBalY);
            newBalXShort = totalBalOut - newBalXLong;
            newBalYShort = totalBalIn - newBalYLong;

            if (newBalXShort + fee >= range) { // ensure sufficient liquidity
                newBalXShort -= fee;
                newBalXLong += fee;
            }
            newBalXLong += fee; // twice

            if (newBalYLong + fee >= range) { // ensure sufficient liquidity
                newBalYLong -= feeInAmountIn;
                newBalYShort += feeInAmountIn;
            }
        }

        _pool.balanceXLong = newBalXLong;
        _pool.balanceYLong = newBalYLong;
        _pool.balanceXShort = newBalXShort;
        _pool.balanceYShort = newBalYShort;

        _priceInfo.activeId = binId;
        amountOut -= fee;

        if (amountOut >= minAmountOut) {
            TransferHelper.safeTransfer(tokenOut, recipient, amountOut);
        } else {
            revert SLIPPAGE_EXCEEDED();
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
