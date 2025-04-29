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

    mapping(int24 binId => uint256 binshare) private bins; // share is stored as 128.128 fixed point

    address public immutable override factory;

    PoolInfo private poolInfo;

    constructor(
        address _tokenX,
        address _tokenY,
        int24 _activeId,
        address _initiator,
        string memory name,
        string memory symbol
    ) Ax11Lp(name, symbol) {
        factory = msg.sender;
        initialize(_tokenX, _tokenY, _activeId, _initiator);
    }

    function getPoolInfo() public view override returns (PoolInfo memory) {
        return poolInfo;
    }

    function setInitiator(address _initiator) external override {
        require(msg.sender == poolInfo.initiator, INVALID_ADDRESS());
        poolInfo.initiator = _initiator;
    }

    function checkBinIdLimit(int24 value) private pure {
        require(value >= -88767 && value <= 88767, INVALID_BIN_ID());
    }

    /// @dev equivalent to (1001>>128)/1000, which is 1.001 in 128.128 fixed point
    function getBase() private pure returns (uint256) {
        return 340622649287859401926837982039199979667;
    }
    /// @notice EXCLUDING FEE
    /// @notice This is only for calculating the amountIn within a single bin.

    function _getAmountInFromBin(bool xInYOut, int24 binId, uint256 balance)
        private
        pure
        returns (uint256 maxAmountIn, uint256 price)
    {
        price = Uint128x128Math.pow(getBase(), binId);
        maxAmountIn = xInYOut
            ? Uint256x256Math.shiftDivRoundUp(balance, 128, price) // getBase().pow(binId) = price128.128
            : Uint256x256Math.mulShiftRoundUp(balance, price, 128); // getBase().pow(binId) = price128.128
    }

    /// @notice This function is used to calculate the amountIn for the next bin
    /// the previous price should be dervied from `_getAmountInFromBin`
    /// this will save gas by not calculating the price with pow() again
    function _getAmountInFromNextBin(bool xInYOut, uint256 previousPrice, uint256 balance)
        private
        pure
        returns (uint256 maxAmountIn, uint256 price)
    {
        if (xInYOut) {
            price = ((previousPrice * 1001) / 1000);
            maxAmountIn = Uint256x256Math.shiftDivRoundUp(balance, 128, price);
        } else {
            price = ((previousPrice * 1000) / 1001);
            maxAmountIn = Uint256x256Math.mulShiftRoundUp(balance, price, 128);
        }
    }

    /// @notice Initialize the pool
    /// @param _activeId The active bin id
    /// @param _initiator The initiator of the pool
    /// @dev we assume the amount received by the pool is ALWAYS equal to transferFrom value of 512
    /// Note: meaning that we don't support fee-on-transfer tokens
    function initialize(address _tokenX, address _tokenY, int24 _activeId, address _initiator) private {
        TransferHelper.safeTransferFrom(_tokenX, _initiator, address(this), 1024);
        TransferHelper.safeTransferFrom(_tokenY, _initiator, address(this), 1024);

        int24 _lowestId = _activeId - 511;
        int24 _highestId = _activeId + 511;
        checkBinIdLimit(_lowestId);
        checkBinIdLimit(_highestId);
        int24 iteration = _activeId;
        uint256 _binShare = 2 << 128; // 2 tokens/bin, scaling as 128.128 fixed point

        while (iteration < _highestId) {
            iteration++;
            bins[iteration] = _binShare;
        }
        iteration = _activeId;
        while (iteration > _lowestId) {
            iteration--;
            bins[iteration] = _binShare;
        }

        uint256 _tokenShare = 1024 << 128; // scaling as 128.128 fixed point
        uint256 _lpShare = _tokenShare >> 1; // half of the token share

        int24 tickX = (_activeId + _lowestId) >> 1;
        int24 tickY = (_activeId + _highestId) >> 1;

        poolInfo = PoolInfo({
            tokenX: _tokenX,
            tokenY: _tokenY,
            initiator: _initiator,
            totalBalanceXLong: 512,
            totalBalanceYLong: 512,
            totalBalanceXShort: 512,
            totalBalanceYShort: 512,
            totalBinShareX: _tokenShare,
            totalBinShareY: _tokenShare,
            activeBinShareX: _binShare,
            activeBinShareY: _binShare,
            activeId: _activeId,
            lowestId: _lowestId,
            highestId: _highestId,
            tickXUpper: tickX, // midpoint,round down
            tickYUpper: tickY, // midpoint,round down
            tickXLower: (_activeId + tickX) >> 1, // midpoint,round down
            tickYLower: (_activeId + tickY) >> 1, // midpoint,round down
            targetTimestamp: uint88(block.timestamp)
        });

        _mint(address(0), _lpShare, _lpShare, _lpShare, _lpShare);
    }

    /// @dev Note: this function assumes that BalanceXLong,YLong, XShort, YShort will never be zero
    /// The prevention is implemented in the swap function, disallowing complete depletion of liquidity
    function mint(LiquidityOption calldata option)
        external
        override
        ensure(option.deadline)
        nonReentrant
        noDelegateCall
        returns (uint256 LPXLong, uint256 LPYLong, uint256 LPXShort, uint256 LPYShort)
    {
        address sender = msg.sender;
        int24 binId = poolInfo.activeId;
        require(binId >= option.minActiveId && binId <= option.maxActiveId, SLIPPAGE_EXCEEDED());

        uint256 amountX;
        uint256 amountY;
        uint256 bal;

        if (option.amountForLongX != 0) {
            bal = poolInfo.totalBalanceXLong;
            LPXLong = PriceMath.fullMulDivUnchecked(option.amountForLongX, _totalSupply.longX, bal); // overflow is not realistic, bal can't be 0.
            amountX += option.amountForLongX;
            bal += option.amountForLongX;
            poolInfo.totalBalanceXLong = bal.safe128();
        }
        if (option.amountForLongY != 0) {
            bal = poolInfo.totalBalanceYLong;
            LPYLong = PriceMath.fullMulDivUnchecked(option.amountForLongY, _totalSupply.longY, bal); // overflow is not realistic, bal can't be 0.
            amountY += option.amountForLongY;
            bal += option.amountForLongY;
            poolInfo.totalBalanceYLong = bal.safe128();
        }
        if (option.amountForShortX != 0) {
            bal = poolInfo.totalBalanceXShort;
            LPXShort = PriceMath.fullMulDivUnchecked(option.amountForShortX, _totalSupply.shortX, bal); // overflow is not realistic, bal can't be 0.
            amountX += option.amountForShortX;
            bal += option.amountForShortX;
            poolInfo.totalBalanceXShort = bal.safe128();
        }
        if (option.amountForShortY != 0) {
            bal = poolInfo.totalBalanceYShort;
            LPYShort = PriceMath.fullMulDivUnchecked(option.amountForShortY, _totalSupply.shortY, bal); // overflow is not realistic, bal can't be 0.
            amountY += option.amountForShortY;
            bal += option.amountForShortY;
            poolInfo.totalBalanceYShort = bal.safe128();
        }

        if (amountX != 0) TransferHelper.safeTransferFrom(poolInfo.tokenX, sender, address(this), amountX);
        if (amountY != 0) TransferHelper.safeTransferFrom(poolInfo.tokenY, sender, address(this), amountY);

        _mint(option.recipient, LPXLong, LPYLong, LPXShort, LPYShort);
    }

    /// @dev Note: this function assumes that BalanceXLong,YLong, XShort, YShort will never be zero
    /// The prevention is implemented in the swap function, disallowing complete depletion of liquidity
    function burn(LiquidityOption calldata option)
        external
        override
        ensure(option.deadline)
        nonReentrant
        noDelegateCall
        returns (uint256 amountX, uint256 amountY)
    {
        address sender = msg.sender;
        int24 binId = poolInfo.activeId;
        require(binId >= option.minActiveId && binId <= option.maxActiveId, SLIPPAGE_EXCEEDED());

        uint256 balXLong = poolInfo.totalBalanceXLong;
        uint256 balYLong = poolInfo.totalBalanceYLong;
        uint256 balXShort = poolInfo.totalBalanceXShort;
        uint256 balYShort = poolInfo.totalBalanceYShort;

        uint256 totalBalX = balXLong + balXShort;
        uint256 totalBalY = balYLong + balYShort;

        uint256 amountDeducted;

        if (option.amountForLongX != 0) {
            amountDeducted = PriceMath.fullMulDivUnchecked(option.amountForLongX, balXLong, _totalSupply.longX); // overflow is not realistic, _totalSupply can't be 0.
            balXLong -= amountDeducted;
            amountX += amountDeducted;
            require(balXLong != 0, MINIMUM_LIQUIDITY_EXCEEDED());
            poolInfo.totalBalanceXLong = balXLong.safe128();
        }
        if (option.amountForLongY != 0) {
            amountDeducted = PriceMath.fullMulDivUnchecked(option.amountForLongY, balYLong, _totalSupply.longY); // overflow is not realistic, _totalSupply can't be 0.
            balYLong -= amountDeducted;
            amountY += amountDeducted;
            require(balYLong != 0, MINIMUM_LIQUIDITY_EXCEEDED());
            poolInfo.totalBalanceYLong = balYLong.safe128();
        }
        if (option.amountForShortX != 0) {
            amountDeducted = PriceMath.fullMulDivUnchecked(option.amountForShortX, balXShort, _totalSupply.shortX); // overflow is not realistic, _totalSupply can't be 0.
            balXShort -= amountDeducted;
            amountX += amountDeducted;
            require(balXShort != 0, MINIMUM_LIQUIDITY_EXCEEDED());
            poolInfo.totalBalanceXShort = balXShort.safe128();
        }
        if (option.amountForShortY != 0) {
            amountDeducted = PriceMath.fullMulDivUnchecked(option.amountForShortY, balYShort, _totalSupply.shortY); // overflow is not realistic, _totalSupply can't be 0.
            balYShort -= amountDeducted;
            amountY += amountDeducted;
            require(balYShort != 0, MINIMUM_LIQUIDITY_EXCEEDED());
            poolInfo.totalBalanceYShort = balYShort.safe128();
        }

        totalBalX -= amountX;
        totalBalY -= amountY;

        if (totalBalX < 1024) amountX -= (1024 - totalBalX);
        if (totalBalY < 1024) amountY -= (1024 - totalBalY);
        /// @dev if a user's share is too large that it covers almost the entire pool, they need to leave the minimum liquidity in the pool.
        /// so they may be able to withdraw 99.999xxx% of their funds.

        _burn(sender, option.amountForLongX, option.amountForLongY, option.amountForShortX, option.amountForShortY);

        if (amountX != 0) TransferHelper.safeTransfer(poolInfo.tokenX, sender, amountX);
        if (amountY != 0) TransferHelper.safeTransfer(poolInfo.tokenY, sender, amountY);
    }

    /// @dev Note: this function assumes that BalanceXLong,YLong, XShort, YShort will never be zero
    /// The prevention is implemented in the swap and burn function, disallowing complete depletion of liquidity
    function flash(address recipient, address callback, uint256 amountX, uint256 amountY)
        external
        nonReentrant
        noDelegateCall
    {
        address tokenX = poolInfo.tokenX;
        address tokenY = poolInfo.tokenY;

        uint256 balanceXBefore;
        uint256 balanceYBefore;
        uint256 feeX;
        uint256 feeY;

        uint256 balanceAfter;
        uint256 totalBalLong;
        uint256 totalBalShort;

        if (amountX != 0) {
            balanceXBefore = IERC20(tokenX).balanceOf(address(this));
            feeX = PriceMath.divUp(amountX, 10000); // 0.01% fee
            TransferHelper.safeTransfer(tokenX, recipient, amountX);
        }
        if (amountY != 0) {
            balanceYBefore = IERC20(tokenY).balanceOf(address(this));
            feeY = PriceMath.divUp(amountY, 10000); // 0.01% fee
            TransferHelper.safeTransfer(tokenY, recipient, amountY);
        }

        IAx11FlashCallback(callback).flashCallback(feeX, feeY);

        if (amountX != 0) {
            balanceAfter = IERC20(tokenX).balanceOf(address(this));
            require(balanceAfter >= (balanceXBefore + feeX), FLASH_INSUFFICIENT_BALANCE());
            totalBalLong = PriceMath.fullMulDivUnchecked(balanceAfter, poolInfo.totalBalanceXLong, balanceXBefore); // overflow is not realistic
            totalBalShort = balanceAfter - totalBalLong;
            poolInfo.totalBalanceXLong = totalBalLong.safe128();
            poolInfo.totalBalanceXShort = totalBalShort.safe128();
        }
        if (amountY != 0) {
            balanceAfter = IERC20(tokenY).balanceOf(address(this));
            require(balanceAfter >= (balanceYBefore + feeY), FLASH_INSUFFICIENT_BALANCE());
            totalBalLong = PriceMath.fullMulDivUnchecked(balanceAfter, poolInfo.totalBalanceYLong, balanceYBefore); // overflow is not realistic
            totalBalShort = balanceAfter - totalBalLong;
            poolInfo.totalBalanceYLong = totalBalLong.safe128();
            poolInfo.totalBalanceYShort = totalBalShort.safe128();
        }
    }

    function swap(address recipient, bool xInYOut, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        ensure(deadline)
        nonReentrant
        noDelegateCall
        returns (uint256 amountOut)
    {
        require(amountIn != 0 && minAmountOut != 0, INVALID_AMOUNT());
        uint256 totalBalXLong = poolInfo.totalBalanceXLong;
        uint256 totalBalXShort = poolInfo.totalBalanceXShort;
        uint256 totalBalYLong = poolInfo.totalBalanceYLong;
        uint256 totalBalYShort = poolInfo.totalBalanceYShort;

        uint256 totalBalX = totalBalXLong + totalBalXShort;
        uint256 totalBalY = totalBalYLong + totalBalYShort;
        int24 binId = poolInfo.activeId;

        address tokenIn;
        address tokenOut;
        uint256 totalBalIn;
        uint256 totalBalOut;
        uint256 binShareIn;
        uint256 binShareOut;
        uint256 totalBinShareIn;
        uint256 totalBinShareOut;

        if (xInYOut) {
            tokenIn = poolInfo.tokenX;
            tokenOut = poolInfo.tokenY;
            totalBalIn = totalBalX;
            totalBalOut = totalBalY;
            binShareIn = poolInfo.activeBinShareX;
            binShareOut = poolInfo.activeBinShareY;
            totalBinShareIn = poolInfo.totalBinShareX;
            totalBinShareOut = poolInfo.totalBinShareY;
        } else {
            tokenIn = poolInfo.tokenY;
            tokenOut = poolInfo.tokenX;
            totalBalIn = totalBalY;
            totalBalOut = totalBalX;
            binShareIn = poolInfo.activeBinShareY;
            binShareOut = poolInfo.activeBinShareX;
            totalBinShareIn = poolInfo.totalBinShareY;
            totalBinShareOut = poolInfo.totalBinShareX;
        }

        TransferHelper.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);

        uint256 binAmountOut = PriceMath.fullMulDivUnchecked(totalBalOut, binShareOut, totalBinShareOut); // overflow is not realistic
        (uint256 maxAmountIn, uint256 price) = _getAmountInFromBin(xInYOut, binId, binAmountOut);
        uint256 usedBinShareOut;

        while (true) {
            /// @dev update bin share within the loop
            if (amountIn >= maxAmountIn) {
                amountIn -= maxAmountIn;
                amountOut += binAmountOut;
                totalBalOut -= binAmountOut; // update total balance out
                usedBinShareOut = binShareOut;
                binShareOut = 0;
            } else {
                uint256 usedAmountOut = PriceMath.fullMulDiv(amountIn, binAmountOut, maxAmountIn); // maxAmountIn can be 0 (case: perfect drain)
                amountOut += usedAmountOut;
                totalBalOut -= usedAmountOut; // update total balance out
                usedBinShareOut = PriceMath.fullMulDiv(usedAmountOut, binShareOut, binAmountOut); // binAmountOut can be 0 (case: perfect drain)
                binShareOut -= usedBinShareOut;
                maxAmountIn = amountIn;
                amountIn = 0;
            }
            totalBalIn += maxAmountIn; // update total balance in
            uint256 binShareInGain = PriceMath.fullMulDivUnchecked(maxAmountIn, totalBinShareIn, totalBalIn); // overflow is not realistic
            binShareIn += binShareInGain;
            totalBinShareIn += binShareInGain; // update total bin share
            totalBinShareOut -= usedBinShareOut; // update total bin share

            if (amountIn == 0) break; // delete bins[binId] is not necessary
            // because if we pass the bin, it will set the new value in the next line
            // and if it stays, we can just leave it, because we'll only use the activeBinShareX/Y in poolInfo

            bins[binId] = binShareIn; // add to new bin
            binId = xInYOut ? binId + 1 : binId - 1;
            checkBinIdLimit(binId);
            binShareIn = 0;
            binShareOut = bins[binId];

            binAmountOut = PriceMath.fullMulDivUnchecked(totalBalOut, binShareOut, totalBinShareOut); // overflow is not realistic
            (maxAmountIn, price) = _getAmountInFromNextBin(xInYOut, price, binAmountOut);
        }

        /// @dev update pool storage after the loop
        if (xInYOut) {
            totalBalXLong = PriceMath.fullMulDivUnchecked(totalBalIn, totalBalXLong, totalBalX); // overflow is not realistic
            totalBalXShort = totalBalIn - totalBalXLong;
            totalBalYLong = PriceMath.fullMulDivUnchecked(totalBalOut, totalBalYLong, totalBalY); // overflow is not realistic
            totalBalYShort = totalBalOut - totalBalYLong;
        } else {
            totalBalYLong = PriceMath.fullMulDivUnchecked(totalBalIn, totalBalYLong, totalBalY); // overflow is not realistic
            totalBalYShort = totalBalIn - totalBalYLong;
            totalBalXLong = PriceMath.fullMulDivUnchecked(totalBalOut, totalBalXLong, totalBalX); // overflow is not realistic
            totalBalXShort = totalBalOut - totalBalXLong;
        }

        require(totalBalIn >= 1024 && totalBalOut >= 1024, MINIMUM_LIQUIDITY_EXCEEDED());
        require(
            totalBalXLong != 0 && totalBalYLong != 0 && totalBalXShort != 0 && totalBalYShort != 0,
            MINIMUM_LIQUIDITY_EXCEEDED()
        );

        poolInfo.totalBalanceXLong = totalBalXLong.safe128();
        poolInfo.totalBalanceYLong = totalBalYLong.safe128();
        poolInfo.totalBalanceXShort = totalBalXShort.safe128();
        poolInfo.totalBalanceYShort = totalBalYShort.safe128();
        poolInfo.totalBinShareX = xInYOut ? totalBinShareIn : totalBinShareOut;
        poolInfo.totalBinShareY = xInYOut ? totalBinShareOut : totalBinShareIn;
        poolInfo.activeBinShareX = xInYOut ? binShareIn : binShareOut;
        poolInfo.activeBinShareY = xInYOut ? binShareOut : binShareIn;
        poolInfo.activeId = binId;

        /// TODO: should also update priceInfo here ...............
        // TODO: also dont forget to incorporate fee into calculation, short and long balance must change

        require(amountOut >= minAmountOut, SLIPPAGE_EXCEEDED());
        TransferHelper.safeTransfer(tokenOut, recipient, amountOut);

        //TODO: uint24 range = uint24(_priceInfo.highestId - _priceInfo.lowestId + 1); // we will come back to fix this because highestId and lowestId can be updated
    }
}
