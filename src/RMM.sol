// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {console2} from "lib/forge-std/src/console2.sol";

import "./lib/RmmLib.sol";
import "./lib/RmmErrors.sol";
import "./lib/RmmEvents.sol";
import "./lib/LiquidityLib.sol";

contract RMM is ERC20 {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    using SafeTransferLib for ERC20;

    uint256 public sigma;
    uint256 public fee;
    uint256 public maturity;

    uint256 public reserveX;
    uint256 public reserveY;
    uint256 public totalLiquidity;
    uint256 public strike;

    uint256 public lastTimestamp;
    uint256 public lastImpliedPrice;

    uint256 private _lock = 1;

    modifier lock() {
        if (_lock != 1) revert Reentrancy();
        _lock = 0;
        _;
        _lock = 1;
    }

    /// @dev Applies updates to the trading function and validates the adjustment.
    modifier evolve(PYIndex index) {
        _;
        int256 terminal = tradingFunction(index);

        if (abs(terminal) > 100) {
            revert OutOfRange(terminal);
        }
    }

    constructor(string memory name_, string memory symbol_, address PT_, uint256 sigma_, uint256 fee_)
        ERC20(name_, symbol_, 18)
    {
        PT = IPPrincipalToken(PT_);
        SY = IStandardizedYield(PT.SY());
        YT = IPYieldToken(PT.YT());
        SY_scalar = scalar(address(SY));
        PT_scalar = scalar(address(PT));
        sigma = sigma_;
        maturity = PT.expiry();
        fee = fee_;

        // Sets approvals ahead of time for this contract to handle routing.
        {
            // curly braces scope avoids stack too deep
            address[] memory tokensIn = SY.getTokensIn();
            uint256 length = tokensIn.length;

            for (uint256 i; i < length; ++i) {
                ERC20 token = ERC20(tokensIn[i]);
                if (address(token) != address(0)) token.approve(address(SY), type(uint256).max);
            }
        }
    }

    function init(uint256 priceX, uint256 amountX, uint256 strike_)
        external
        lock
        returns (uint256 totalLiquidity_, uint256 amountY)
    {
        if (strike_ <= 1e18 || strike != 0) revert InvalidStrike();

        PYIndex index = YT.newIndex();
        (totalLiquidity_, amountY) = prepareInit(priceX, amountX, strike_, sigma, index);

        _mint(msg.sender, totalLiquidity_ - 1000);
        _mint(address(0), 1000);
        _adjust(toInt(amountX), toInt(amountY), toInt(totalLiquidity_), strike_, index);
        _debit(address(SY), reserveX);
        _debit(address(PT), reserveY);

        emit Init(
            msg.sender, address(SY), address(PT), amountX, amountY, totalLiquidity_, strike_, sigma, fee, maturity
        );
    }

    receive() external payable {}

    /// @dev Swaps SY for YT, sending at least `minAmountOut` YT to `to`.
    /// @notice `amountIn` is an amount of PT that needs to be minted from the SY in and the SY flash swapped from the pool
    /// @notice Order of operations is as follows:
    /// 1. Compute amount PT to pull from the pool, this PT is destined to be swapped for SY
    /// 2. Compute the amount of SY out given that we are swapping in the borrowed PT
    /// 3. Adjust the pool state, execute the PT -> SY swap
    /// 4. Compute the SY in needed to cover the flash swapped PT
    /// 5. Send the YT to the recipient
    function swapExactSyForYt(
        uint256 maxSyIn,
        uint256 amountPtToFlash,
        uint256 minAmountOut,
        uint256 upperBound,
        uint256 epsilon,
        address to
    ) external lock returns (uint256 amountOut, int256 deltaLiquidity) {
        PYIndex index = YT.newIndex();
        uint256 amountInWad;
        uint256 amountOutWad;
        uint256 strike_;
        
        // compute amount PT to pull from the pool
        amountPtToFlash = computeSYToYT(index, maxSyIn, upperBound, block.timestamp, amountPtToFlash, epsilon);

        (amountInWad, amountOutWad, amountOut, deltaLiquidity, strike_) =
            prepareSwapPtIn(amountPtToFlash, block.timestamp, index);

        _adjust(-toInt(amountOutWad), toInt(amountInWad), deltaLiquidity, strike_, index);

        // SY is needed to cover the minted PT, so we need to debit the delta from the msg.sender
        uint256 delta = index.assetToSyUp(amountInWad) - amountOutWad;

        uint256 ytOut = amountOut + delta;

        if (delta > maxSyIn) {
            revert ExcessInput(maxSyIn, maxSyIn, delta);
        }

        (uint256 debitNative) = _debit(address(SY), delta);

        amountOut = mintPtYt(ytOut, address(this));

        if (amountOut < minAmountOut) {
            revert InsufficientOutput(amountInWad, minAmountOut, amountOut);
        }

        _credit(address(YT), to, amountOut);

        emit Swap(msg.sender, to, address(SY), address(YT), debitNative, amountOut, deltaLiquidity);
    }

    struct SwapToYt {
        address tokenIn;
        uint256 amountTokenIn;
        uint256 amountNativeIn;
        uint256 amountPtIn;
        uint256 minSyMinted;
        uint256 realSyMinted;
        uint256 minYtOut;
        uint256 realYtOut;
        address to;
    }

    function swapExactTokenForYt(
        address token,
        uint256 amountTokenIn,
        uint256 amountPtForFlashSwap,
        uint256 minSyMinted,
        uint256 minYtOut,
        uint256 upperBound,
        uint256 epsilon,
        address to
    ) external payable lock returns (uint256 amountInWad, uint256 amountOutWad, int256 deltaLiquidity) {
        SwapToYt memory swap;
        swap.tokenIn = token;
        swap.amountTokenIn = token == address(0) ? 0 : amountTokenIn;
        swap.amountNativeIn = msg.value;
        swap.amountPtIn = amountPtForFlashSwap;
        swap.minSyMinted = minSyMinted;
        swap.minYtOut = minYtOut;
        swap.to = to;
        swap.realSyMinted = _mintSYFromNativeAndToken(address(this), swap.tokenIn, swap.amountTokenIn, swap.minSyMinted);

        PYIndex index = YT.newIndex();
        uint256 strike_;
        uint256 amountOut;

        swap.amountPtIn = computeSYToYT(index, swap.realSyMinted, upperBound, block.timestamp, swap.amountPtIn, epsilon);

        (amountInWad, amountOutWad, amountOut, deltaLiquidity, strike_) =
            prepareSwapPtIn(swap.amountPtIn, block.timestamp, index);

        _adjust(-toInt(amountOutWad), toInt(amountInWad), deltaLiquidity, strike_, index);

        // SY is needed to cover the minted PT, so we need to debit the delta from the msg.sender
        swap.realYtOut = amountOut + (index.assetToSyUp(amountInWad) - amountOutWad);

        // Converts the SY received from minting it into its components PT and YT.
        amountOut = mintPtYt(swap.realYtOut, address(this));
        swap.realYtOut = amountOut;

        if (swap.realYtOut < swap.minYtOut) {
            revert InsufficientOutput(amountInWad, swap.minYtOut, swap.realYtOut);
        }

        _credit(address(YT), to, swap.realYtOut);

        uint256 debitSurplus = address(this).balance;
        if (debitSurplus > 0) {
            SafeTransferLib.safeTransferETH(swap.to, debitSurplus);
        }

        emit Swap(
            msg.sender,
            swap.to,
            address(SY),
            address(YT),
            swap.amountTokenIn + swap.amountNativeIn - debitSurplus,
            swap.realYtOut,
            deltaLiquidity
        );
    }

    function swapExactPtForSy(uint256 amountIn, uint256 minAmountOut, address to)
        external
        payable
        lock
        returns (uint256 amountOut, int256 deltaLiquidity)
    {
        PYIndex index = YT.newIndex();
        uint256 amountInWad;
        uint256 amountOutWad;
        uint256 strike_;

        (amountInWad, amountOutWad, amountOut, deltaLiquidity, strike_) =
            prepareSwapPtIn(amountIn, block.timestamp, index);

        if (amountOut < minAmountOut) {
            revert InsufficientOutput(amountInWad, minAmountOut, amountOut);
        }

        _adjust(-toInt(amountOutWad), toInt(amountInWad), deltaLiquidity, strike_, index);
        (uint256 creditNative) = _credit(address(SY), to, amountOutWad);
        (uint256 debitNative) = _debit(address(PT), amountInWad);

        emit Swap(msg.sender, to, address(PT), address(SY), debitNative, creditNative, deltaLiquidity);
    }

    function swapExactSyForPt(uint256 amountIn, uint256 minAmountOut, address to)
        external
        payable
        lock
        returns (uint256 amountOut, int256 deltaLiquidity)
    {
        PYIndex index = YT.newIndex();
        uint256 amountInWad;
        uint256 amountOutWad;
        uint256 strike_;

        (amountInWad, amountOutWad, amountOut, deltaLiquidity, strike_) =
            prepareSwapSyIn(amountIn, block.timestamp, index);

        if (amountOut < minAmountOut) {
            revert InsufficientOutput(amountInWad, minAmountOut, amountOut);
        }

        _adjust(toInt(amountInWad), -toInt(amountOutWad), deltaLiquidity, strike_, index);
        (uint256 creditNative) = _credit(address(PT), to, amountOutWad);
        (uint256 debitNative) = _debit(address(SY), amountInWad);

        emit Swap(msg.sender, to, address(SY), address(PT), debitNative, creditNative, deltaLiquidity);
    }

    /// 
    function swapExactYtForSy(uint256 ytIn, uint256 maxSyIn, address to)
        external
        lock
        returns (uint256 amountOut, uint256 amountIn, int256 deltaLiquidity)
    {
        PYIndex index = YT.newIndex();
        uint256 amountInWad;
        uint256 amountOutWad;
        uint256 strike_;

        // amount PT out must == ytIn so that we can recombine to SY and cover the SY in side of the swap
        (amountInWad, amountOutWad, amountIn, deltaLiquidity, strike_) =
            prepareSwapSyForExactPt(ytIn, block.timestamp, index);

        if (amountIn > maxSyIn) {
            revert ExcessInput(ytIn, maxSyIn, amountIn);
        }

        _adjust(toInt(amountInWad), -toInt(amountOutWad), deltaLiquidity, strike_, index);
        (uint256 creditNative) = _debit(address(YT), ytIn);
        uint256 amountSy = redeemPy(ytIn, address(this));
        amountOut = amountSy - amountInWad;
        amountIn = amountInWad;
        (uint256 debitNative) = _credit(address(SY), to, amountOut);

        emit Swap(msg.sender, to, address(PT), address(SY), debitNative, creditNative, deltaLiquidity);
    }

    /// @notice uint256 deltaX is expected in SY units, uint256 deltaY is expected in PT units -- these are later converted into asset units for the math
    function allocate(bool inTermsOfX, uint256 amount, uint256 minLiquidityOut, address to)
        external
        lock
        returns (uint256)
    {
        if (block.timestamp >= maturity) revert MaturityReached();

        PYIndex index = YT.newIndex();
        (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity, uint256 lptMinted) =
            prepareAllocate(inTermsOfX, amount);
        if (deltaLiquidity < minLiquidityOut) {
            revert InsufficientOutput(amount, minLiquidityOut, deltaLiquidity);
        }

        _mint(to, lptMinted);
        _updateReserves(toInt(deltaXWad), toInt(deltaYWad), toInt(deltaLiquidity), index);

        (uint256 debitNativeX) = _debit(address(SY), deltaXWad);
        (uint256 debitNativeY) = _debit(address(PT), deltaYWad);

        emit Allocate(msg.sender, to, debitNativeX, debitNativeY, deltaLiquidity);

        return deltaLiquidity;
    }

    /// @dev Burns `deltaLiquidity` * `totalSupply` / `totalLiquidity` rounded up
    /// and returns `deltaLiquidity` * `reserveX` / `totalLiquidity`
    ///           + `deltaLiquidity` * `reserveY` / `totalLiquidity` of ERC-20 tokens.
    function deallocate(uint256 deltaLiquidity, uint256 minDeltaXOut, uint256 minDeltaYOut, address to)
        external
        lock
        returns (uint256 deltaX, uint256 deltaY)
    {
        (uint256 deltaXWad, uint256 deltaYWad, uint256 lptBurned) = prepareDeallocate(deltaLiquidity);
        (deltaX, deltaY) = (downscaleDown(deltaXWad, SY_scalar), downscaleDown(deltaYWad, PT_scalar));

        if (minDeltaXOut > deltaX) {
            revert InsufficientOutput(deltaLiquidity, minDeltaXOut, deltaX);
        }
        if (minDeltaYOut > deltaY) {
            revert InsufficientOutput(deltaLiquidity, minDeltaYOut, deltaY);
        }

        _burn(msg.sender, lptBurned); // uses state totalLiquidity
        _updateReserves(-toInt(deltaXWad), -toInt(deltaYWad), -toInt(deltaLiquidity), YT.newIndex());

        (uint256 creditNativeX) = _credit(address(SY), to, deltaXWad);
        (uint256 creditNativeY) = _credit(address(PT), to, deltaYWad);

        emit Deallocate(msg.sender, to, creditNativeX, creditNativeY, deltaLiquidity);
    }

    /// @notice this is used in place of _adjust when executing an allocate or deallocate.
    /// @dev Apply reserve and liquidity updates then validate trading function with evolve modifier
    function _updateReserves(int256 deltaX, int256 deltaY, int256 deltaLiquidity, PYIndex index)
        internal
        evolve(index)
    {
        reserveX = sum(reserveX, deltaX);
        reserveY = sum(reserveY, deltaY);
        totalLiquidity = sum(totalLiquidity, deltaLiquidity);
    }

    // state updates
    /// @dev Applies an adjustment to the reserves, liquidity, and last timestamp before validating it with the trading function.
    function _adjust(int256 deltaX, int256 deltaY, int256 deltaLiquidity, uint256 strike_, PYIndex index)
        internal
        evolve(index)
    {
        lastTimestamp = block.timestamp;
        reserveX = sum(reserveX, deltaX);
        reserveY = sum(reserveY, deltaY);
        totalLiquidity = sum(totalLiquidity, deltaLiquidity);
        strike = strike_;
        int256 timeToExpiry = int256(maturity) - int256(block.timestamp);

        lastImpliedPrice = timeToExpiry > 0
            ? uint256(int256(computeSpotPrice(index.syToAsset(reserveX), totalLiquidity, strike, sigma, lastTau())).lnWad() * int256(365 * 86400) / timeToExpiry)
            : 1 ether;
    }

    // payments
    /// @dev Handles the request of payment for a given token.
    function _debit(address token, uint256 amountWad) internal returns (uint256 paymentNative) {
        uint256 balanceNative = _balanceNative(token);
        uint256 amountNative = downscaleDown(amountWad, scalar(token));

        ERC20(token).safeTransferFrom(msg.sender, address(this), amountNative);

        paymentNative = _balanceNative(token) - balanceNative;
        if (paymentNative < amountNative) {
            revert InsufficientPayment(token, paymentNative, amountNative);
        }
    }

    /// @dev Handles sending tokens as payment to the recipient `to`.
    function _credit(address token, address to, uint256 amount) internal returns (uint256 paymentNative) {
        uint256 balanceNative = _balanceNative(token);
        uint256 amountNative = downscaleDown(amount, scalar(token));

        ERC20(token).safeTransfer(to, amountNative);

        paymentNative = balanceNative - _balanceNative(token);
        if (paymentNative < amountNative) {
            revert InsufficientPayment(token, paymentNative, amountNative);
        }
    }

    /// @dev Retrieves the balance of a token in this contract, reverting if the call fails or returns unexpected data.
    function _balanceNative(address token) internal view returns (uint256) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (!success || data.length != 32) revert BalanceError();
        return abi.decode(data, (uint256));
    }


    /// @dev Computes the trading function result using the current state.
    function tradingFunction(PYIndex index) public view returns (int256) {
        if (totalLiquidity == 0) return 0; // Not initialized.
        uint256 totalAsset = index.syToAsset(reserveX);
        return computeTradingFunction(totalAsset, reserveY, totalLiquidity, strike, sigma, lastTau());
    }

    function computeKGivenLastPrice(uint256 reserveX_, uint256 liquidity, uint256 sigma_, uint256 tau_)
        public
        view
        returns (uint256)
    {
        int256 timeToExpiry = int256(maturity - block.timestamp);
        int256 rt = int256(lastImpliedPrice) * int256(timeToExpiry) / int256(365 * 86400);
        int256 lastPrice = rt.expWad();

        uint256 a = sigma_.mulWadDown(sigma_).mulWadDown(tau_).mulWadDown(0.5 ether);
        // // $$\Phi^{-1} (1 - \frac{x}{L})$$
        int256 b = Gaussian.ppf(int256(1 ether - reserveX_.divWadDown(liquidity)));
        int256 exp = (b * (int256(computeSigmaSqrtTau(sigma_, tau_))) / 1e18 - int256(a)).expWad();
        return uint256(lastPrice).divWadDown(uint256(exp));
    }

    function computeTokenToYT(
        PYIndex index,
        address token,
        uint256 exactTokenIn,
        uint256 max,
        uint256 blockTime,
        uint256 initialGuess,
        uint256 epsilon
    ) public view returns (uint256 amountSyMinted, uint256 amountYtOut) {
        if (!SY.isValidTokenIn(token)) {
            revert InvalidTokenIn(token);
        }
        amountSyMinted = SY.previewDeposit(token, exactTokenIn);
        amountYtOut = computeSYToYT(index, amountSyMinted, max, blockTime, initialGuess, epsilon);
    }

    function computeSYToYT(
        PYIndex index,
        uint256 exactSYIn,
        uint256 max,
        uint256 blockTime,
        uint256 initialGuess,
        uint256 epsilon
    ) public view returns (uint256 guess) {
        uint256 min = exactSYIn;
        max = max > 0 ? max : calcMaxPtIn(index.syToAsset(reserveX), reserveY, totalLiquidity, strike);
        for (uint256 iter = 0; iter < 256; ++iter) {
            guess = initialGuess > 0 && iter == 0 ? initialGuess : (min + max) / 2;
            (,, uint256 amountOut,,) = prepareSwapPtIn(guess, blockTime, index);
            uint256 netSyToPt = index.assetToSyUp(guess);

            uint256 netSyToPull = netSyToPt - amountOut;
            if (netSyToPull <= exactSYIn) {
                if (isASmallerApproxB(netSyToPull, exactSYIn, epsilon)) {
                    return guess;
                }
                min = guess;
            } else {
                max = guess - 1;
            }
        }
    }

    //prepare calls
    function prepareInit(uint256 priceX, uint256 amountX, uint256 strike_, uint256 sigma_, PYIndex index)
        public
        view
        returns (uint256 totalLiquidity_, uint256 amountY)
    {
        uint256 totalAsset = index.syToAsset(amountX);
        uint256 tau_ = computeTauWadYears(maturity - block.timestamp);
        PoolPreCompute memory comp = PoolPreCompute({reserveInAsset: totalAsset, strike_: strike_, tau_: tau_});
        uint256 initialLiquidity =
            computeLGivenX({reserveX_: totalAsset, S: priceX, strike_: strike_, sigma_: sigma_, tau_: tau_});
        amountY =
            computeY({reserveX_: totalAsset, liquidity: initialLiquidity, strike_: strike_, sigma_: sigma_, tau_: tau_});
        totalLiquidity_ = solveL(comp, initialLiquidity, amountY, sigma_);
    }

    function prepareSwapSyForExactPt(uint256 ptOut, uint256 timestamp, PYIndex index)
        public
        view
        returns (uint256 amountInWad, uint256 ptOutWad, uint256 amountIn, int256 deltaLiquidity, uint256 strike_)
    {
        ptOutWad = upscale(ptOut, PT_scalar);
        // convert amountIn to assetIn, only for swapping X in
        PoolPreCompute memory comp = preparePoolPreCompute(index, timestamp);
        uint256 computedL = solveL(comp, totalLiquidity, reserveY, sigma);
        uint256 nextLiquidity = computeDeltaLYOut(
            ptOut, comp.reserveInAsset, reserveY, totalLiquidity, fee, comp.strike_, sigma, comp.tau_
        ) + computedL;

        uint256 nextReserveX = solveX(reserveY - ptOutWad, nextLiquidity, comp.strike_, sigma, comp.tau_);
        amountInWad = index.assetToSy(nextReserveX) - reserveX;
        amountIn = downscaleDown(amountInWad, SY_scalar);
        strike_ = comp.strike_;
        deltaLiquidity = toInt(nextLiquidity) - toInt(totalLiquidity);
    }

    function prepareSwapSyIn(uint256 amountIn, uint256 timestamp, PYIndex index)
        public
        view
        returns (uint256 amountInWad, uint256 amountOutWad, uint256 amountOut, int256 deltaLiquidity, uint256 strike_)
    {
        amountInWad = upscale(amountIn, SY_scalar);
        // convert amountIn to assetIn, only for swapping X in
        uint256 amountInAsset = index.syToAsset(amountInWad);

        PoolPreCompute memory comp = preparePoolPreCompute(index, timestamp);
        // compute liquidity
        uint256 computedL = solveL(comp, totalLiquidity, reserveY, sigma);
        uint256 nextLiquidity = computeDeltaLXIn(
            amountInAsset, comp.reserveInAsset, reserveY, totalLiquidity, fee, comp.strike_, sigma, comp.tau_
        ) + computedL;

        // compute reserves in asset
        uint256 nextReserveY =
            solveY(comp.reserveInAsset + amountInAsset, nextLiquidity, comp.strike_, sigma, comp.tau_);

        amountOutWad = reserveY - nextReserveY;
        amountOut = downscaleDown(amountOutWad, PT_scalar);
        strike_ = comp.strike_;
        deltaLiquidity = toInt(nextLiquidity) - toInt(totalLiquidity);
    }

    function prepareSwapPtIn(uint256 ptIn, uint256 timestamp, PYIndex index)
        public
        view
        returns (uint256 amountInWad, uint256 amountOutWad, uint256 amountOut, int256 deltaLiquidity, uint256 strike_)
    {
        amountInWad = upscale(ptIn, PT_scalar);
        PoolPreCompute memory comp = preparePoolPreCompute(index, timestamp);

        // compute liquidity
        uint256 computedL = solveL(comp, totalLiquidity, reserveY, sigma);
        uint256 nextLiquidity = computeDeltaLYIn(
            amountInWad, comp.reserveInAsset, reserveY, totalLiquidity, fee, comp.strike_, sigma, comp.tau_
        ) + computedL;

        // compute reserves
        uint256 nextReserveX = solveX(reserveY + amountInWad, nextLiquidity, comp.strike_, sigma, comp.tau_);

        amountOutWad = reserveX - index.assetToSy(nextReserveX);
        amountOut = downscaleDown(amountOutWad, SY_scalar);
        strike_ = comp.strike_;
        deltaLiquidity = toInt(nextLiquidity) - toInt(totalLiquidity);
    }

    /// @notice uint256 deltaX is expected in SY units, uint256 deltaY is expected in PT units
    function prepareAllocate(bool inTermsOfX, uint256 amount)
        public
        view
        returns (uint256 deltaXWad, uint256 deltaYWad, uint256 deltaLiquidity, uint256 lptMinted)
    {
        if (inTermsOfX) {
            deltaXWad = upscale(amount, SY_scalar);
            (deltaYWad, deltaLiquidity) = computeAllocationGivenDeltaX(deltaXWad, reserveX, reserveY, totalLiquidity);
        } else {
            deltaYWad = upscale(amount, PT_scalar);
            (deltaXWad, deltaLiquidity) = computeAllocationGivenDeltaY(deltaYWad, reserveX, reserveY, totalLiquidity);
        }

        lptMinted = deltaLiquidity.mulDivDown(totalSupply, totalLiquidity + deltaLiquidity);
    }

    function prepareDeallocate(uint256 deltaLiquidity)
        public
        view
        returns (uint256 deltaXWad, uint256 deltaYWad, uint256 lptBurned)
    {
        uint256 liquidity = totalLiquidity;
        deltaXWad = deltaLiquidity.mulDivDown(reserveX, liquidity);
        deltaYWad = deltaLiquidity.mulDivDown(reserveY, liquidity);
        lptBurned = deltaLiquidity.mulDivUp(totalSupply, liquidity);
    }

    function preparePoolPreCompute(PYIndex index, uint256 blockTime) public view returns (PoolPreCompute memory) {
        uint256 tau_ = futureTau(blockTime);
        uint256 totalAsset = index.syToAsset(reserveX);
        uint256 strike_ = computeKGivenLastPrice(totalAsset, totalLiquidity, sigma, tau_);
        return PoolPreCompute(totalAsset, strike_, tau_);
    }

    // tau computing
    /// @dev Computes the time to maturity based on the `lastTimestamp` and converts it to units of WAD years.
    function lastTau() public view returns (uint256) {
        if (maturity < lastTimestamp) {
            return 0;
        }

        return computeTauWadYears(maturity - lastTimestamp);
    }

    function futureTau(uint256 timestamp) public view returns (uint256) {
        if (maturity < timestamp) {
            return 0;
        }

        return computeTauWadYears(maturity - timestamp);
    }

    // token minting
    function mintPtYt(uint256 amount, address to) internal returns (uint256 amountPY) {
        SY.transfer(address(YT), amount);
        amountPY = YT.mintPY(to, to);
    }

    function mintSY(address receiver, address tokenIn, uint256 amountTokenToDeposit, uint256 minSharesOut)
        public
        payable
        returns (uint256 amountOut)
    {
        return _mintSYFromNativeAndToken(receiver, tokenIn, amountTokenToDeposit, minSharesOut);
    }

    function _mintSYFromNativeAndToken(address receiver, address tokenIn, uint256 amountTokenIn, uint256 minSyMinted)
        internal
        returns (uint256 amountSyOut)
    {
        if (!SY.isValidTokenIn(tokenIn)) revert InvalidTokenIn(tokenIn);

        if (tokenIn == address(0)) {
            amountSyOut = SY.deposit{value: msg.value}(receiver, address(0), msg.value, minSyMinted);
        } else {
            ERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountTokenIn);
            amountSyOut = SY.deposit(receiver, tokenIn, amountTokenIn, minSyMinted);
        }
    }

    function redeemPy(uint256 amount, address to) internal returns (uint256 amountOut) {
        PT.transfer(address(YT), amount);
        YT.transfer(address(YT), amount);
        amountOut = YT.redeemPY(to);
    }
}
