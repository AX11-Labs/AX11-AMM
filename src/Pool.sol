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

    mapping(int24 binId => uint256 binshare) public bins; // share is stored as 128.128 fixed point

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

    /// @notice Initialize the pool
    /// @param _activeId The active bin id
    /// @param _initiator The initiator of the pool
    /// @dev we assume the amount received by the pool is ALWAYS equal to transferFrom value of 512
    /// Note: meaning that we don't support fee-on-transfer tokens
    function initialize(address _tokenX, address _tokenY, int24 _activeId, address _initiator) private {
        TransferHelper.safeTransferFrom(_tokenX, _initiator, address(this), 1024);
        TransferHelper.safeTransferFrom(_tokenY, _initiator, address(this), 1024);

        int24 _minId = _activeId - 511;
        int24 _maxId = _activeId + 511;
        checkBinIdLimit(_minId);
        checkBinIdLimit(_maxId);
        int24 iteration = _activeId;
        uint256 _binShare = 2 << 128; // 2 tokens/bin, scaling as 128.128 fixed point

        while (iteration < _maxId) {
            iteration++;
            bins[iteration] = _binShare;
        }
        iteration = _activeId;
        while (iteration > _minId) {
            iteration--;
            bins[iteration] = _binShare;
        }

        uint256 _tokenShare = 1024 << 128; // scaling as 128.128 fixed point
        uint256 _lpShare = _tokenShare >> 1; // half of the token share

        int24 tickX = (_activeId + _minId) >> 1;
        int24 tickY = (_activeId + _maxId) >> 1;

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
            minId: _minId,
            maxId: _maxId,
            tickXUpper: tickX, // midpoint,round down
            tickYUpper: tickY, // midpoint,round down
            tickXLower: (_activeId + tickX) >> 1, // midpoint,round down
            tickYLower: (_activeId + tickY) >> 1 // midpoint,round down
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
        PoolInfo storage _pool = poolInfo;
        LpInfo storage _lpInfo = _totalSupply;

        int24 binId = _pool.activeId;
        require(binId >= option.minActiveId && binId <= option.maxActiveId, SLIPPAGE_EXCEEDED());

        uint256 amountX;
        uint256 amountY;
        uint256 bal;

        if (option.amountForLongX != 0) {
            bal = _pool.totalBalanceXLong;
            LPXLong = PriceMath.fullMulDiv(option.amountForLongX, _lpInfo.longX, bal); // assume bal != 0
            amountX += option.amountForLongX;
            bal += option.amountForLongX;
            _pool.totalBalanceXLong = bal.safe128();
        }
        if (option.amountForLongY != 0) {
            bal = _pool.totalBalanceYLong;
            LPYLong = PriceMath.fullMulDiv(option.amountForLongY, _lpInfo.longY, bal); // assume bal != 0
            amountY += option.amountForLongY;
            bal += option.amountForLongY;
            _pool.totalBalanceYLong = bal.safe128();
        }
        if (option.amountForShortX != 0) {
            bal = _pool.totalBalanceXShort;
            LPXShort = PriceMath.fullMulDiv(option.amountForShortX, _lpInfo.shortX, bal); // assume bal != 0
            amountX += option.amountForShortX;
            bal += option.amountForShortX;
            _pool.totalBalanceXShort = bal.safe128();
        }
        if (option.amountForShortY != 0) {
            bal = _pool.totalBalanceYShort;
            LPYShort = PriceMath.fullMulDiv(option.amountForShortY, _lpInfo.shortY, bal); // assume bal != 0
            amountY += option.amountForShortY;
            bal += option.amountForShortY;
            _pool.totalBalanceYShort = bal.safe128();
        }

        if (amountX != 0) TransferHelper.safeTransferFrom(_pool.tokenX, sender, address(this), amountX);
        if (amountY != 0) TransferHelper.safeTransferFrom(_pool.tokenY, sender, address(this), amountY);

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
        PoolInfo storage _pool = poolInfo;
        LpInfo storage _lpInfo = _totalSupply;

        int24 binId = _pool.activeId;
        require(binId >= option.minActiveId && binId <= option.maxActiveId, SLIPPAGE_EXCEEDED());

        uint256 balXLong = _pool.totalBalanceXLong;
        uint256 balYLong = _pool.totalBalanceYLong;
        uint256 balXShort = _pool.totalBalanceXShort;
        uint256 balYShort = _pool.totalBalanceYShort;

        uint256 totalBalX = balXLong + balXShort;
        uint256 totalBalY = balYLong + balYShort;

        uint256 amountDeducted;

        if (option.amountForLongX != 0) {
            amountDeducted = PriceMath.fullMulDiv(option.amountForLongX, balXLong, _lpInfo.longX);
            balXLong -= amountDeducted;
            amountX += amountDeducted;
            require(balXLong != 0, MINIMUM_LIQUIDITY_EXCEEDED());
            _pool.totalBalanceXLong = balXLong.safe128();
        }
        if (option.amountForLongY != 0) {
            amountDeducted = PriceMath.fullMulDiv(option.amountForLongY, balYLong, _lpInfo.longY);
            balYLong -= amountDeducted;
            amountY += amountDeducted;
            require(balYLong != 0, MINIMUM_LIQUIDITY_EXCEEDED());
            _pool.totalBalanceYLong = balYLong.safe128();
        }
        if (option.amountForShortX != 0) {
            amountDeducted = PriceMath.fullMulDiv(option.amountForShortX, balXShort, _lpInfo.shortX);
            balXShort -= amountDeducted;
            amountX += amountDeducted;
            require(balXShort != 0, MINIMUM_LIQUIDITY_EXCEEDED());
            _pool.totalBalanceXShort = balXShort.safe128();
        }
        if (option.amountForShortY != 0) {
            amountDeducted = PriceMath.fullMulDiv(option.amountForShortY, balYShort, _lpInfo.shortY);
            balYShort -= amountDeducted;
            amountY += amountDeducted;
            require(balYShort != 0, MINIMUM_LIQUIDITY_EXCEEDED());
            _pool.totalBalanceYShort = balYShort.safe128();
        }

        totalBalX -= amountX;
        totalBalY -= amountY;

        if (totalBalX < 1024) amountX -= (1024 - totalBalX);
        if (totalBalY < 1024) amountY -= (1024 - totalBalY);
        /// @dev if a user's share is too large that it covers almost the entire pool, they need to leave the minimum liquidity in the pool.
        /// so they may be able to withdraw 99.999xxx% of their funds.

        _burn(sender, option.amountForLongX, option.amountForLongY, option.amountForShortX, option.amountForShortY);

        if (amountX != 0) TransferHelper.safeTransfer(_pool.tokenX, sender, amountX);
        if (amountY != 0) TransferHelper.safeTransfer(_pool.tokenY, sender, amountY);
    }


    /// @dev Note: this function assumes that BalanceXLong,YLong, XShort, YShort will never be zero
    /// The prevention is implemented in the swap and burn function, disallowing complete depletion of liquidity
    function flash(address recipient, address callback, uint256 amountX, uint256 amountY)
        external
        nonReentrant
        noDelegateCall
    {
        PoolInfo storage _pool = poolInfo;

        uint256 balanceXBefore;
        uint256 balanceYBefore;
        uint256 feeX;
        uint256 feeY;
        uint256 balanceXAfter;
        uint256 balanceYAfter;

        if (amountX != 0) {
            balanceXBefore = IERC20(_pool.tokenX).balanceOf(address(this));
            feeX = PriceMath.divUp(amountX, 10000); // 0.01% fee
            TransferHelper.safeTransfer(_pool.tokenX, recipient, amountX);
        }
        if (amountY != 0) {
            balanceYBefore = IERC20(_pool.tokenY).balanceOf(address(this));
            feeY = PriceMath.divUp(amountY, 10000); // 0.01% fee
            TransferHelper.safeTransfer(_pool.tokenY, recipient, amountY);
        }

        IAx11FlashCallback(callback).flashCallback(feeX, feeY);

        if (amountX != 0) {
            balanceXAfter = IERC20(_pool.tokenX).balanceOf(address(this));
            uint256 totalBalXLong = PriceMath.fullMulDiv(balanceXAfter, _pool.totalBalanceXLong, balanceXBefore); // assume balanceXBefore != 0
            uint256 totalBalXShort = balanceXAfter - totalBalXLong;
            _pool.totalBalanceXLong = totalBalXLong.safe128();
            _pool.totalBalanceXShort = totalBalXShort.safe128();
        }
        if (amountY != 0) {
            balanceYAfter = IERC20(_pool.tokenY).balanceOf(address(this));
            uint256 totalBalYLong = PriceMath.fullMulDiv(balanceYAfter, _pool.totalBalanceYLong, balanceYBefore); // assume balanceYBefore != 0
            uint256 totalBalYShort = balanceYAfter - totalBalYLong;
            _pool.totalBalanceYLong = totalBalYLong.safe128();
            _pool.totalBalanceYShort = totalBalYShort.safe128();
        }

        require(
            balanceXAfter >= (balanceXBefore + feeX) && balanceYAfter >= (balanceYBefore + feeY), FLASH_INSUFFICIENT_BALANCE()
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

    function swap(address recipient, bool xInYOut, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        ensure(deadline)
        nonReentrant
        noDelegateCall
        returns (uint256 amountOut)
    {
        require(amountIn != 0 && minAmountOut != 0, INVALID_AMOUNT());
        PoolInfo storage _pool = poolInfo;

        uint256 totalBalX = _pool.totalBalanceXLong + _pool.totalBalanceXShort;
        uint256 totalBalY = _pool.totalBalanceYLong + _pool.totalBalanceYShort;
        int24 binId = _pool.activeId;

        (address tokenIn, address tokenOut) = xInYOut ? (_pool.tokenX, _pool.tokenY) : (_pool.tokenY, _pool.tokenX);
        (uint256 totalBalIn, uint256 totalBalOut) = xInYOut ? (totalBalX, totalBalY) : (totalBalY, totalBalX);
        (uint256 binShareIn, uint256 binShareOut) =
            xInYOut ? (_pool.activeBinShareX, _pool.activeBinShareY) : (_pool.activeBinShareY, _pool.activeBinShareX);
        (uint256 totalBinShareIn, uint256 totalBinShareOut) =
            xInYOut ? (_pool.totalBinShareX, _pool.totalBinShareY) : (_pool.totalBinShareY, _pool.totalBinShareX);

        TransferHelper.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);

        uint256 binAmountOut;
        uint256 maxAmountIn;
        uint256 usedBinShareOut;

        while (true) {
            binAmountOut = PriceMath.fullMulDiv(totalBalOut, binShareOut, totalBinShareOut);
            maxAmountIn = _getAmountInFromBin(xInYOut, binId, binAmountOut);
            /// @dev update bin share within the loop
            if (amountIn >= maxAmountIn) {
                amountIn -= maxAmountIn;
                amountOut += binAmountOut;
                totalBalOut -= binAmountOut; // update total balance out
                usedBinShareOut = binShareOut;
            } else {
                uint256 usedAmountOut = PriceMath.fullMulDiv(amountIn, binAmountOut, maxAmountIn);
                require(usedAmountOut != 0, TRADE_SIZE_TOO_SMALL());
                amountOut += usedAmountOut;
                totalBalOut -= usedAmountOut; // update total balance out
                usedBinShareOut = PriceMath.fullMulDiv(usedAmountOut, binShareOut, binAmountOut);
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
            // because if we pass the bin, it will set the new value in the next line
            // and if it stays, we can just leave it, because we'll only use the activeBinShareX/Y

            bins[binId] = binShareIn; // add to new bin
            binId = xInYOut ? binId + 1 : binId - 1;
            checkBinIdLimit(binId);
            binShareIn = 0;
            binShareOut = bins[binId];
        }

        uint256 totalBalXLong;
        uint256 totalBalXShort;
        uint256 totalBalYLong;
        uint256 totalBalYShort;
        /// @dev update pool storage after the loop
        if (xInYOut) {
            totalBalXLong = PriceMath.fullMulDiv(totalBalIn, _pool.totalBalanceXLong, totalBalX);
            totalBalXShort = totalBalIn - totalBalXLong;
            totalBalYLong = PriceMath.fullMulDiv(totalBalOut, _pool.totalBalanceYLong, totalBalY);
            totalBalYShort = totalBalOut - totalBalYLong;
        } else {
            totalBalYLong = PriceMath.fullMulDiv(totalBalIn, _pool.totalBalanceYLong, totalBalY);
            totalBalYShort = totalBalIn - totalBalYLong;
            totalBalXLong = PriceMath.fullMulDiv(totalBalOut, _pool.totalBalanceXLong, totalBalX);
            totalBalXShort = totalBalOut - totalBalXLong;
        }

        require(totalBalIn >= 1024 && totalBalOut >= 1024, MINIMUM_LIQUIDITY_EXCEEDED());
        require(
            totalBalXLong != 0 && totalBalYLong != 0 && totalBalXShort != 0 && totalBalYShort != 0,
            MINIMUM_LIQUIDITY_EXCEEDED()
        );

        _pool.totalBalanceXLong = totalBalXLong.safe128();
        _pool.totalBalanceYLong = totalBalYLong.safe128();
        _pool.totalBalanceXShort = totalBalXShort.safe128();
        _pool.totalBalanceYShort = totalBalYShort.safe128();
        _pool.totalBinShareX = xInYOut ? totalBinShareIn : totalBinShareOut;
        _pool.totalBinShareY = xInYOut ? totalBinShareOut : totalBinShareIn;
        _pool.activeBinShareX = xInYOut ? binShareIn : binShareOut;
        _pool.activeBinShareY = xInYOut ? binShareOut : binShareIn;
        _pool.activeId = binId;
        /// TODO: should also update priceInfo here ...............
        // TODO: also dont forget to incorporate fee into calculation, short and long balance must change

        if (amountOut >= minAmountOut) {
            TransferHelper.safeTransfer(tokenOut, recipient, amountOut);
        } else {
            revert SLIPPAGE_EXCEEDED();
        }

        //TODO: uint24 range = uint24(_priceInfo.maxId - _priceInfo.minId + 1); // we will come back to fix this because maxId and minId can be updated
    }
}
