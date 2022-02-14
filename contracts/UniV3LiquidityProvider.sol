//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import { IERC20Minimal } from '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';

import { LowGasSafeMath } from "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";


interface ChainlinkAggregatorV3Interface {
  function decimals() external view returns (uint8);

  // getRoundData and latestRoundData should both raise "No data present"
  // if they do not have data to report, instead of returning unset values
  // which could be misinterpreted as actual reported values.
  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
}

interface IWethToken {
    function deposit() external payable;
}

interface StETH {
    function submit(address _referral) external payable returns (uint256);
}

interface WstETH {
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function stEthPerToken() external view returns (uint256);
}

contract UniV3LiquidityProvider is IUniswapV3MintCallback {
  using LowGasSafeMath for uint256;

  IUniswapV3Pool public constant pool = IUniswapV3Pool(0xD340B57AAcDD10F96FC1CF10e15921936F41E29c);

  address public constant token0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH
  address public constant token1 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
  address public constant STETH_TOKEN = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

  address public constant CHAINLINK_STETH_ETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;

  uint256 public constant TOTAL_SLIPPAGE_POINTS = 1e4;
  uint256 public constant MAX_SLIPPAGE = 50; // value of TOTAL_SLIPPAGE_POINTS counts for 100%

  int24 public constant wideLowerTick = -970; // 1.1019
  int24 public constant wideUpperTick = 1630; // 0.8496

  /// Corresponds to 0.5% change from spot price 1.0609086
  uint24 public constant maxTickMovement = 50;

  bytes32 public immutable widePositionID;


  constructor() {
    pool.increaseObservationCardinalityNext(30); // TODO: remove?

    widePositionID = keccak256(abi.encodePacked(address(this), wideLowerTick, wideUpperTick));
  }

  receive() external payable {
  }

  function _getChainlinkBasedWstethPrice() internal view returns (uint256) {
    uint256 priceDecimals = ChainlinkAggregatorV3Interface(CHAINLINK_STETH_ETH_PRICE_FEED).decimals();
    // assert 0 < priceDecimals and priceDecimals <= 18
    (
      uint80 roundID, 
      int price,
      uint startedAt,
      uint timeStamp,
      uint80 answeredInRound
    ) = ChainlinkAggregatorV3Interface(CHAINLINK_STETH_ETH_PRICE_FEED).latestRoundData();

    assert(timeStamp != 0);
    uint256 ethPerSteth = uint256(price * int(10 ** (18 - priceDecimals)));
    uint256 stethPerWsteth = WstETH(token0).stEthPerToken();
    return ethPerSteth * stethPerWsteth;
  }

  function getSpotPrice() external view returns (uint256) {
    return _getSpotPrice();
  }

  function _getSpotPrice() internal view returns (uint256) {
    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
    return uint(sqrtRatioX96).mul(uint(sqrtRatioX96)).mul(1e18) >> (96 * 2);
  }

  function getCurrentPriceTick() external view returns (int24) {
    (, int24 currentTick, , , , , ) = pool.slot0();
    return currentTick;
  }

  // TODO: authentication
  function seed(uint128 _liquidity) external returns (
    uint256 token0Seeded,
    uint256 token1Seeded,
    uint256 token0Left,
    uint256 token1Left
  ) {
    // TODO: check current price

    (uint256 amount0, uint256 amount1) = pool.mint(
      address(this),
      wideLowerTick,
      wideUpperTick,
      _liquidity,
      abi.encode(msg.sender) // Data field for uniswapV3MintCallback
    );

    token0Left = IERC20Minimal(token0).balanceOf(address(this));
    token1Left = IERC20Minimal(token1).balanceOf(address(this));
    token0Seeded = amount0;
    token1Seeded = amount1;

    requireLimitedSlippageToTwapPrice();
    requireLimitedSlippageToChainlinkPrice();
  }

  function getAmountOfEthForWsteth(uint256 _amountOfWsteth) external view returns (uint256) {
    return _getAmountOfEthForWsteth(_amountOfWsteth);
  }

  function _getAmountOfEthForWsteth(uint256 _amountOfWsteth) internal view returns (uint256) {
    return (_amountOfWsteth * WstETH(token0).stEthPerToken()) / 1e18;
  }

  function exchangeForTokens(uint256 ethForWsteth, uint256 ethForWeth) external {
    _exchangeForTokens(ethForWsteth, ethForWeth);
  }

  function _exchangeForTokens(uint256 ethForWsteth, uint256 ethForWeth) internal {
      require(address(this).balance >= ethForWeth + ethForWsteth, "NOT_ENOUGH_ETH");

      IWethToken(token1).deposit{value: ethForWeth}();
      require(IERC20Minimal(token1).balanceOf(address(this)) == ethForWeth);

      StETH(STETH_TOKEN).submit{value: ethForWsteth}(address(0x00));
      require(IERC20Minimal(STETH_TOKEN).balanceOf(address(this)) == ethForWsteth - 1);

      IERC20Minimal(STETH_TOKEN).approve(token0, ethForWsteth);
      uint256 wstethAmount = WstETH(token0).wrap(ethForWsteth);
      require(IERC20Minimal(token0).balanceOf(address(this)) == wstethAmount);
  }

  function uniswapV3MintCallback(
    uint256 amount0Owed,
    uint256 amount1Owed,
    bytes calldata data
  ) external override {
    require(msg.sender == address(pool));

    uint256 ethForToken0 = _getAmountOfEthForWsteth(amount0Owed);
    _exchangeForTokens(ethForToken0 + 1, amount1Owed);

    require(IERC20Minimal(token0).balanceOf(address(this)) >= amount0Owed, "NOT_ENOUGH_TOKEN0");
    require(IERC20Minimal(token1).balanceOf(address(this)) >= amount1Owed, "NOT_ENOUGH_TOKEN1");

    require(amount0Owed > 0, "AMOUNT0OWED_IS_ZERO");
    require(amount1Owed > 0, "AMOUNT01WED_IS_ZERO");
    IERC20Minimal(token0).transfer(address(pool), amount0Owed);
    IERC20Minimal(token1).transfer(address(pool), amount1Owed);
  }

  /// @notice Ensure that the current price isn't too far from the 5 minute TWAP price
  function requireLimitedSlippageToTwapPrice() private view {
    (, int24 currentTick, , , , , ) = pool.slot0();

    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = 5 minutes;
    secondsAgos[1] = 0;
    (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);

    int24 averageTick = int24(int256(tickCumulatives[1] - tickCumulatives[0]) / 5 minutes);

    int24 diff = averageTick > currentTick ? averageTick - currentTick : currentTick - averageTick;
    require(uint24(diff) < maxTickMovement, "Slippage");
  }

  function _calcSlippage(uint256 chainlinkPrice, uint256 spotPrice) internal view returns (uint256 slippage) {
    int chainlinkPrice_ = int(chainlinkPrice / 1e18);
    int spotPrice_ = int(spotPrice);

    int slippage_ = ((spotPrice_ - chainlinkPrice_) * int(TOTAL_SLIPPAGE_POINTS)) / 1e18;
    if (slippage_ < 0)
      slippage_ = -slippage_;

    slippage = uint256(slippage_);
  }

  function calcSlippage(uint256 chainlinkPrice, uint256 spotPrice) public view returns (uint256 slippage) {
    return _calcSlippage(chainlinkPrice, spotPrice);
  }

  function requireLimitedSlippageToChainlinkPrice() private view {
    uint256 slippage = _calcSlippage(_getChainlinkBasedWstethPrice(), _getSpotPrice());
    if (slippage < 0)
      slippage = -slippage;
    require(slippage <= MAX_SLIPPAGE, "LARGE_SLIPPAGE");
  }

  // TODO: Add functions to withdraw tokens

}
