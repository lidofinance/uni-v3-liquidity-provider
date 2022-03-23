//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "../UniV3LiquidityProvider.sol";


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

    function calcDesiredTokenAmounts(int24 _tick, uint256 _ethAmount) external view
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _calcDesiredTokenAmounts(_tick, _ethAmount);
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
