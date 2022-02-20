//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;


import "../UniV3LiquidityProvider.sol";


contract TestUniV3LiquidityProvider is UniV3LiquidityProvider {

  function diffInPointsBetweenTwoPrices(uint256 chainlinkPrice, uint256 spotPrice)
    public view returns (uint256 difference)
  {
    return _diffInPointsBetweenTwoPrices(chainlinkPrice, spotPrice);
  }

  function shiftFromDesirableTick() external view returns (uint24) {
    return _shiftFromDesirableTick();
  }

  function getAmountOfEthForWsteth(uint256 _amountOfWsteth) external view returns (uint256) {
    return _getAmountOfEthForWsteth(_amountOfWsteth);
  }
  
  function getChainlinkBasedWstethPrice() external view returns (uint256) {
    return _getChainlinkBasedWstethPrice();
  }

  function getCurrentPriceTick() external view returns (int24) {
    (, int24 currentTick, , , , , ) = pool.slot0();
    return currentTick;
  }

  function getSpotPrice() external view returns (uint256) {
    return _getSpotPrice();
  }

  function getPositionLiquidity() external view returns (uint128) {
    (uint128 liquidity, , , , ) = pool.positions(POSITION_ID);
    // (
    //   liquidity,
    //   uint256 feeGrowthInside0LastX128,
    //   uint256 feeGrowthInside1LastX128,
    //   uint128 tokensOwed0,
    //   uint128 tokensOwed1
    // ) = pool.positions(POSITION_ID);
    return liquidity;
  }

  function getPositionTokenOwner(uint256 _tokenId) external view returns (address) {
    return nonfungiblePositionManager.ownerOf(_tokenId);
  }

  function refundLeftoversToLidoAgent() external {
    _refundLeftoversToLidoAgent();
  }

  function exchangeEthForTokens(uint256 amount0, uint256 amount1) external {
    _exchangeEthForTokens(amount0, amount1);
  }

}
