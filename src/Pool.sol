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
    PoolInfo private poolInfo;
    PriceInfo private priceInfo;
    PriceInfo private prevPriceInfo;

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
        require(msg.sender == factory, INVALID_ADDRESS());
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

    function swap(address recipient, bool xInYOut, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        ensure(deadline)
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

            if (newBalYShort + fee >= range) {
                // ensure sufficient liquidity
                newBalYShort -= fee;
                newBalYLong += fee;
            }
            newBalYLong += fee; // twice

            if (newBalXLong + fee >= range) {
                // ensure sufficient liquidity
                newBalXLong -= feeInAmountIn;
                newBalXShort += feeInAmountIn;
            }
        } else {
            newBalXLong = PriceMath.fullMulDiv(totalBalOut, _pool.balanceXLong, totalBalX);
            newBalYLong = PriceMath.fullMulDiv(totalBalIn, _pool.balanceYLong, totalBalY);
            newBalXShort = totalBalOut - newBalXLong;
            newBalYShort = totalBalIn - newBalYLong;

            if (newBalXShort + fee >= range) {
                // ensure sufficient liquidity
                newBalXShort -= fee;
                newBalXLong += fee;
            }
            newBalXLong += fee; // twice

            if (newBalYLong + fee >= range) {
                // ensure sufficient liquidity
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
        override
        ensure(option.deadline)
        nonReentrant
        returns (uint256 LPXLong, uint256 LPYLong, uint256 LPXShort, uint256 LPYShort)
    {
        address sender = msg.sender;
        int24 binId = priceInfo.activeId;
        require(binId >= option.minActiveId && binId <= option.maxActiveId, SLIPPAGE_EXCEEDED());
        uint256 amountX;
        uint256 amountY;

        PoolInfo storage _pool = poolInfo;

        if (option.amountForLongX != 0) {
            LPXLong = PriceMath.fullMulDiv(option.amountForLongX, _pool.LPShareXLong, _pool.balanceXLong);
            amountX += option.amountForLongX;
            _pool.balanceXLong += option.amountForLongX;
            _pool.LPShareXLong += LPXLong;
        }
        if (option.amountForShortX != 0) {
            LPXShort = PriceMath.fullMulDiv(option.amountForShortX, _pool.LPShareXShort, _pool.balanceXShort);
            amountX += option.amountForShortX;
            _pool.balanceXShort += option.amountForShortX;
            _pool.LPShareXShort += LPXShort;
        }
        if (option.amountForLongY != 0) {
            LPYLong = PriceMath.fullMulDiv(option.amountForLongY, _pool.LPShareYLong, _pool.balanceYLong);
            amountY += option.amountForLongY;
            _pool.balanceYLong += option.amountForLongY;
            _pool.LPShareYLong += LPYLong;
        }
        if (option.amountForShortY != 0) {
            LPYShort = PriceMath.fullMulDiv(option.amountForShortY, _pool.LPShareYShort, _pool.balanceYShort);
            amountY += option.amountForShortY;
            _pool.balanceYShort += option.amountForShortY;
            _pool.LPShareYShort += LPYShort;
        }

        if (amountX != 0) TransferHelper.safeTransferFrom(tokenX, sender, address(this), amountX);
        if (amountY != 0) TransferHelper.safeTransferFrom(tokenY, sender, address(this), amountY);

        _mint(option.recipient, LPXLong, LPYLong, LPXShort, LPYShort);
    }

    function burn(LiquidityOption calldata option)
        external
        override
        ensure(option.deadline)
        nonReentrant
        returns (uint256 amountX, uint256 amountY)
    {
        address sender = msg.sender;
        PoolInfo storage _pool = poolInfo;
        uint256 amountDeducted;
        // Calculate amounts to withdraw based on LP shares
        if (option.amountForLongX != 0) {
            amountDeducted = PriceMath.fullMulDiv(option.amountForLongX, _pool.balanceXLong, _pool.LPShareXLong);
            _pool.balanceXLong -= amountDeducted;
            _pool.LPShareXLong -= option.amountForLongX;
            amountX += amountDeducted;
        }
        if (option.amountForShortX != 0) {
            amountDeducted = PriceMath.fullMulDiv(option.amountForShortX, _pool.balanceXShort, _pool.LPShareXShort);
            _pool.balanceXShort -= amountDeducted;
            _pool.LPShareXShort -= option.amountForShortX;
            amountX += amountDeducted;
        }
        if (option.amountForLongY != 0) {
            amountDeducted = PriceMath.fullMulDiv(option.amountForLongY, _pool.balanceYLong, _pool.LPShareYLong);
            _pool.balanceYLong -= amountDeducted;
            _pool.LPShareYLong -= option.amountForLongY;
            amountY += amountDeducted;
        }
        if (option.amountForShortY != 0) {
            amountDeducted = PriceMath.fullMulDiv(option.amountForShortY, _pool.balanceYShort, _pool.LPShareYShort);
            _pool.balanceYShort -= amountDeducted;
            _pool.LPShareYShort -= option.amountForShortY;
            amountY += amountDeducted;
        }

        // Burn LP tokens
        _burn(sender, option.amountForLongX, option.amountForLongY, option.amountForShortX, option.amountForShortY);

        // Transfer tokens back to sender
        if (amountX != 0) TransferHelper.safeTransfer(tokenX, sender, amountX);
        if (amountY != 0) TransferHelper.safeTransfer(tokenY, sender, amountY);
    }

    //function flash
}
