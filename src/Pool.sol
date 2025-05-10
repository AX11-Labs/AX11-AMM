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
        require(value >= -44405 && value <= 44405, INVALID_BIN_ID());
    }

    /// @dev equivalent to (1002<<128)/1000, which is 1.002 in 128.128 fixed point
    function getBase() private pure returns (uint256) {
        return 340962931654780340390301356646631747878;
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
            price = ((previousPrice * 1002) / 1000);
            maxAmountIn = Uint256x256Math.shiftDivRoundUp(balance, 128, price);
        } else {
            price = ((previousPrice * 1000) / 1002);
            maxAmountIn = Uint256x256Math.mulShiftRoundUp(balance, price, 128);
        }
    }

    /// @notice Initialize the pool
    /// @param _activeId The active bin id
    /// @param _initiator The initiator of the pool
    /// @dev we assume the amount received by the pool is ALWAYS equal to the transferFrom value of 512
    /// Note: meaning that we don't support fee-on-transfer tokens
    function initialize(address _tokenX, address _tokenY, int24 _activeId, address _initiator) private {
        TransferHelper.safeTransferFrom(_tokenX, _initiator, address(this), 512);
        TransferHelper.safeTransferFrom(_tokenY, _initiator, address(this), 512);

        int24 _lowestId = _activeId - 255;
        int24 _highestId = _activeId + 255;

        checkBinIdLimit(_lowestId);
        checkBinIdLimit(_highestId);

        uint256 _binShare = 2 << 128; // 2 tokens/bin, scaling as 128.128 fixed point
        int24 iteration = _activeId;

        while (iteration < _highestId) {
            iteration++;
            bins[iteration] = _binShare;
        }
        iteration = _activeId;
        while (iteration > _lowestId) {
            iteration--;
            bins[iteration] = _binShare;
        }

        uint256 _tokenShare = 512 << 128; // scaling as 128.128 fixed point
        uint256 _lpShare = _tokenShare >> 1; // half of the token share

        int24 _tickX = (_activeId + _lowestId) >> 1; // midpoint,round down
        int24 _tickY = (_activeId + _highestId) >> 1; // midpoint,round down

        poolInfo = PoolInfo({
            tokenX: _tokenX,
            tokenY: _tokenY,
            totalBalanceXLong: 256,
            totalBalanceYLong: 256,
            totalBalanceXShort: 256,
            totalBalanceYShort: 256,
            totalBinShareX: _tokenShare,
            totalBinShareY: _tokenShare,
            activeBinShareX: _binShare,
            activeBinShareY: _binShare,
            activeId: _activeId,
            lowestId: _lowestId,
            highestId: _highestId,
            tickX: _tickX,
            tickY: _tickY,
            twabCumulative: 0, // initialize at 1st swap
            last7daysCumulative: 0, //initialize at 1st swap
            lastBlockTimestamp: 0, // initialize at 1st swap
            last7daysTimestamp: 0, //initialize at 1st swap
            targetTimestamp: 0, // initialize at 1st swap
            initiator: _initiator
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

        uint256 feeX;
        uint256 feeY;

        if (option.amountForLongX != 0) {
            amountDeducted = PriceMath.fullMulDivUnchecked(option.amountForLongX, balXLong, _totalSupply.longX); // overflow is not realistic, _totalSupply can't be 0.
            feeX = FeeTier.getFee(uint24(binId - poolInfo.lowestId), amountDeducted);
            balXLong -= (amountDeducted - feeX);
            amountX += (amountDeducted - feeX);
            require(balXLong != 0, INSUFFICIENT_LIQUIDITY());
            poolInfo.totalBalanceXLong = balXLong.safe128();
        }
        if (option.amountForLongY != 0) {
            amountDeducted = PriceMath.fullMulDivUnchecked(option.amountForLongY, balYLong, _totalSupply.longY); // overflow is not realistic, _totalSupply can't be 0.
            feeY = FeeTier.getFee(uint24(poolInfo.highestId - binId), amountDeducted);
            balYLong -= (amountDeducted - feeY);
            amountY += (amountDeducted - feeY);
            require(balYLong != 0, INSUFFICIENT_LIQUIDITY());
            poolInfo.totalBalanceYLong = balYLong.safe128();
        }
        if (option.amountForShortX != 0) {
            amountDeducted = PriceMath.fullMulDivUnchecked(option.amountForShortX, balXShort, _totalSupply.shortX); // overflow is not realistic, _totalSupply can't be 0.
            feeX = FeeTier.getFee(uint24(binId - poolInfo.lowestId), amountDeducted);
            balXShort -= (amountDeducted - feeX);
            amountX += (amountDeducted - feeX);
            require(balXShort != 0, INSUFFICIENT_LIQUIDITY());
            poolInfo.totalBalanceXShort = balXShort.safe128();
        }
        if (option.amountForShortY != 0) {
            amountDeducted = PriceMath.fullMulDivUnchecked(option.amountForShortY, balYShort, _totalSupply.shortY); // overflow is not realistic, _totalSupply can't be 0.
            feeY = FeeTier.getFee(uint24(poolInfo.highestId - binId), amountDeducted);
            balYShort -= (amountDeducted - feeY);
            amountY += (amountDeducted - feeY);
            require(balYShort != 0, INSUFFICIENT_LIQUIDITY());
            poolInfo.totalBalanceYShort = balYShort.safe128();
        }

        totalBalX -= amountX;
        totalBalY -= amountY;

        if (totalBalX < 512) amountX -= (512 - totalBalX);
        if (totalBalY < 512) amountY -= (512 - totalBalY);
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
            require(balanceAfter >= (balanceXBefore + feeX), INSUFFICIENT_PAYBACK());
            totalBalLong = PriceMath.fullMulDivUnchecked(balanceAfter, poolInfo.totalBalanceXLong, balanceXBefore); // overflow is not realistic
            totalBalShort = balanceAfter - totalBalLong;
            poolInfo.totalBalanceXLong = totalBalLong.safe128();
            poolInfo.totalBalanceXShort = totalBalShort.safe128();
        }
        if (amountY != 0) {
            balanceAfter = IERC20(tokenY).balanceOf(address(this));
            require(balanceAfter >= (balanceYBefore + feeY), INSUFFICIENT_PAYBACK());
            totalBalLong = PriceMath.fullMulDivUnchecked(balanceAfter, poolInfo.totalBalanceYLong, balanceYBefore); // overflow is not realistic
            totalBalShort = balanceAfter - totalBalLong;
            poolInfo.totalBalanceYLong = totalBalLong.safe128();
            poolInfo.totalBalanceYShort = totalBalShort.safe128();
        }
    }

    function getTwabId() public view returns (int24 binId) {}

    function swap(address recipient, bool xInYOut, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        ensure(deadline)
        nonReentrant
        noDelegateCall
        returns (uint256 amountOut)
    {
        require(amountIn != 0 && minAmountOut != 0, INVALID_AMOUNT());
        int24 binId = poolInfo.activeId;
        int24 newHighestId = poolInfo.highestId;
        int24 newLowestId = poolInfo.lowestId;
        uint32 _blockTimeStamp = uint32(block.timestamp); // overflow is far away (year 2106)
        uint32 timeElapsed = (_blockTimeStamp) - poolInfo.lastBlockTimestamp; // overflow is unrealistic

        // update oracle
        if (timeElapsed != 0) {
            int64 newTwab = binId * int32(timeElapsed); // overflow is unrealistic,
            poolInfo.twabCumulative += newTwab; // overflow is unrealistic
            poolInfo.lastBlockTimestamp = _blockTimeStamp;

            if (poolInfo.targetTimestamp == 0) {
                poolInfo.last7daysCumulative = newTwab; // initialize
                poolInfo.last7daysTimestamp = _blockTimeStamp; // initialize
                poolInfo.targetTimestamp = _blockTimeStamp + 7 days; // initialize
            } else if (poolInfo.targetTimestamp <= _blockTimeStamp) {
                // update the 7 days twab
                int24 last7daysTwab = int24(
                    (poolInfo.twabCumulative - poolInfo.last7daysCumulative)
                        / int32(_blockTimeStamp - poolInfo.last7daysTimestamp)
                ); // overflow is unrealistic
                poolInfo.last7daysCumulative = poolInfo.twabCumulative;
                poolInfo.last7daysTimestamp = _blockTimeStamp; // initialize
                poolInfo.targetTimestamp = _blockTimeStamp + 7 days; // initialize

                // range expansion and contraction
                int24 oldRange = newHighestId - newLowestId;
                int24 newRange;
                if (last7daysTwab < poolInfo.tickX) {
                    //expand towards lower id
                    int24 oldLowestId = newLowestId;
                    newLowestId -= (poolInfo.tickX - last7daysTwab) >> 1;
                    if (binId - newLowestId > 255) newLowestId += binId - newLowestId - 255;
                    if (newLowestId < -44405) newLowestId = -44405;

                    newRange = newHighestId - newLowestId;

                    if (newRange > oldRange) {
                        uint256 oldTotalBinShareX = poolInfo.totalBinShareX;
                        uint256 newTotalBinShareX =
                            PriceMath.fullMulDivUnchecked(oldTotalBinShareX, uint24(newRange), uint24(oldRange)); // overflow is unrealistic
                        uint256 addBinShareXPerBin =
                            (newTotalBinShareX - oldTotalBinShareX) / uint24(newRange - oldRange);
                        while (oldLowestId > newLowestId) {
                            oldLowestId--;
                            bins[oldLowestId] = addBinShareXPerBin;
                        }
                        poolInfo.totalBinShareX = newTotalBinShareX;
                    } else {
                        newLowestId = oldLowestId;
                    }
                } else if (last7daysTwab > poolInfo.tickY) {
                    //expand towards higher id
                    int24 oldHighestId = newHighestId;
                    newHighestId += (last7daysTwab - poolInfo.tickY) >> 1;
                    if (newHighestId - binId > 255) newHighestId -= newHighestId - binId - 255;
                    if (newHighestId > 44405) newHighestId = 44405;

                    newRange = newHighestId - newLowestId;

                    if (newRange > oldRange) {
                        uint256 oldTotalBinShareY = poolInfo.totalBinShareY;
                        uint256 newTotalBinShareY =
                            PriceMath.fullMulDivUnchecked(oldTotalBinShareY, uint24(newRange), uint24(oldRange)); // overflow is unrealistic
                        uint256 addBinShareYPerBin =
                            (newTotalBinShareY - oldTotalBinShareY) / uint24(newRange - oldRange);
                        while (oldHighestId < newHighestId) {
                            oldHighestId++;
                            bins[oldHighestId] = addBinShareYPerBin;
                        }
                        poolInfo.totalBinShareY = newTotalBinShareY;
                    } else {
                        newHighestId = oldHighestId;
                    }
                } else {
                    //contract
                    int24 contractionSpaceX = last7daysTwab - poolInfo.tickX;
                    int24 contractionSpaceY = poolInfo.tickY - last7daysTwab;
                    newRange = contractionSpaceX < contractionSpaceY ? contractionSpaceX : contractionSpaceY;
                    newRange >>= 1;
                    if (newRange > 0) {
                        int24 oldLowestId = newLowestId;
                        int24 oldHighestId = newHighestId;
                        newLowestId += newRange;
                        newHighestId -= newRange;

                        if (newHighestId < binId + 15) newHighestId = binId + 15;
                        if (newLowestId > binId - 15) newLowestId = binId - 15;
                        if (newLowestId < -44405) newLowestId = -44405;
                        if (newHighestId > 44405) newHighestId = 44405;

                        if (oldHighestId > newHighestId) {
                            uint256 binShareYToRemove;
                            while (oldHighestId > newHighestId) {
                                binShareYToRemove += bins[oldHighestId];
                                oldHighestId--;
                            }
                            poolInfo.totalBinShareY -= binShareYToRemove;
                        } else {
                            newHighestId = oldHighestId;
                        }

                        if (oldLowestId < newLowestId) {
                            uint256 binShareXToRemove;
                            while (oldLowestId < newLowestId) {
                                binShareXToRemove += bins[oldLowestId];
                                oldLowestId++;
                            }
                            poolInfo.totalBinShareX -= binShareXToRemove;
                        } else {
                            newLowestId = oldLowestId;
                        }
                    }
                }
                poolInfo.tickX = (binId + newLowestId) >> 1;
                poolInfo.tickY = (binId + newHighestId) >> 1;
            }
        }

        uint256 totalBalXLong = poolInfo.totalBalanceXLong;
        uint256 totalBalXShort = poolInfo.totalBalanceXShort;
        uint256 totalBalYLong = poolInfo.totalBalanceYLong;
        uint256 totalBalYShort = poolInfo.totalBalanceYShort;

        uint256 totalBalX = totalBalXLong + totalBalXShort;
        uint256 totalBalY = totalBalYLong + totalBalYShort;

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
        uint256 originalAmountIn = amountIn;
        uint256 binAmountOut = PriceMath.fullMulDivUnchecked(totalBalOut, binShareOut, totalBinShareOut); // overflow is not realistic
        (uint256 maxAmountIn, uint256 price) = _getAmountInFromBin(xInYOut, binId, binAmountOut);
        uint256 usedBinShareOut;

        while (binId >= newLowestId && binId <= newHighestId) {
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
            uint256 adjustedBinShareOut;
            if (xInYOut) {
                binId++;
                if (newHighestId < 44405) {
                    adjustedBinShareOut = (bins[binId] + bins[newHighestId]) >> 1;
                    newHighestId++;
                    bins[newHighestId] = adjustedBinShareOut;
                    totalBinShareOut += adjustedBinShareOut;

                    uint256 adjustedBinShareInEquivalent =
                        PriceMath.fullMulDiv(adjustedBinShareOut, binShareInGain, usedBinShareOut);
                    uint256 newLowestIdBinShare = bins[newLowestId];

                    if (binId - newLowestId > newHighestId - binId) {
                        if (adjustedBinShareInEquivalent >= newLowestIdBinShare) {
                            adjustedBinShareInEquivalent = newLowestIdBinShare;
                            newLowestId++;
                        } else {
                            bins[newLowestId] = newLowestIdBinShare - adjustedBinShareInEquivalent;
                        }
                        totalBinShareIn -= adjustedBinShareInEquivalent;
                    }
                }
            } else {
                binId--;
                if (newLowestId > -44405) {
                    adjustedBinShareOut = (bins[binId] + bins[newLowestId]) >> 1;
                    newLowestId--;
                    bins[newLowestId] = adjustedBinShareOut;
                    totalBinShareOut += adjustedBinShareOut;

                    uint256 adjustedBinShareInEquivalent =
                        PriceMath.fullMulDiv(adjustedBinShareOut, binShareInGain, usedBinShareOut);
                    uint256 newHighestIdBinShare = bins[newHighestId];

                    if (newHighestId - binId > binId - newLowestId) {
                        if (adjustedBinShareInEquivalent >= newHighestIdBinShare) {
                            adjustedBinShareInEquivalent = newHighestIdBinShare;
                            newHighestId--;
                        } else {
                            bins[newHighestId] = newHighestIdBinShare - adjustedBinShareInEquivalent;
                        }
                        totalBinShareIn -= adjustedBinShareInEquivalent;
                    }
                }
            }

            binShareIn = 0;
            binShareOut = bins[binId];

            binAmountOut = PriceMath.fullMulDivUnchecked(totalBalOut, binShareOut, totalBinShareOut); // overflow is not realistic
            (maxAmountIn, price) = _getAmountInFromNextBin(xInYOut, price, binAmountOut);
        }

        // calculate fee
        uint256 feeOut = xInYOut
            ? FeeTier.getFee(uint24(newHighestId - binId), amountOut)
            : FeeTier.getFee(uint24(binId - newLowestId), amountOut);
        uint256 feeIn = PriceMath.fullMulDivUnchecked(originalAmountIn, feeOut, amountOut);

        // get new token balances for lp
        if (xInYOut) {
            totalBalXLong = PriceMath.fullMulDivUnchecked(totalBalIn, totalBalXLong, totalBalX); // overflow is not realistic
            totalBalXShort = totalBalIn - totalBalXLong;
            if (totalBalXLong > feeIn + 512) {
                totalBalXLong -= feeIn;
                totalBalXShort += feeIn;
            }

            totalBalYLong = PriceMath.fullMulDivUnchecked(totalBalOut, totalBalYLong, totalBalY); // overflow is not realistic
            totalBalYShort = totalBalOut - totalBalYLong;
            if (totalBalYShort > feeOut + 512) {
                totalBalYShort -= feeOut;
                totalBalYLong += feeOut << 1;
            } else {
                totalBalYLong += feeOut;
            }
        } else {
            totalBalYLong = PriceMath.fullMulDivUnchecked(totalBalIn, totalBalYLong, totalBalY); // overflow is not realistic
            totalBalYShort = totalBalIn - totalBalYLong;
            if (totalBalYLong > feeIn + 512) {
                totalBalYLong -= feeIn;
                totalBalYShort += feeIn;
            }

            totalBalXLong = PriceMath.fullMulDivUnchecked(totalBalOut, totalBalXLong, totalBalX); // overflow is not realistic
            totalBalXShort = totalBalOut - totalBalXLong;
            if (totalBalXShort > feeOut + 512) {
                totalBalXShort -= feeOut;
                totalBalXLong += feeOut << 1;
            } else {
                totalBalXLong += feeOut;
            }
        }

        totalBalOut += feeOut;
        amountOut -= feeOut;

        checkBinIdLimit(binId);
        require(totalBalOut > 511, INSUFFICIENT_LIQUIDITY());
        require(
            totalBalXLong != 0 && totalBalYLong != 0 && totalBalXShort != 0 && totalBalYShort != 0,
            INSUFFICIENT_LIQUIDITY()
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
        poolInfo.lowestId = newLowestId;
        poolInfo.highestId = newHighestId;

        require(amountOut >= minAmountOut, SLIPPAGE_EXCEEDED());
        TransferHelper.safeTransfer(tokenOut, recipient, amountOut);
    }
}
