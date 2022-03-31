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

    uint256 public constant TOTAL_POINTS = 10000;  // Amount of points in 100%

    constructor(
        uint256 _ethAmount,
        int24 _positionLowerTick,
        int24 _positionUpperTick,
        int24 _minAllowedTick,
        int24 _maxAllowedTick
    ) UniV3LiquidityProvider(
        _ethAmount,
        _positionLowerTick,
        _positionUpperTick,
        _minAllowedTick,
        _maxAllowedTick
    ) {
    }

    /// returns wstEthOverWEthRatio
    function calcTokensRatio(int24 _tick) external view returns (uint256) {
        return _calcTokensRatio(_tick);
    }

    function calcTokensRatioFromSqrtPrice(uint160 _sqrtPriceX86) external view returns (uint256 wstEthOverWEthRatio) {
        return _calcTokensRatioFromSqrtPrice(_sqrtPriceX86);
    }

    function calcTokenAmounts(int24 _tick, uint256 _ethAmount) external view
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _calcTokenAmounts(_tick, _ethAmount);
    }

    function calcTokenAmountsFromCurrentPoolSqrtPrice(uint256 _ethAmount) external view
        returns (uint256 amount0, uint256 amount1)
    {
        return _calcTokenAmountsFromCurrentPoolSqrtPrice(_ethAmount);
    }

    function calcMinTokenAmounts(int24 _minTick, int24 _maxTick) external view
        returns (
            uint256 minWsteth,
            uint256 minWeth
    ) {
        return _calcMinTokenAmounts(_minTick, _maxTick);
    }

    function priceDeviationPoints(uint256 _priceOne, uint256 _priceTwo)
        public view returns (uint256 difference)
    {
        return _priceDeviationPoints(_priceOne, _priceTwo);
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
        ( , , , , , tickLower, tickUpper, liquidity, , , tokensOwed0, tokensOwed1)
            = NONFUNGIBLE_POSITION_MANAGER.positions(_tokenId);
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

    function uniswapV3MintCallback(
        uint256 _amount0Owed,
        uint256 _amount1Owed,
        bytes calldata _data
    ) external override
    {
        require(msg.sender == address(POOL));
        require(_amount0Owed > 0, "AMOUNT0OWED_IS_ZERO");
        require(_amount1Owed > 0, "AMOUNT1OWED_IS_ZERO");

        uint256 balanceBefore = address(this).balance;
        _wrapEthToTokens(_amount0Owed, _amount1Owed);

        require(address(this).balance - (balanceBefore - ETH_TO_SEED) < 10, "DEBUG_MOCK_TOO_MUCH_SPARE_ETH_LEFT");

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

    function _getChainlinkFeedLatestRoundDataPrice() internal view virtual returns (int256) {
        ( , int256 price, , uint256 timeStamp, ) = 
            ChainlinkAggregatorV3Interface(CHAINLINK_STETH_ETH_PRICE_FEED).latestRoundData();
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
