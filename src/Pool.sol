// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.28;

import {AX11Lp} from './abstracts/AX11Lp.sol';
import {ReentrancyGuard} from './abstracts/ReentrancyGuard.sol';
import {Deadline} from './abstracts/Deadline.sol';
import {NoDelegateCall} from './abstracts/NoDelegateCall.sol';

import {IPool} from './interfaces/IPool.sol';
import {IERC20} from './interfaces/IERC20.sol';
import {IAX11Callback} from './interfaces/IAX11Callback.sol';

import {TransferHelper} from './libraries/TransferHelper.sol';
import {PriceMath} from './libraries/PriceMath.sol';
import {FeeTier} from './libraries/FeeTier.sol';
import {SafeCast} from './libraries/SafeCast.sol';
import {PoolHelper} from './libraries/PoolHelper.sol';

contract Pool is AX11Lp, IPool, ReentrancyGuard, Deadline, NoDelegateCall {
    using SafeCast for uint256;

    mapping(uint256 poolId => PoolInfo) private _pools;
    mapping(address tokenX => mapping(address tokenY => uint256 poolId)) private _poolIds;
    mapping(int24 binId => mapping(uint256 poolId => uint256 binshare)) private _bins; // share is stored as 128.128 fixed point

    uint256 public override totalPools;
    address public override owner;

    constructor() {
        owner = msg.sender;
    }

    function setOwner(address _owner) external override {
        require(msg.sender == owner, NOT_OWNER());
        owner = _owner;
    }

    function getPoolId(address tokenX, address tokenY) public view override returns (uint256) {
        return _poolIds[tokenX][tokenY];
    }

    function getPoolInfo(uint256 poolId) public view override returns (PoolInfo memory) {
        return _pools[poolId];
    }

    /// @notice Create a liquidity pool
    /// @param tokenX The address of the tokenX
    /// @param tokenY The address of the tokenY
    /// @param activeId The active bin id
    /// @dev we assume the amount received by the pool is ALWAYS equal to the transferFrom value of 512
    /// Note: meaning that we don't support fee-on-transfer tokens
    function createPool(
        address tokenX,
        address tokenY,
        int24 activeId
    ) external override noDelegateCall returns (uint256 poolId) {
        address initiator = msg.sender;
        require(tokenX < tokenY, INVALID_ADDRESS()); // required pre-sorting of tokens
        poolId = PoolHelper.computePoolId(tokenX, tokenY);

        int24 lowestId = activeId - 255;
        int24 highestId = activeId + 255;

        PoolHelper.checkBinIdLimit(lowestId);
        PoolHelper.checkBinIdLimit(highestId);

        uint256 binShare = 2 << 128; // 2 tokens/bin, 128.128 fixed point
        uint256 tokenShare = 512 << 128; // 128.128 fixed point
        uint256 lpShare = tokenShare >> 1; // half of token share

        int24 tickX = (activeId + lowestId) >> 1; // midpoint, round down
        int24 tickY = (activeId + highestId) >> 1; // midpoint, round down

        PoolInfo storage pool = _pools[poolId];
        require(pool.tokenY == address(0), INVALID_ADDRESS()); // check if pool already exists

        TransferHelper.safeTransferFrom(tokenX, initiator, address(this), 512);
        TransferHelper.safeTransferFrom(tokenY, initiator, address(this), 512);

        pool.tokenX = tokenX;
        pool.tokenY = tokenY;
        pool.totalBalanceXLong = 256;
        pool.totalBalanceYLong = 256;
        pool.totalBalanceXShort = 256;
        pool.totalBalanceYShort = 256;
        pool.totalBinShareX = tokenShare;
        pool.totalBinShareY = tokenShare;
        pool.activeBinShareX = binShare;
        pool.activeBinShareY = binShare;
        pool.activeId = activeId;
        pool.lowestId = lowestId;
        pool.highestId = highestId;
        pool.tickX = tickX;
        pool.tickY = tickY;
        pool.groupBinXFrom = activeId + 1;
        pool.groupBinXTo = highestId;
        pool.groupBinYFrom = activeId - 1;
        pool.groupBinYTo = lowestId;
        pool.groupBinXSharePerBin = binShare;
        pool.groupBinYSharePerBin = binShare;

        _mint(address(0), poolId, lpShare, lpShare, lpShare, lpShare);
        totalPools++;
        emit PoolCreated(tokenX, tokenY, poolId);
    }

    /// @dev flash loan function
    /// @notice retrieve the token from all liquidity pools combined, charged with a fixed 0.01% fee
    /// @param recipient The address of the recipient
    /// @param callback The address of the callback
    /// @param token The address of the token
    /// @param amount The amount of the token
    /// @param deadline The deadline of the flash loan
    function flash(
        address recipient,
        address callback,
        address token,
        uint256 amount,
        uint256 deadline
    ) external override ensure(deadline) nonReentrant noDelegateCall {
        if (amount != 0) {
            uint256 available = IERC20(token).balanceOf(address(this));
            require(available >= amount, INVALID_AMOUNT());
            uint256 fee = PriceMath.divUp(amount, 10000); // 0.01% fee
            uint256 paybackAmount = amount + fee;
            TransferHelper.safeTransfer(token, recipient, amount);
            IAX11Callback(callback).flashCallback(paybackAmount);
            require(IERC20(token).balanceOf(address(this)) >= available + fee, FLASH_INSUFFICIENT_PAYBACK());
        }
    }

    /// @dev this function assumes that BalanceXLong,YLong, XShort, YShort will never be zero
    /// The prevention is implemented in the swap function, disallowing complete depletion of liquidity
    /// @dev we do not support fee-on-transfer tokens, make sure to follow ERC20 standard in order to use this function
    function mint(
        LiquidityOption calldata option
    )
        external
        override
        ensure(option.deadline)
        nonReentrant
        noDelegateCall
        returns (uint256 LPXLong, uint256 LPYLong, uint256 LPXShort, uint256 LPYShort)
    {
        PoolInfo storage pool = _pools[option.poolId];
        LpInfo storage totalSupply = _totalSupply[option.poolId];

        address tokenX = pool.tokenX;
        address tokenY = pool.tokenY;
        int24 binId = pool.activeId;

        require(tokenY != address(0), INVALID_ADDRESS()); // check if pool already exists
        require(binId >= option.minActiveId && binId <= option.maxActiveId, SLIPPAGE_EXCEEDED());

        uint256 amountX = option.amountForLongX + option.amountForShortX;
        uint256 amountY = option.amountForLongY + option.amountForShortY;

        if (option.callback == address(0)) {
            if (amountX != 0) TransferHelper.safeTransferFrom(pool.tokenX, msg.sender, address(this), amountX);
            if (amountY != 0) TransferHelper.safeTransferFrom(pool.tokenY, msg.sender, address(this), amountY);
        } else {
            uint256 amountXBefore = IERC20(tokenX).balanceOf(address(this));
            uint256 amountYBefore = IERC20(tokenY).balanceOf(address(this));

            IAX11Callback(option.callback).mintCallback(amountX, amountY);

            if (amountX != 0)
                require(
                    IERC20(tokenX).balanceOf(address(this)) >= amountXBefore + amountX,
                    MINT_INSUFFICIENT_PAYBACK()
                );
            if (amountY != 0)
                require(
                    IERC20(tokenY).balanceOf(address(this)) >= amountYBefore + amountY,
                    MINT_INSUFFICIENT_PAYBACK()
                );
        }

        uint256 bal;
        if (option.amountForLongX != 0) {
            bal = pool.totalBalanceXLong;
            LPXLong = PriceMath.fullMulDiv(option.amountForLongX, totalSupply.longX, bal);
            pool.totalBalanceXLong = (bal + option.amountForLongX).safe128();
        }
        if (option.amountForLongY != 0) {
            bal = pool.totalBalanceYLong;
            LPYLong = PriceMath.fullMulDiv(option.amountForLongY, totalSupply.longY, bal);
            pool.totalBalanceYLong = (bal + option.amountForLongY).safe128();
        }
        if (option.amountForShortX != 0) {
            bal = pool.totalBalanceXShort;
            LPXShort = PriceMath.fullMulDiv(option.amountForShortX, totalSupply.shortX, bal);
            pool.totalBalanceXShort = (bal + option.amountForShortX).safe128();
        }
        if (option.amountForShortY != 0) {
            bal = pool.totalBalanceYShort;
            LPYShort = PriceMath.fullMulDiv(option.amountForShortY, totalSupply.shortY, bal);
            pool.totalBalanceYShort = (bal + option.amountForShortY).safe128();
        }

        _mint(option.recipient, option.poolId, LPXLong, LPYLong, LPXShort, LPYShort);
    }

    /// @dev Note: this function assumes that BalanceXLong,YLong, XShort, YShort will never be zero
    /// The prevention is implemented in the swap function, disallowing complete depletion of liquidity
    function burn(
        LiquidityOption calldata option
    ) external override ensure(option.deadline) nonReentrant noDelegateCall returns (uint256 amountX, uint256 amountY) {
        PoolInfo storage pool = _pools[option.poolId];
        LpInfo memory totalSupplyBefore = _totalSupply[option.poolId];

        address tokenX = pool.tokenX;
        address tokenY = pool.tokenY;
        int24 binId = pool.activeId;

        require(tokenY != address(0), INVALID_ADDRESS()); // check if pool already exists
        require(binId >= option.minActiveId && binId <= option.maxActiveId, SLIPPAGE_EXCEEDED());

        if (option.callback == address(0)) {
            _burn(
                msg.sender,
                option.poolId,
                option.amountForLongX,
                option.amountForLongY,
                option.amountForShortX,
                option.amountForShortY
            );
        } else {
            //just transfer the lp tokens to address(0), see AX11Lp.sol
            IAX11Callback(option.callback).burnCallback(
                option.amountForLongX,
                option.amountForLongY,
                option.amountForShortX,
                option.amountForShortY
            );

            LpInfo storage totalSupplyAfter = _totalSupply[option.poolId];

            if (option.amountForLongX != 0)
                require(
                    totalSupplyAfter.longX <= totalSupplyBefore.longX - option.amountForLongX,
                    BURN_INSUFFICIENT_PAYBACK()
                );
            if (option.amountForLongY != 0)
                require(
                    totalSupplyAfter.longY <= totalSupplyBefore.longY - option.amountForLongY,
                    BURN_INSUFFICIENT_PAYBACK()
                );
            if (option.amountForShortX != 0)
                require(
                    totalSupplyAfter.shortX <= totalSupplyBefore.shortX - option.amountForShortX,
                    BURN_INSUFFICIENT_PAYBACK()
                );
            if (option.amountForShortY != 0)
                require(
                    totalSupplyAfter.shortY <= totalSupplyBefore.shortY - option.amountForShortY,
                    BURN_INSUFFICIENT_PAYBACK()
                );
        }

        uint256 balXLong = pool.totalBalanceXLong;
        uint256 balYLong = pool.totalBalanceYLong;
        uint256 balXShort = pool.totalBalanceXShort;
        uint256 balYShort = pool.totalBalanceYShort;
        uint256 amountDeducted;
        uint256 fee;

        if (option.amountForLongX != 0) {
            amountDeducted = PriceMath.fullMulDiv(option.amountForLongX, balXLong, totalSupplyBefore.longX);
            fee = FeeTier.getFee(uint24(binId - pool.lowestId), amountDeducted);
            amountDeducted -= fee;
            balXLong -= amountDeducted;
            amountX += amountDeducted;
            require(balXLong != 0, INSUFFICIENT_LIQUIDITY());
            pool.totalBalanceXLong = balXLong.safe128();
        }
        if (option.amountForLongY != 0) {
            amountDeducted = PriceMath.fullMulDiv(option.amountForLongY, balYLong, totalSupplyBefore.longY);
            fee = FeeTier.getFee(uint24(pool.highestId - binId), amountDeducted);
            amountDeducted -= fee;
            balYLong -= amountDeducted;
            amountY += amountDeducted;
            require(balYLong != 0, INSUFFICIENT_LIQUIDITY());
            pool.totalBalanceYLong = balYLong.safe128();
        }
        if (option.amountForShortX != 0) {
            amountDeducted = PriceMath.fullMulDiv(option.amountForShortX, balXShort, totalSupplyBefore.shortX);
            fee = FeeTier.getFee(uint24(binId - pool.lowestId), amountDeducted);
            amountDeducted -= fee;
            balXShort -= amountDeducted;
            amountX += amountDeducted;
            require(balXShort != 0, INSUFFICIENT_LIQUIDITY());
            pool.totalBalanceXShort = balXShort.safe128();
        }
        if (option.amountForShortY != 0) {
            amountDeducted = PriceMath.fullMulDiv(option.amountForShortY, balYShort, totalSupplyBefore.shortY);
            fee = FeeTier.getFee(uint24(pool.highestId - binId), amountDeducted);
            amountDeducted -= fee;
            balYShort -= amountDeducted;
            amountY += amountDeducted;
            require(balYShort != 0, INSUFFICIENT_LIQUIDITY());
            pool.totalBalanceYShort = balYShort.safe128();
        }

        uint256 totalBalX = balXLong + balXShort;
        uint256 totalBalY = balYLong + balYShort;

        if (totalBalX < 512) amountX -= (512 - totalBalX);
        if (totalBalY < 512) amountY -= (512 - totalBalY);
        /// @dev if a user's share is too large that it covers almost the entire pool, they need to leave the minimum liquidity in the pool.
        /// so they may be able to withdraw 99.999xxx% of their funds.

        if (amountX != 0) TransferHelper.safeTransfer(tokenX, option.recipient, amountX);
        if (amountY != 0) TransferHelper.safeTransfer(tokenY, option.recipient, amountY);
    }

    function swap(
        address recipient,
        bool xInYOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external ensure(deadline) nonReentrant noDelegateCall returns (uint256 amountOut) {
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
            uint256 _targetTimestamp = poolInfo.targetTimestamp;

            if (_targetTimestamp == 0) {
                poolInfo.last7daysCumulative = newTwab;
                poolInfo.last7daysTimestamp = _blockTimeStamp;
                poolInfo.targetTimestamp = _blockTimeStamp + 7 days;
            } else if (_targetTimestamp <= _blockTimeStamp) {
                // update the 7 days twab
                int24 last7daysTwab = int24(
                    (poolInfo.twabCumulative - poolInfo.last7daysCumulative) /
                        int32(_blockTimeStamp - poolInfo.last7daysTimestamp)
                ); // int32 is sufficient
                poolInfo.last7daysCumulative = poolInfo.twabCumulative;
                poolInfo.last7daysTimestamp = _blockTimeStamp;
                poolInfo.targetTimestamp = _blockTimeStamp + 7 days;

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
                        uint256 newTotalBinShareX = PriceMath.fullMulDiv(
                            oldTotalBinShareX,
                            uint24(newRange),
                            uint24(oldRange)
                        );
                        uint256 addBinShareXPerBin = (newTotalBinShareX - oldTotalBinShareX) /
                            uint24(newRange - oldRange);
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
                        uint256 newTotalBinShareY = PriceMath.fullMulDiv(
                            oldTotalBinShareY,
                            uint24(newRange),
                            uint24(oldRange)
                        );
                        uint256 addBinShareYPerBin = (newTotalBinShareY - oldTotalBinShareY) /
                            uint24(newRange - oldRange);
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
        uint256 binAmountOut = PriceMath.fullMulDiv(totalBalOut, binShareOut, totalBinShareOut);
        (uint256 maxAmountIn, uint256 price) = PriceMath._getAmountInFromBin(xInYOut, binId, binAmountOut);
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
            uint256 binShareInGain = PriceMath.fullMulDiv(maxAmountIn, totalBinShareIn, totalBalIn);
            binShareIn += binShareInGain;
            totalBinShareIn += binShareInGain; // update total bin share
            totalBinShareOut -= usedBinShareOut; // update total bin share

            if (amountIn == 0) break; // delete bins[binId] is not necessary
            // because if we cross the bin, it will set the new value in the next line
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
                    if (usedBinShareOut != 0) {
                        // in case of perfect drain, we don't contract the bin on the other side
                        uint256 adjustedBinShareInEquivalent = PriceMath.fullMulDiv(
                            adjustedBinShareOut,
                            binShareInGain,
                            usedBinShareOut
                        );
                        uint256 lowestIdBinShare = bins[newLowestId];

                        if (binId - newLowestId > newHighestId - binId) {
                            if (adjustedBinShareInEquivalent >= lowestIdBinShare) {
                                adjustedBinShareInEquivalent = lowestIdBinShare;
                                newLowestId++;
                            } else {
                                bins[newLowestId] = lowestIdBinShare - adjustedBinShareInEquivalent;
                            }
                            totalBinShareIn -= adjustedBinShareInEquivalent;
                        }
                    }
                }
            } else {
                binId--;
                if (newLowestId > -44405) {
                    adjustedBinShareOut = (bins[binId] + bins[newLowestId]) >> 1;
                    newLowestId--;
                    bins[newLowestId] = adjustedBinShareOut;
                    totalBinShareOut += adjustedBinShareOut;
                    if (usedBinShareOut != 0) {
                        // in case of perfect drain, we don't contract the bin on the other side
                        uint256 adjustedBinShareInEquivalent = PriceMath.fullMulDiv(
                            adjustedBinShareOut,
                            binShareInGain,
                            usedBinShareOut
                        );
                        uint256 highestIdBinShare = bins[newHighestId];

                        if (newHighestId - binId > binId - newLowestId) {
                            if (adjustedBinShareInEquivalent >= highestIdBinShare) {
                                adjustedBinShareInEquivalent = highestIdBinShare;
                                newHighestId--;
                            } else {
                                bins[newHighestId] = highestIdBinShare - adjustedBinShareInEquivalent;
                            }
                            totalBinShareIn -= adjustedBinShareInEquivalent;
                        }
                    }
                }
            }

            binShareIn = 0;
            binShareOut = bins[binId];

            binAmountOut = PriceMath.fullMulDiv(totalBalOut, binShareOut, totalBinShareOut);
            (maxAmountIn, price) = PriceMath._getAmountInFromNextBin(xInYOut, price, binAmountOut);
        }

        // calculate fee
        uint256 feeOut = xInYOut
            ? FeeTier.getFee(uint24(newHighestId - binId), amountOut)
            : FeeTier.getFee(uint24(binId - newLowestId), amountOut);
        uint256 feeIn = PriceMath.fullMulDiv(originalAmountIn, feeOut, amountOut);

        // get new token balances for lp
        if (xInYOut) {
            totalBalXLong = PriceMath.fullMulDiv(totalBalIn, totalBalXLong, totalBalX);
            totalBalXShort = totalBalIn - totalBalXLong;
            if (totalBalXLong > feeIn + 512) {
                totalBalXLong -= feeIn;
                totalBalXShort += feeIn;
            }

            totalBalYLong = PriceMath.fullMulDiv(totalBalOut, totalBalYLong, totalBalY);
            totalBalYShort = totalBalOut - totalBalYLong;
            if (totalBalYShort > feeOut + 512) {
                totalBalYShort -= feeOut;
                totalBalYLong += feeOut << 1;
            } else {
                totalBalYLong += feeOut;
            }
        } else {
            totalBalYLong = PriceMath.fullMulDiv(totalBalIn, totalBalYLong, totalBalY);
            totalBalYShort = totalBalIn - totalBalYLong;
            if (totalBalYLong > feeIn + 512) {
                totalBalYLong -= feeIn;
                totalBalYShort += feeIn;
            }

            totalBalXLong = PriceMath.fullMulDiv(totalBalOut, totalBalXLong, totalBalX);
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
