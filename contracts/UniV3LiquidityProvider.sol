//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import { IERC20Minimal } from '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';

import { LowGasSafeMath } from "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";


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

  address public admin;

  IUniswapV3Pool public constant pool = IUniswapV3Pool(0xD340B57AAcDD10F96FC1CF10e15921936F41E29c);

  address public constant TOKEN0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH
  address public constant TOKEN1 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
  address public constant STETH_TOKEN = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

  address public constant CHAINLINK_STETH_ETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;

  address public constant LIDO_AGENT = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;

  uint256 public constant TOTAL_SLIPPAGE_POINTS = 1e4;
  uint256 public constant MAX_DIFF_TO_CHAINLINK = 50; // value of TOTAL_SLIPPAGE_POINTS counts for 100%

  int24 public constant POSITION_LOWER_TICK = -1630; // 0.8496
  int24 public constant POSITION_UPPER_TICK = 970; // 1.1019

  /// The tick (corresponds to some price) we'd like not to be moved too far away from
  /// Corresponds to the price 1.0609086
  int24 public constant TARGET_TICK = 590;

  /// Corresponds to 0.5% price change from the price specified by TARGET_TICK
  /// Note this value is a subject of logarithm based calculations, it is not just
  /// that "1" corresponds to 0.01% as it might seem
  uint24 public constant MAX_TICK_MOVEMENT = 50;

  bytes32 public immutable POSITION_ID;

    /**
    * Emitted when the ERC20 `token` recovered (e.g. transferred)
    * to the Lido treasure address by `requestedBy` sender.
    */
    event ERC20Withdrawn(
        address indexed requestedBy,
        address indexed token,
        uint256 amount
    );

    /**
      * Emitted when the ERC721-compatible `token` (NFT) recovered (e.g. transferred)
      * to the Lido treasure address by `requestedBy` sender.
      */
    event ERC721Withdrawn(
        address indexed requestedBy,
        address indexed token,
        uint256 tokenId
    );

    event EthWithdrawn(
      address requestedBy,
      uint256 amount
    );


  modifier authAdminOrDao() {
    require(msg.sender == admin || msg.sender == LIDO_AGENT, "ONLY_ADMIN_OR_DAO_CAN");
    _;
  }

  constructor() {
    admin = msg.sender;

    POSITION_ID = keccak256(abi.encodePacked(address(this), POSITION_LOWER_TICK, POSITION_UPPER_TICK));
  }

  function setAdmin(address _admin) external authAdminOrDao() {
    require(msg.sender == admin, "ONLY_ADMIN_CAN");
    admin = _admin;
  }

  receive() external payable {
  }

  function _getChainlinkBasedWstethPrice() internal view returns (uint256) {
    uint256 priceDecimals = ChainlinkAggregatorV3Interface(CHAINLINK_STETH_ETH_PRICE_FEED).decimals();
    assert(0 < priceDecimals && priceDecimals <= 18);
    (
      uint80 roundID, 
      int price,
      uint startedAt,
      uint timeStamp,
      uint80 answeredInRound
    ) = ChainlinkAggregatorV3Interface(CHAINLINK_STETH_ETH_PRICE_FEED).latestRoundData();

    assert(timeStamp != 0);
    uint256 ethPerSteth = uint256(price * int(10 ** (18 - priceDecimals)));
    uint256 stethPerWsteth = WstETH(TOKEN0).stEthPerToken();
    return ethPerSteth * stethPerWsteth;
  }

  function _getSpotPrice() internal view returns (uint256) {
    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
    return uint(sqrtRatioX96).mul(uint(sqrtRatioX96)).mul(1e18) >> (96 * 2);
  }

  function seed(uint128 _liquidity) external authAdminOrDao() returns (
    uint256 token0Seeded,
    uint256 token1Seeded,
    uint256 token0Left,
    uint256 token1Left
  ) {
    require(_movementFromTargetPrice() <= MAX_TICK_MOVEMENT, "TICK_MOVEMENT_TOO_LARGE_AT_START");
    require(_getDiffToChainlinkPrice() <= MAX_DIFF_TO_CHAINLINK, "LARGE_DIFFERENCE_TO_CHAINLINK_PRICE_AT_START");

    (uint256 amount0, uint256 amount1) = pool.mint(
      address(this),
      POSITION_LOWER_TICK,
      POSITION_UPPER_TICK,
      _liquidity,
      abi.encode(msg.sender) // Data field for uniswapV3MintCallback
    );

    token0Left = IERC20Minimal(TOKEN0).balanceOf(address(this));
    token1Left = IERC20Minimal(TOKEN1).balanceOf(address(this));
    token0Seeded = amount0;
    token1Seeded = amount1;

    require(_movementFromTargetPrice() <= MAX_TICK_MOVEMENT, "TICK_MOVEMENT_TOO_LARGE");
    require(_getDiffToChainlinkPrice() <= MAX_DIFF_TO_CHAINLINK, "LARGE_DIFFERENCE_TO_CHAINLINK_PRICE");
  }

  function _getAmountOfEthForWsteth(uint256 _amountOfWsteth) internal view returns (uint256) {
    return (_amountOfWsteth * WstETH(TOKEN0).stEthPerToken()) / 1e18;
  }

  // Need to have ethForWsteth+2 on balance, due to exchanging for stETH eats 1 additional wei
  // and exchanging stETH for wstETH eats one more additional wei
  function _exchangeForTokens(uint256 _ethForWsteth, uint256 ethForWeth) internal {
    uint256 ethForSteth = _ethForWsteth + 2;
    uint256 stethForWsteth = _ethForWsteth + 1;
    require(address(this).balance >= ethForSteth + ethForWeth, "NOT_ENOUGH_ETH");

    StETH(STETH_TOKEN).submit{value: ethForSteth}(address(0x00));
    require(IERC20Minimal(STETH_TOKEN).balanceOf(address(this)) == stethForWsteth);

    IERC20Minimal(STETH_TOKEN).approve(TOKEN0, stethForWsteth);
    uint256 wstethAmount = WstETH(TOKEN0).wrap(stethForWsteth);
    require(IERC20Minimal(TOKEN0).balanceOf(address(this)) == wstethAmount);
 
    IWethToken(TOKEN1).deposit{value: ethForWeth}();
    require(IERC20Minimal(TOKEN1).balanceOf(address(this)) == ethForWeth);
  }

  function uniswapV3MintCallback(
    uint256 amount0Owed,
    uint256 amount1Owed,
    bytes calldata data
  ) external override {
    require(msg.sender == address(pool));

    uint256 ethForToken0 = _getAmountOfEthForWsteth(amount0Owed);
    _exchangeForTokens(ethForToken0 + 2, amount1Owed);

    require(IERC20Minimal(TOKEN0).balanceOf(address(this)) >= amount0Owed, "NOT_ENOUGH_TOKEN0");
    require(IERC20Minimal(TOKEN1).balanceOf(address(this)) >= amount1Owed, "NOT_ENOUGH_TOKEN1");

    require(amount0Owed > 0, "AMOUNT0OWED_IS_ZERO");
    require(amount1Owed > 0, "AMOUNT01WED_IS_ZERO");
    IERC20Minimal(TOKEN0).transfer(address(pool), amount0Owed);
    IERC20Minimal(TOKEN1).transfer(address(pool), amount1Owed);
  }

  /// Calced in ticks
  function _movementFromTargetPrice() internal view returns (uint24) {
    (, int24 currentTick, , , , , ) = pool.slot0();
    int24 movement = currentTick - TARGET_TICK;
    if (movement < 0) {
      movement = -movement;
    }
    return uint24(movement);
  }

  function _calcSpotToChainlinkPriceAbsDiff(uint256 chainlinkPrice, uint256 spotPrice)
    internal view returns (uint256 difference)
  {
    int chainlinkPrice_ = int(chainlinkPrice / 1e18);
    int spotPrice_ = int(spotPrice);

    int diff = ((spotPrice_ - chainlinkPrice_) * int(TOTAL_SLIPPAGE_POINTS)) / 1e18;
    if (diff < 0)
      diff = -diff;

    difference = uint256(diff);
  }


  function _getDiffToChainlinkPrice() internal view returns (uint256) {
    return _calcSpotToChainlinkPriceAbsDiff(_getChainlinkBasedWstethPrice(), _getSpotPrice());
  }

  /**
    * Transfers all of the ERC20-token (defined by the `_token` contract address)
    * to the Lido agent address.
    *
    * @param _token an ERC20-compatible token
    */
  function withdrawERC20(address _token) external authAdminOrDao() {
    uint256 amount = IERC20Minimal(_token).balanceOf(address(this));
    emit ERC20Withdrawn(msg.sender, _token, amount);
    require(IERC20Minimal(_token).transfer(LIDO_AGENT, amount));
  }

  /**
    * Transfers a given token_id of an ERC721-compatible NFT (defined by the token contract address)
    * currently belonging to the burner contract address to the Lido agent address.
    *
    * @param _token an ERC721-compatible token
    * @param _tokenId minted token id
    */
  function withdrawERC721(address _token, uint256 _tokenId) external authAdminOrDao() {
      emit ERC721Withdrawn(msg.sender, _token, _tokenId);

      IERC721(_token).transferFrom(address(this), LIDO_AGENT, _tokenId);
  }

  function withdrawETH() external authAdminOrDao() {
    emit EthWithdrawn(msg.sender, address(this).balance);
    (bool success, ) = LIDO_AGENT.call{value: address(this).balance}("");
    require(success);
  }

}
