//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { LowGasSafeMath } from "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import { TransferHelper } from "@uniswap/v3-core/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-core/contracts/libraries/SqrtPriceMath.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
// import "@uniswap/v3-core/contracts/libraries/FullMath.sol";

import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface IWETH {
    function deposit() external payable;
    function withdraw(uint wad) external;
}


interface IWstETH {
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _stETHAmount) external returns (uint256);
    function stEthPerToken() external view returns (uint256);
    function getStETHByWstETH(uint256 _wstETHAmount) external view returns (uint256);
}

// NB: Considerations about math precision
// To reduce the impact of rounding errors we use "Ray Math" taken from AAVE protocol
// A Ray is a unit with 27 decimals of precision.
// Variables storing values with 27 digits of precision are named with suffix "E27"

contract UniV3LiquidityProvider {
    using LowGasSafeMath for uint256;

    /// WstETH/Weth Uniswap V3 pool
    IUniswapV3Pool public constant POOL = IUniswapV3Pool(0xD340B57AAcDD10F96FC1CF10e15921936F41E29c);

    /// Uniswap V3 contract for seeding liquidity minting position NFT for any pool
    INonfungiblePositionManager public constant NONFUNGIBLE_POSITION_MANAGER =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    address public constant TOKEN0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH
    address public constant TOKEN1 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address public constant STETH_TOKEN = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant LIDO_AGENT = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;

    uint256 public constant TOTAL_POINTS = 10000; // amount of points in 100%

    int24 public constant POSITION_LOWER_TICK = -1630; // spot price 0.8496
    int24 public constant POSITION_UPPER_TICK = 970; // spot price 1.1019
    bytes32 public immutable POSITION_ID;

    /// Note this value is a subject of logarithm based calculations, it is not just
    /// that "1" corresponds to 0.01% as it might seem. But might be very close at current price
    uint24 public MAX_TICK_DEVIATION;

    /// Specifies an allowed range for value of desiredTick set in mint() call
    int24 public MIN_ALLOWED_DESIRED_TICK;
    int24 public MAX_ALLOWED_DESIRED_TICK;

    address public admin;

    /// Amount of ETH to use to provide liquidity
    uint256 public ethAmount;

    /// The pool price tick we'd like not to be moved too far away from
    int24 public desiredTick;

    /// Desired amounts of tokens for providing liquidity to the pool
    uint256 public desiredWstethAmount;
    uint256 public desiredWethAmount;

    /// Amount of liquidity provided for the position created in mint() function
    uint128 public liquidityProvided;

    /// NTF id of the liquidity position minted
    uint256 public liquidityPositionTokenId;

    /// Emitted when ETH is received by the contract
    event EthReceived(
        uint256 amount
    );

    /// Emitted when the liquidity parameters are modified
    /// Contains not only modified parameters but all parameters of interest
    event LiquidityParametersUpdated(
        uint256 ethAmount,
        int24 desiredTick,
        uint24 maxTickDeviation,
        int24 minAllowedDesiredTick,
        int24 maxAllowedDesiredTick,
        uint256 desiredWstethAmount,
        uint256 desiredWethAmount
    );

    /// Emitted when liquidity provided to UniswapV3 pool and
    /// liquidity position NFT is minted
    event LiquidityProvided(
        uint256 tokenId,
        uint128 liquidity,
        uint256 wstethAmount,
        uint256 wethAmount
    );

    /// Emitted when ETH is refunded to Lido agent contract
    event EthRefunded(
        address requestedBy,
        uint256 amount
    );

    /// Emitted when the ERC20 `token` refunded
    /// to the Lido agent address by `requestedBy` sender.
    event ERC20Refunded(
        address indexed requestedBy,
        address indexed token,
        uint256 amount
    );

    /// Emitted when the ERC721-compatible `token` (NFT) refunded
    /// to the Lido treasure address by `requestedBy` sender.
    event ERC721Refunded(
        address indexed requestedBy,
        address indexed token,
        uint256 tokenId
    );

    
    /// Emitted when liquidity position closed and fees collected
    /// to the Lido treasure address by `requestedBy` sender.
    event LiquidityRetracted(
        uint256 wstethAmount,
        uint256 wethAmount,
        uint256 wstethFeesCollected,
        uint256 wethFeesCollected
    );


    /// Emitted when new admin is set
    event AdminSet(address indexed admin);

    /**
     * @param _ethAmount Amount of Ether on the contract used for providing liquidity
     * @param _desiredTick Desired price tick (may be changed when mint() is called)
     * @param _maxTickDeviation Max tolerable deviation of pool current price
     * @param _maxAllowedDesiredTickChange Max change (abs value) of desired tick allowed after contract deployment
     *                                     We don't allow desired tick to be changed to much after the deployment
     */
    constructor(
        uint256 _ethAmount,
        int24 _desiredTick,
        uint24 _maxTickDeviation,
        uint24 _maxAllowedDesiredTickChange
    ) {
        admin = msg.sender;

        POSITION_ID = keccak256(abi.encodePacked(address(this), POSITION_LOWER_TICK, POSITION_UPPER_TICK));

        ethAmount = _ethAmount;
        MAX_TICK_DEVIATION = _maxTickDeviation;

        desiredTick = _desiredTick;
        MIN_ALLOWED_DESIRED_TICK = _desiredTick - int24(_maxAllowedDesiredTickChange);
        MAX_ALLOWED_DESIRED_TICK = _desiredTick + int24(_maxAllowedDesiredTickChange);
    }

    receive() external payable {
        emit EthReceived(msg.value);
    }

    modifier authAdminOrDao() {
        require(msg.sender == admin || msg.sender == LIDO_AGENT, "AUTH_ADMIN_OR_LIDO_AGENT");
        _;
    }

    function setAdmin(address _admin) external authAdminOrDao() {
        emit AdminSet(_admin);
        admin = _admin;
    }

    /**
     * Update desired tick and provide liquidity to the pool
     * 
     * @param _desiredTick New desired tick
     */
    function mint(int24 _desiredTick) external authAdminOrDao() returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) {
        require(_desiredTick >= MIN_ALLOWED_DESIRED_TICK && _desiredTick <= MAX_ALLOWED_DESIRED_TICK,
            'DESIRED_TICK_IS_OUT_OF_ALLOWED_RANGE');

        desiredTick = _desiredTick;
        require(desiredTick > POSITION_LOWER_TICK && desiredTick < POSITION_UPPER_TICK); // just one more sanity check
        require(_deviationFromDesiredTick() <= MAX_TICK_DEVIATION, "TICK_DEVIATION_TOO_BIG_AT_START");


        (uint256 desWsteth, uint256 desWeth) = _calcTokenAmountsFromCurrentPoolSqrtPrice(ethAmount);

        uint256 balanceBefore = address(this).balance;
        _wrapEthToTokens(desWsteth, desWeth);
        // TODO: remove this debug require
        require(address(this).balance - (balanceBefore - ethAmount) < 2, "DEBUG_TOO_MUCH_SPARE_ETH_LEFT");

        (uint256 minWsteth, uint256 minWeth) = _calcMinTokenAmounts(_desiredTick, MAX_TICK_DEVIATION);

        IERC20(TOKEN0).approve(address(NONFUNGIBLE_POSITION_MANAGER), desWsteth);
        IERC20(TOKEN1).approve(address(NONFUNGIBLE_POSITION_MANAGER), desWeth);


        // // One more sanity check: check current tick is within position range
        // (, int24 currentTick, , , , , ) = POOL.slot0();
        // require(currentTick > POSITION_LOWER_TICK && currentTick < POSITION_UPPER_TICK);
// 
        // _wrapEthToTokens(desiredWstethAmount, desiredWethAmount);

        IERC20(TOKEN0).approve(address(NONFUNGIBLE_POSITION_MANAGER), desWsteth);
        IERC20(TOKEN1).approve(address(NONFUNGIBLE_POSITION_MANAGER), desWeth);

        INonfungiblePositionManager.MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: TOKEN0,
                token1: TOKEN1,
                fee: POOL.fee(),
                tickLower: POSITION_LOWER_TICK,
                tickUpper: POSITION_UPPER_TICK,
                amount0Desired: desWsteth,
                amount1Desired: desWeth,
                amount0Min: minWsteth,
                amount1Min: minWeth,
                // amount0Min: 0,
                // amount1Min: 0,
                recipient: LIDO_AGENT,
                deadline: block.timestamp
            });
        (tokenId, liquidity, amount0, amount1) = NONFUNGIBLE_POSITION_MANAGER.mint(params);

        require(LIDO_AGENT == NONFUNGIBLE_POSITION_MANAGER.ownerOf(tokenId));
        require(amount0 >= minWsteth, "AMOUNT0_TOO_LITTLE");
        require(amount1 >= minWeth, "AMOUNT1_TOO_LITTLE");
        require(_deviationFromDesiredTick() <= MAX_TICK_DEVIATION, "TICK_DEVIATION_TOO_BIG_AFTER_SEEDING");

        liquidityProvided = liquidity;
        liquidityPositionTokenId = tokenId;
        
        IERC20(TOKEN0).approve(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(TOKEN1).approve(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        emit LiquidityProvided(tokenId, liquidity, amount0, amount1);

        _refundLeftoversToLidoAgent();
    }

    function closeLiquidityPosition() external authAdminOrDao() returns (
        uint256 amount0,
        uint256 amount1,
        uint256 amount0Fees,
        uint256 amount1Fees
    ) {
        // TODO: maybe adjust amount{0,1}Min for slippage protection
        //       is sandwich scary? is anything else is scarry?

        // amount0Min and amount1Min are price slippage checks
        // if the amount received after burning is not greater than these minimums, transaction will fail
        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: liquidityPositionTokenId,
                liquidity: liquidityProvided,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });

        (amount0, amount1) = NONFUNGIBLE_POSITION_MANAGER.decreaseLiquidity(params);
        require(amount0 > 0, "AMOUNT0_IS_ZERO");
        require(amount1 > 0, "AMOUNT1_IS_ZERO");

        (uint256 amount0Collected, uint256 amount1Collected) = NONFUNGIBLE_POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: liquidityPositionTokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,  // narrowing conversion is OK: with 1e18 precision there is
                amount1Max: type(uint128).max   // still enough space for any reasonable token amounts
            })
        );

        amount0Fees = amount0Collected - amount0;
        amount1Fees = amount1Collected - amount1;

        emit LiquidityRetracted(amount0, amount1, amount0Fees, amount1Fees);

        _refundLeftoversToLidoAgent();

        NONFUNGIBLE_POSITION_MANAGER.burn(liquidityPositionTokenId);
        liquidityPositionTokenId = 0;
    }

    function refundETH() external authAdminOrDao() {
        _refundETH();
    }

    /**
     * Transfers given amount of the ERC20-token to Lido agent
     *
     * @param _token an ERC20-compatible token
     * @param _amount amount of the token
     */
    function refundERC20(address _token, uint256 _amount) external authAdminOrDao() {
        _refundERC20(_token, _amount);
    }

    /**
     * Transfers a given token_id of an ERC721-compatible NFT to Lido agent
     *
     * @param _token an ERC721-compatible token
     * @param _tokenId minted token id
     */
    function refundERC721(address _token, uint256 _tokenId) external authAdminOrDao() {
        emit ERC721Refunded(msg.sender, _token, _tokenId);
        // Doesn't return bool as `transfer` for ERC20 does, because it performs 'require' check inside
        IERC721(_token).safeTransferFrom(address(this), LIDO_AGENT, _tokenId);
    }

    function _refundETH() internal {
        uint256 amount = address(this).balance;
        if (amount > 0) {
            emit EthRefunded(msg.sender, amount);
            (bool success, ) = LIDO_AGENT.call{value: amount}("");
            require(success);
        }
    }

    function _refundERC20(address _token, uint256 _amount) internal {
        emit ERC20Refunded(msg.sender, _token, _amount);
        TransferHelper.safeTransfer(_token, LIDO_AGENT, _amount);
    }

    /**
     * Calc needed token ratio at given price tick for the liquidity position
     *
     * @param _tick Price tick
     * @return wstEthOverWEthRatio (desiredWstethAmount / desiredWethAmount)
     */
    function _calcTokensRatio(int24 _tick) internal view returns (uint256 wstEthOverWEthRatio) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_tick);
        return _calcTokensRatioFromSqrtPrice(sqrtPriceX96);
    }

    function _calcTokensRatioFromSqrtPrice(uint160 _sqrtPriceX96) internal view
        returns (uint256 wstEthOverWEthRatioE27)
    {
        // We care only of ratio of tokens here, so the exact amount of liquidity isn't important
        // But the amount must be large enough to provide sufficient precision
        int128 liquidity = 1e27;  

        int256 amount0E27 = SqrtPriceMath.getAmount0Delta(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(POSITION_UPPER_TICK),
            liquidity
        );
        int256 amount1E27 = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtRatioAtTick(POSITION_LOWER_TICK),
            _sqrtPriceX96,
            liquidity
        );
        require(amount0E27 > 0);
        require(amount1E27 > 0);

        wstEthOverWEthRatioE27 = uint256((amount0E27 * 1e27) / amount1E27);
    }

    /**
     * Calc token amounts from wsteth/weth ratio
     *
     * @param _ratioE27 wsteth/weth target ratio with e27 precision
     * @param _ethAmount eth amount to use
     * @return amount0 Amounts of wsteth
     * @return amount1 Amount of weth
     */
    function _calcTokenAmountsFromRatio(uint256 _ratioE27, uint256 _ethAmount) internal view
        returns (uint256 amount0, uint256 amount1)
    {
        // The system from which the formulas derived:
        //   ratio = wsteth / weth
        //   eth = stEthPerToken * wsteth + weth
        //
        // The formulas used for calculation
        //   weth = eth / (ratio * stEthPerToken + 1)
        //   wsteth = ratio * weth


        // uint256 wstethPriceE27 = _getAmountOfEthForWsteth(oneE27);
        // uint256 wstethPriceE27 = IWstETH(TOKEN0).stEthPerToken();
        // uint256 wstethPriceE27 = IWstETH(TOKEN0).getStETHByWstETH(oneE27);

        uint256 oneE27 = 1e27;
        uint256 wstethPriceE27 = _getAmountOfEthForWsteth(oneE27);

        uint256 denominatorE27 = oneE27 + (_ratioE27 * wstethPriceE27) / oneE27;

        uint256 amount1E27 = (_ethAmount * 1e9 * oneE27) / denominatorE27;

        amount0 = (amount1E27 * _ratioE27) / (oneE27 * 1e9);

        amount1 = amount1E27 / 1e9;
    }

    function _calcTokenAmountsFromCurrentPoolSqrtPrice(uint256 _ethAmount) internal view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtRatioX96, , , , , , ) = POOL.slot0(); 
        uint256 ratio = _calcTokensRatioFromSqrtPrice(sqrtRatioX96);
        return _calcTokenAmountsFromRatio(ratio, _ethAmount);
    }

    function _calcTokenAmounts(int24 _tick, uint256 _ethAmount) internal view
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 ratio = _calcTokensRatio(_tick);
        return _calcTokenAmountsFromRatio(ratio, _ethAmount);
    }

    function _calcMinTokenAmounts(int24 _desiredTick, uint24 _maxTickDeviation) internal view
        returns (
            uint256 minWsteth,
            uint256 minWeth
    ) {
        uint256 ethAmountToUse = ethAmount;

        int24 minTick = _desiredTick - int24(_maxTickDeviation) - 1;
        int24 maxTick = _desiredTick + int24(_maxTickDeviation) + 1;
        (uint256 wstethForMinTick, uint256 wethForMinTick) = _calcTokenAmounts(minTick, ethAmountToUse);
        (uint256 wstethForMaxTick, uint256 wethForMaxTick) = _calcTokenAmounts(maxTick, ethAmountToUse);

        minWsteth = wstethForMaxTick;
        minWeth = wethForMinTick;
    }

    function _getAmountOfEthForWsteth(uint256 _amountOfWsteth) internal view returns (uint256) {
        return IWstETH(TOKEN0).getStETHByWstETH(_amountOfWsteth) + 1;
    }

    function _wrapEthToTokens(uint256 _amount0, uint256 _amount1) internal {
        uint256 ethForWsteth = _getAmountOfEthForWsteth(_amount0);
        uint256 ethForWeth = _amount1;
        require(address(this).balance >= ethForWsteth + ethForWeth, "NOT_ENOUGH_ETH");

        (bool success, ) = TOKEN0.call{value: ethForWsteth}("");
        require(success, "WSTETH_MINTING_FAILED");

        IWETH(TOKEN1).deposit{value: ethForWeth}();

        require(IERC20(TOKEN0).balanceOf(address(this)) >= _amount0, "NOT_ENOUGH_WSTETH");
        require(IERC20(TOKEN1).balanceOf(address(this)) >= _amount1, "NOT_ENOUGH_WETH");
    }

    function _refundLeftoversToLidoAgent() internal {
        uint256 token0Balance = IERC20(TOKEN0).balanceOf(address(this));
        if (token0Balance > 0) {
            IWstETH(TOKEN0).unwrap(token0Balance);
        }

        _refundERC20(STETH_TOKEN, IERC20(STETH_TOKEN).balanceOf(address(this)));

        IWETH(TOKEN1).withdraw(IERC20(TOKEN1).balanceOf(address(this)));
        _refundETH();
    }

    function _deviationFromDesiredTick() internal view returns (uint24) {
        (, int24 currentTick, , , , , ) = POOL.slot0();

        return (currentTick > desiredTick)
            ? uint24(currentTick - desiredTick)
            : uint24(desiredTick - currentTick);
    }

    // function _emitEventWithCurrentLiquidityParameters() internal returns (uint256) {
    //     emit LiquidityParametersUpdated(
    //         ethAmount,
    //         desiredTick,
    //         MAX_TICK_DEVIATION,
    //         MIN_ALLOWED_DESIRED_TICK,
    //         MAX_ALLOWED_DESIRED_TICK,
    //         desiredWethAmount,
    //         desiredWstethAmount
    //     );
    // }

}
