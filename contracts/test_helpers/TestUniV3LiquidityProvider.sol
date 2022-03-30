//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "../UniV3LiquidityProvider.sol";

import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";


interface ChainlinkAggregatorV3Interface {
    function decimals() external view returns (uint8);

    // getRoundData and latestRoundData should both raise "No data present"
    // if they do not have data to report, instead of returning unset values
    // which could be misinterpreted as actual reported values.
    function latestRoundData() external view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}


contract TestUniV3LiquidityProvider is 
    IERC721Receiver,
    IUniswapV3MintCallback,
    UniV3LiquidityProvider
{
    using LowGasSafeMath for uint256;

    address public constant CHAINLINK_STETH_ETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;

    constructor(
        uint256 _ethAmount,
        int24 _desiredTick,
        uint24 _maxTickDeviation,
        uint24 _maxAllowedDesiredTickChange
    ) UniV3LiquidityProvider(
        _ethAmount,
        _desiredTick,
        _maxTickDeviation,
        _maxAllowedDesiredTickChange
    ) {
    }

    /// returns wstEthOverWEthRatio
    function calcDesiredTokensRatio(int24 _tick) external view returns (uint256) {
        return _calcDesiredTokensRatio(_tick);
    }

    function calcDesiredTokensRatioFromSqrtPrice(uint160 _sqrtPriceX86) external view returns (uint256 wstEthOverWEthRatio) {
        return _calcDesiredTokensRatioFromSqrtPrice(_sqrtPriceX86);
    }

    function calcDesiredTokenAmounts(int24 _tick, uint256 _ethAmount) external view
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _calcDesiredTokenAmounts(_tick, _ethAmount);
    }

    // function calcDesiredTokensRatioFromSqrtPrice(uint160 _sqrtPriceX96) external view
    // {
    //     return _calcDesiredTokensRatioFromSqrtPrice(_sqrtPriceX96);
    // }

    // function calcDesiredTokenAmountsFromRatio(uint256 _ratio, uint256 _ethAmount) external view
    //     returns (uint256 amount0, uint256 amount1)
    // {
    //     return _calcDesiredTokenAmountsFromRatio(_ratio, _ethAmount);
    // }

    function calcDesiredTokensAmountsFromCurrentPoolSqrtPrice(uint256 _ethAmount) external view
        returns (uint256 amount0, uint256 amount1)
    {
        return _calcDesiredTokensAmountsFromCurrentPoolSqrtPrice(_ethAmount);
    }

    function calcDesiredAndMinTokenAmounts() external {
        _calcDesiredAndMinTokenAmounts();
    }

    function priceDeviationPoints(uint256 _priceOne, uint256 _priceTwo)
        public view returns (uint256 difference)
    {
        return _priceDeviationPoints(_priceOne, _priceTwo);
    }

    function deviationFromDesiredTick() external view returns (uint24) {
        return _deviationFromDesiredTick();
    }

    function getAmountOfEthForWsteth(uint256 _amountOfWsteth) external view returns (uint256) {
        return _getAmountOfEthForWsteth(_amountOfWsteth);
    }
    
    function getChainlinkBasedWstethPrice() external view returns (uint256) {
        return _getChainlinkBasedWstethPrice();
    }

    function getChainlinkFeedLatestRoundDataPrice() external view returns (int256) {
        return _getChainlinkFeedLatestRoundDataPrice();
    }

    function getCurrentPriceTick() external view returns (int24) {
        (, int24 currentTick, , , , , ) = POOL.slot0();
        return currentTick;
    }

    function getCurrentSqrtPriceX96() external view returns (uint160) {
        (uint160 sqrtPriceX96, , , , , , ) = POOL.slot0();
        return sqrtPriceX96;
    }

    function getSpotPrice() external view returns (uint256) {
        return _getSpotPrice();
    }

    function getPositionLiquidity() external view returns (uint128) {
        (uint128 liquidity, , , , ) = POOL.positions(POSITION_ID);
        return liquidity;
    }

    function refundLeftoversToLidoAgent() external {
        _refundLeftoversToLidoAgent();
    }

    function wrapEthToTokens(uint256 _amount0, uint256 _amount1) external {
        _wrapEthToTokens(_amount0, _amount1);
    }

    function getPositionInfo(uint256 _tokenId) external view returns (
        uint128 liquidity,
        uint128 tokensOwed0,
        uint128 tokensOwed1,
        int24 tickLower,
        int24 tickUpper
    ){
        (
            ,
            address operator,
            ,
            ,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            ,
            ,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = NONFUNGIBLE_POSITION_MANAGER.positions(_tokenId);
    }

    // Calc amounts by using POOL's mint (not NonFungibleTokenManager and not manual calculations)
    function calcTokenAmountsByPool(uint128 _liquidity) external authAdminOrDao() returns (
        uint256 token0Seeded,
        uint256 token1Seeded
    ) {
        (token0Seeded, token1Seeded) = POOL.mint(
            address(this),
            POSITION_LOWER_TICK,
            POSITION_UPPER_TICK,
            _liquidity,
            abi.encode(msg.sender) // Data field for uniswapV3MintCallback
        );
    }

    // A wrapper around library function
    function getSqrtRatioAtTick(int24 _tick) external view returns (uint160) {
        return TickMath.getSqrtRatioAtTick(_tick);
    }

    // A wrapper around library function
    function getTickAtSqrtRatio(uint160 _sqrtRatioX96) external view returns (int24) {
        return TickMath.getTickAtSqrtRatio(_sqrtRatioX96);
    }

    // A wrapper around library function for current pool state
    function getLiquidityForAmounts(uint256 amount0, uint256 amount1) external view returns (uint128 liquidity)
    {
        (uint160 sqrtPriceX96, , , , , , ) = POOL.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(POSITION_LOWER_TICK);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(POSITION_UPPER_TICK);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            amount0,
            amount1
        ); 
    }

    function uniswapV3MintCallback(
        uint256 _amount0Owed,
        uint256 _amount1Owed,
        bytes calldata _data
    ) external override
    {
        require(msg.sender == address(POOL));
        require(_amount0Owed > 0, "AMOUNT0OWED_IS_ZERO");
        require(_amount1Owed > 0, "AMOUNT1OWED_IS_ZERO");

        _wrapEthToTokens(_amount0Owed, _amount1Owed);

        TransferHelper.safeTransfer(TOKEN0, address(POOL), _amount0Owed);
        TransferHelper.safeTransfer(TOKEN1, address(POOL), _amount1Owed);
    }
    

    /**
     * @dev We expect it not to be executed as Uniswap-v3 doesn't use safeTransferFrom
     * Will revert if called to alert.
     */
    function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenId,
        bytes calldata data
    ) external override returns (bytes4)
    {
        require(false, "UNEXPECTED_POSITION_NFT");

        (, , address token0, address token1, , , , uint128 liquidity, , , , ) =
            NONFUNGIBLE_POSITION_MANAGER.positions(_tokenId);
        
        return this.onERC721Received.selector;
    }


    /**
     * FUNCTION FOR TEST PURPOSES
     * 
     * @param _desiredTick New desired tick
     */
    function mintTest(int24 _desiredTick) external authAdminOrDao() returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        uint256 ourAmount0,
        uint256 ourAmount1,
        uint256 poolRatio,
        uint256 ourRatio
    ) {
        require(_desiredTick >= MIN_ALLOWED_DESIRED_TICK && _desiredTick <= MAX_ALLOWED_DESIRED_TICK,
            'DESIRED_TICK_IS_OUT_OF_ALLOWED_RANGE');

        desiredTick = _desiredTick;
        require(desiredTick > POSITION_LOWER_TICK && desiredTick < POSITION_UPPER_TICK); // just one more sanity check

        _calcDesiredAndMinTokenAmounts();
        require(_deviationFromDesiredTick() <= MAX_TICK_DEVIATION, "TICK_DEVIATION_TOO_BIG_AT_START");

        _emitEventWithCurrentLiquidityParameters();

        // One more sanity check: check current tick is within position range
        (uint160 sqrtPriceX86, int24 currentTick, , , , , ) = POOL.slot0();
        require(currentTick > POSITION_LOWER_TICK && currentTick < POSITION_UPPER_TICK);

        // Calc amounts based on current pool sqrtPriceX96
        // (ourAmount0, ourAmount1) = _calcDesiredTokensAmountsFromCurrentPoolSqrtPrice(ethAmount - ETH_AMOUNT_MARGIN);
        // sqrtPriceX86 = TickMath.getSqrtRatioAtTick(currentTick);
        ourRatio = _calcDesiredTokensRatioFromSqrtPrice(sqrtPriceX86);
        (ourAmount0, ourAmount1) = _calcDesiredTokenAmountsFromRatio(ourRatio, ethAmount - ETH_AMOUNT_MARGIN);
        desiredWstethAmount = ourAmount0;
        desiredWethAmount = ourAmount1;

        _wrapEthToTokens(desiredWstethAmount, desiredWethAmount);

        IERC20(TOKEN0).approve(address(NONFUNGIBLE_POSITION_MANAGER), desiredWstethAmount);
        IERC20(TOKEN1).approve(address(NONFUNGIBLE_POSITION_MANAGER), desiredWethAmount);

        INonfungiblePositionManager.MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: TOKEN0,
                token1: TOKEN1,
                fee: POOL.fee(),
                tickLower: POSITION_LOWER_TICK,
                tickUpper: POSITION_UPPER_TICK,
                amount0Desired: desiredWstethAmount,
                amount1Desired: desiredWethAmount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: LIDO_AGENT,
                deadline: block.timestamp
            });
        

        (tokenId, liquidity, amount0, amount1) = NONFUNGIBLE_POSITION_MANAGER.mint(params);
        liquidityProvided = liquidity;
        liquidityPositionTokenId = tokenId;

        poolRatio = (amount0 * 1e18) / amount1;

        IERC20(TOKEN0).approve(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(TOKEN1).approve(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        emit LiquidityProvided(tokenId, liquidity, amount0, amount1);

        // require(amount0 >= minWstethAmount, "AMOUNT0_TOO_LITTLE");
        // require(amount1 >= minWethAmount, "AMOUNT1_TOO_LITTLE");
        require(_deviationFromDesiredTick() <= MAX_TICK_DEVIATION, "TICK_DEVIATION_TOO_BIG_AFTER_SEEDING");
        require(LIDO_AGENT == NONFUNGIBLE_POSITION_MANAGER.ownerOf(tokenId));

        _refundLeftoversToLidoAgent();
    }


    function _getChainlinkFeedLatestRoundDataPrice() internal view virtual returns (int256) {
        ( , int256 price, , uint256 timeStamp, ) = ChainlinkAggregatorV3Interface(CHAINLINK_STETH_ETH_PRICE_FEED).latestRoundData();
        assert(timeStamp != 0);
        return price;
    }

    function _getChainlinkBasedWstethPrice() internal view returns (uint256) {
        uint256 priceDecimals = ChainlinkAggregatorV3Interface(CHAINLINK_STETH_ETH_PRICE_FEED).decimals();
        assert(0 < priceDecimals && priceDecimals <= 18);

        int price = _getChainlinkFeedLatestRoundDataPrice();

        uint256 ethPerSteth = uint256(price) * 10**(18 - priceDecimals);
        uint256 stethPerWsteth = IWstETH(TOKEN0).stEthPerToken();
        return (ethPerSteth * stethPerWsteth) / 1e18;
    }

    function _priceDeviationPoints(uint256 _basePrice, uint256 _price)
        internal view returns (uint256 difference)
    {
        require(_basePrice > 0, "ZERO_BASE_PRICE");

        uint256 absDiff = _basePrice > _price
            ? _basePrice - _price
            : _price - _basePrice;

        return (absDiff * TOTAL_POINTS) / _basePrice;
    }

    function _deviationFromChainlinkPricePoints() internal view returns (uint256) {
        return _priceDeviationPoints(_getChainlinkBasedWstethPrice(), _getSpotPrice());
    }

    function _getSpotPrice() internal view returns (uint256) {
        (uint160 sqrtRatioX96, , , , , , ) = POOL.slot0();
        return uint(sqrtRatioX96).mul(uint(sqrtRatioX96)).mul(1e18) >> (96 * 2);
    }
}
