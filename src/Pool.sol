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
import {SafeCast} from "./libraries/Math/SafeCast.sol";
import {NoDelegateCall} from "./abstracts/NoDelegateCall.sol";
import {IAx11FlashCallback} from "./interfaces/IAx11FlashCallback.sol";

contract Pool is Ax11Lp, IPool, ReentrancyGuard, Deadline, NoDelegateCall {
    using SafeCast for uint256;

    mapping(int24 binId => uint256 share) public bins; // share is stored as 128.128 fixed point

    PoolInfo private poolInfo;
    PriceInfo private priceInfo;
    MarketBin private marketBin;

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

    function getPoolInfo() public view override returns (PoolInfo memory) {
        return poolInfo;
    }

    function getPriceInfo() public view override returns (PriceInfo memory) {
        return priceInfo;
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

        int24 _minId = _activeId - 511;
        int24 _maxId = _activeId + 511;
        require(_minId >= MIN_BIN_ID && _maxId <= MAX_BIN_ID, INVALID_BIN_ID());

        marketBin = MarketBin({shareX: 1, shareY: 1});
        int24 iteration = _activeId;
        uint256 _binShare = 1 << 128; // scaling as 128.128 fixed point
        while (iteration < _maxId) {
            iteration++;
            bins[iteration] = _binShare;
        }
        iteration = _activeId;
        while (iteration > _minId) {
            iteration--;
            bins[iteration] = _binShare;
        }

        uint256 _tokenShare = 512 << 128; // scaling as 128.128 fixed point
        uint256 _lpShare = _tokenShare >> 1; // half of the token share

        poolInfo = PoolInfo({
            totalBalanceXLong: 256,
            totalBalanceYLong: 256,
            totalBalanceXShort: 256,
            totalBalanceYShort: 256,
            totalBinShareX: _tokenShare,
            totalBinShareY: _tokenShare,
            totalLPShareXLong: _lpShare,
            totalLPShareYLong: _lpShare,
            totalLPShareXShort: _lpShare,
            totalLPShareYShort: _lpShare
        });

        priceInfo = PriceInfo({
            activeId: _activeId,
            minId: _minId,
            maxId: _maxId,
            tickUpper: (_activeId + _maxId) >> 1, // midpoint,round down
            tickLower: (_activeId + _minId) >> 1, // midpoint,round down
            fee: 30
        });

        initiator = _initiator;
        _mint(address(0), _lpShare, _lpShare, _lpShare, _lpShare);
    }

    function mint(LiquidityOption calldata option)
        external
        override
        ensure(option.deadline)
        nonReentrant
        noDelegateCall
        returns (uint256 LPXLong, uint256 LPYLong, uint256 LPXShort, uint256 LPYShort)
    {
        require(
            option.amountForLongX != 0 || option.amountForLongY != 0 || option.amountForShortX != 0
                || option.amountForShortY != 0,
            INVALID_AMOUNT()
        ); // at least one of the amount should not be 0
        address sender = msg.sender;
        int24 binId = priceInfo.activeId;
        require(binId >= option.minActiveId && binId <= option.maxActiveId, SLIPPAGE_EXCEEDED());

        uint256 amountX;
        uint256 amountY;

        PoolInfo storage _pool = poolInfo;

        if (option.amountForLongX != 0) {
            LPXLong = PriceMath.fullMulDiv(option.amountForLongX, _pool.totalLPShareXLong, _pool.totalBalanceXLong);
            amountX += option.amountForLongX;
            _pool.totalBalanceXLong += option.amountForLongX;
            _pool.totalLPShareXLong += LPXLong;
        }
        if (option.amountForLongY != 0) {
            LPYLong = PriceMath.fullMulDiv(option.amountForLongY, _pool.totalLPShareYLong, _pool.totalBalanceYLong);
            amountY += option.amountForLongY;
            _pool.totalBalanceYLong += option.amountForLongY;
            _pool.totalLPShareYLong += LPYLong;
        }
        if (option.amountForShortX != 0) {
            LPXShort = PriceMath.fullMulDiv(option.amountForShortX, _pool.totalLPShareXShort, _pool.totalBalanceXShort);
            amountX += option.amountForShortX;
            _pool.totalBalanceXShort += option.amountForShortX;
            _pool.totalLPShareXShort += LPXShort;
        }
        if (option.amountForShortY != 0) {
            LPYShort = PriceMath.fullMulDiv(option.amountForShortY, _pool.totalLPShareYShort, _pool.totalBalanceYShort);
            amountY += option.amountForShortY;
            _pool.totalBalanceYShort += option.amountForShortY;
            _pool.totalLPShareYShort += LPYShort;
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
        noDelegateCall
        returns (uint256 amountX, uint256 amountY)
    {
        require(
            option.amountForLongX != 0 || option.amountForLongY != 0 || option.amountForShortX != 0
                || option.amountForShortY != 0,
            INVALID_AMOUNT()
        ); // at least one of the amount should not be 0
        address sender = msg.sender;
        int24 binId = priceInfo.activeId;
        require(binId >= option.minActiveId && binId <= option.maxActiveId, SLIPPAGE_EXCEEDED());

        uint128 amountDeducted;

        PoolInfo storage _pool = poolInfo;

        if (option.amountForLongX != 0) {
            amountDeducted =
                PriceMath.fullMulDiv(option.amountForLongX, _pool.totalBalanceXLong, _pool.totalLPShareXLong).safe128();
            _pool.totalBalanceXLong -= amountDeducted;
            _pool.totalLPShareXLong -= option.amountForLongX;
            amountX += amountDeducted;
        }
        if (option.amountForLongY != 0) {
            amountDeducted =
                PriceMath.fullMulDiv(option.amountForLongY, _pool.totalBalanceYLong, _pool.totalLPShareYLong).safe128();
            _pool.totalBalanceYLong -= amountDeducted;
            _pool.totalLPShareYLong -= option.amountForLongY;
            amountY += amountDeducted;
        }
        if (option.amountForShortX != 0) {
            amountDeducted = PriceMath.fullMulDiv(
                option.amountForShortX, _pool.totalBalanceXShort, _pool.totalLPShareXShort
            ).safe128();
            _pool.totalBalanceXShort -= amountDeducted;
            _pool.totalLPShareXShort -= option.amountForShortX;
            amountX += amountDeducted;
        }
        if (option.amountForShortY != 0) {
            amountDeducted = PriceMath.fullMulDiv(
                option.amountForShortY, _pool.totalBalanceYShort, _pool.totalLPShareYShort
            ).safe128();
            _pool.totalBalanceYShort -= amountDeducted;
            _pool.totalLPShareYShort -= option.amountForShortY;
            amountY += amountDeducted;
        }

        _burn(sender, option.amountForLongX, option.amountForLongY, option.amountForShortX, option.amountForShortY);

        if (amountX != 0) TransferHelper.safeTransfer(tokenX, sender, amountX);
        if (amountY != 0) TransferHelper.safeTransfer(tokenY, sender, amountY);
    }

    function flash(address recipient, address callback, uint128 amountX, uint128 amountY)
        external
        nonReentrant
        noDelegateCall
    {
        require(amountX != 0 && amountY != 0, INVALID_AMOUNT()); // at least one of the amount should not be 0
        uint128 feeX = PriceMath.divUp(amountX, 10000); // 0.01% fee
        uint128 feeY = PriceMath.divUp(amountY, 10000); // 0.01% fee
        uint128 balanceXBefore = IERC20(tokenX).balanceOf(address(this));
        uint128 balanceYBefore = IERC20(tokenY).balanceOf(address(this));

        if (amountX != 0) TransferHelper.safeTransfer(tokenX, recipient, amountX);
        if (amountY != 0) TransferHelper.safeTransfer(tokenY, recipient, amountY);

        IAx11FlashCallback(callback).flashCallback(feeX, feeY);

        uint128 balanceXAfter = IERC20(tokenX).balanceOf(address(this));
        uint128 balanceYAfter = IERC20(tokenY).balanceOf(address(this));

        require(
            balanceXAfter >= balanceXBefore + feeX && balanceYAfter >= balanceYBefore + feeY, INSUFFICIENT_BALANCE()
        );
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

    function swap(address recipient, bool xInYOut, uint128 amountIn, uint128 minAmountOut, uint256 deadline)
        external
        ensure(deadline)
        nonReentrant
        noDelegateCall
        returns (uint128 amountOut)
    {
        require(amountIn != 0 && minAmountOut != 0, INVALID_AMOUNT());
        uint128 totalBalX = poolInfo.balanceXLong + poolInfo.balanceXShort;
        uint128 totalBalY = poolInfo.balanceYLong + poolInfo.balanceYShort;

        (address tokenIn, address tokenOut) = xInYOut ? (tokenX, tokenY) : (tokenY, tokenX);
        TransferHelper.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);

        PoolInfo storage _pool = poolInfo;
        PriceInfo storage _priceInfo = priceInfo;

        int24 binId = _priceInfo.activeId;

        (uint128 totalBalIn, uint128 totalBalOut) = xInYOut ? (totalBalX, totalBalY) : (totalBalY, totalBalX);

        uint128 binBalanceIn;
        uint128 binBalanceOut;
        uint128 maxAmountIn;

        while (true) {
            BinInfo storage _bin = bins[binId];
            (binBalanceIn, binBalanceOut) = xInYOut ? (_bin.balanceX, _bin.balanceY) : (_bin.balanceY, _bin.balanceX);

            (maxAmountIn) = _getAmountInFromBin(xInYOut, binId, binBalanceOut).safe128();

            if (amountIn >= maxAmountIn) {
                amountIn -= maxAmountIn;
                amountOut += binBalanceOut;
                totalBalOut -= binBalanceOut;
                binBalanceOut = 0;
            } else {
                uint128 useAmountOut = (PriceMath.fullMulDiv(amountIn, binBalanceOut, maxAmountIn)).safe128(); // won't overlow as remainingAmount < balIn
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

        uint24 range = uint24(_priceInfo.maxId - _priceInfo.minId + 1); // we will come back to fix this because maxId and minId can be updated
        uint128 fee = FeeTier.getFee(range, amountOut);
        uint128 feeInAmountIn = FeeTier.getFee(range, amountIn);

        uint128 newBalXLong;
        uint128 newBalYLong;
        uint128 newBalXShort;
        uint128 newBalYShort;

        if (xInYOut) {
            newBalXLong = PriceMath.fullMulDiv(totalBalIn, _pool.balanceXLong, totalBalX).safe128();
            newBalYLong = PriceMath.fullMulDiv(totalBalOut, _pool.balanceYLong, totalBalY).safe128();
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
            newBalXLong = PriceMath.fullMulDiv(totalBalOut, _pool.balanceXLong, totalBalX).safe128();
            newBalYLong = PriceMath.fullMulDiv(totalBalIn, _pool.balanceYLong, totalBalY).safe128();
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
}
