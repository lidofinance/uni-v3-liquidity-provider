//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;


import "../UniV3LiquidityProvider.sol";


contract TestUniV3LiquidityProvider is UniV3LiquidityProvider {

  function calcSpotToChainlinkPriceAbsDiff(uint256 chainlinkPrice, uint256 spotPrice)
    public view returns (uint256 difference)
  {
    return super._calcSpotToChainlinkPriceAbsDiff(chainlinkPrice, spotPrice);
  }

  function movementFromTargetPrice() external view returns (uint24) {
    return super._movementFromTargetPrice();
  }

  function exchangeForTokens(uint256 ethForWsteth, uint256 ethForWeth) external {
    super._exchangeForTokens(ethForWsteth, ethForWeth);
  }

  function getAmountOfEthForWsteth(uint256 _amountOfWsteth) external view returns (uint256) {
    return super._getAmountOfEthForWsteth(_amountOfWsteth);
  }

  function getCurrentPriceTick() external view returns (int24) {
    (, int24 currentTick, , , , , ) = pool.slot0();
    return currentTick;
  }

  function getSpotPrice() external view returns (uint256) {
    return super._getSpotPrice();
  }

}
