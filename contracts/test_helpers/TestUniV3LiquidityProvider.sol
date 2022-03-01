//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "../UniV3LiquidityProvider.sol";


contract TestUniV3LiquidityProvider is 
    IERC721Receiver,
    IUniswapV3MintCallback,
    UniV3LiquidityProvider
{
    int256 public chainlinkOverriddenPrice;

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

    function setChainlinkPrice(int256 _price) external {
        chainlinkOverriddenPrice = _price;
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

    function getPositionTokenOwner(uint256 _tokenId) external view returns (address) {
        return NONFUNGIBLE_POSITION_MANAGER.ownerOf(_tokenId);
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

    function calcTokenAmounts(uint128 _liquidity) external authAdminOrDao() returns (
        uint256 token0Seeded,
        uint256 token1Seeded
    ) {
        // require(_deviationFromDesiredTick() <= MAX_TICK_DEVIATION, "TICK_MOVEMENT_TOO_LARGE_AT_START");
        // require(_deviationFromChainlinkPricePoints() <= MAX_DIFF_TO_CHAINLINK_POINTS, "LARGE_DIFFERENCE_TO_CHAINLINK_PRICE_AT_START");

        (token0Seeded, token1Seeded) = POOL.mint(
            address(this),
            POSITION_LOWER_TICK,
            POSITION_UPPER_TICK,
            _liquidity,
            abi.encode(msg.sender) // Data field for uniswapV3MintCallback
        );

        // require(_deviationFromDesiredTick() <= MAX_TICK_DEVIATION, "TICK_MOVEMENT_TOO_LARGE");
        // require(_deviationFromChainlinkPricePoints() <= MAX_DIFF_TO_CHAINLINK_POINTS, "LARGE_DIFFERENCE_TO_CHAINLINK_PRICE");
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

    function _getChainlinkFeedLatestRoundDataPrice() internal view override returns (int256) {
        if (0 == chainlinkOverriddenPrice) {
            return super._getChainlinkFeedLatestRoundDataPrice();
        } else {
            return chainlinkOverriddenPrice;
        }
    }

}
