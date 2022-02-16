//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;


import "../UniV3LiquidityProvider.sol";


contract TestUniV3LiquidityProvider is UniV3LiquidityProvider {

  function calcSpotToChainlinkPriceAbsDiff(uint256 chainlinkPrice, uint256 spotPrice)
    public view returns (uint256 difference)
  {
    return _calcSpotToChainlinkPriceAbsDiff(chainlinkPrice, spotPrice);
  }

  function movementFromTargetPrice() external view returns (uint24) {
    return _movementFromTargetPrice();
  }

  function exchangeForTokens(uint256 ethForWsteth, uint256 ethForWeth) external {
    _exchangeForTokens(ethForWsteth, ethForWeth);
  }

  function getAmountOfEthForWsteth(uint256 _amountOfWsteth) external view returns (uint256) {
    return _getAmountOfEthForWsteth(_amountOfWsteth);
  }

  function getCurrentPriceTick() external view returns (int24) {
    (, int24 currentTick, , , , , ) = pool.slot0();
    return currentTick;
  }

  function getSpotPrice() external view returns (uint256) {
    return _getSpotPrice();
  }

  function getPositionInfo() external view returns (uint128 liquidity) {
    (
      uint128 liquidity,
      uint256 feeGrowthInside0LastX128,
      uint256 feeGrowthInside1LastX128,
      uint128 tokensOwed0,
      uint128 tokensOwed1
    ) = pool.positions(POSITION_ID);

  }

}
