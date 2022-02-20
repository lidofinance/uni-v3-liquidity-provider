//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";

import { LowGasSafeMath } from "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TransferHelper } from "@uniswap/v3-core/contracts/libraries/TransferHelper.sol";


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
    function withdraw(uint wad) external;
}

interface StETH {
    function submit(address _referral) external payable returns (uint256);
}

interface WstETH {
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _stETHAmount) external returns (uint256);
    function stEthPerToken() external view returns (uint256);
}

contract UniV3LiquidityProvider is IUniswapV3MintCallback, IERC721Receiver {
  using LowGasSafeMath for uint256;

  address public admin;

  IUniswapV3Pool public constant pool = IUniswapV3Pool(0xD340B57AAcDD10F96FC1CF10e15921936F41E29c);
  INonfungiblePositionManager public constant nonfungiblePositionManager = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

  address public constant TOKEN0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH
  address public constant TOKEN1 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
  address public constant STETH_TOKEN = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

  address public constant CHAINLINK_STETH_ETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;

  address public constant LIDO_AGENT = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;


  uint256 public constant TOTAL_POINTS = 10000; // amount of points in 1000%
  uint256 public constant MAX_DIFF_TO_CHAINLINK_POINTS = 50; // corresponds to 0.5%


  int24 public constant POSITION_LOWER_TICK = -1630; // 0.8496
  int24 public constant POSITION_UPPER_TICK = 970; // 1.1019

  /// The pool price tick we'd like not to be moved too far away from
  int24 public constant DESIRED_TICK = 590; // corresponds to the price 1.0609086

  /// Corresponds to 0.5% price change from the price specified by DESIRED_TICK
  /// Note this value is a subject of logarithm based calculations, it is not just
  /// that "1" corresponds to 0.01% as it might seem
  uint24 public constant MAX_DIFF_FROM_TARGET_PRICE_TICKS = 50;

  bytes32 public POSITION_ID;

  uint24 POOL_FEE = 500;

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

  event EthWithdrawn(address requestedBy, uint256 amount);

  event AdminSet(address newAdmin);

  event LeftoversRefunded(uint256 ethAmount, uint256 stEthAmount);


  modifier authAdminOrDao() {
    require(msg.sender == admin || msg.sender == LIDO_AGENT, "ONLY_ADMIN_OR_DAO_CAN");
    _;
  }

  constructor() {
    admin = msg.sender;

    POSITION_ID = keccak256(abi.encodePacked(address(this), POSITION_LOWER_TICK, POSITION_UPPER_TICK));
  }

  function setAdmin(address _admin) external authAdminOrDao() {
    emit AdminSet(_admin);
    admin = _admin;
  }

  receive() external payable {
  }

  function _getChainlinkBasedWstethPrice() internal view returns (uint256) {
    uint256 priceDecimals = ChainlinkAggregatorV3Interface(CHAINLINK_STETH_ETH_PRICE_FEED).decimals();
    assert(0 < priceDecimals && priceDecimals <= 18);

    ( , int price, , uint timeStamp, ) = ChainlinkAggregatorV3Interface(CHAINLINK_STETH_ETH_PRICE_FEED).latestRoundData();

    assert(timeStamp != 0);
    uint256 ethPerSteth = uint256(price) * 10**(18 - priceDecimals);
    uint256 stethPerWsteth = WstETH(TOKEN0).stEthPerToken();
    return (ethPerSteth * stethPerWsteth) / 1e18;
  }

  function _getSpotPrice() internal view returns (uint256) {
    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
    return uint(sqrtRatioX96).mul(uint(sqrtRatioX96)).mul(1e18) >> (96 * 2);
  }

  function _exchangeEthForTokens(uint256 amount0, uint256 amount1) internal {
    // Need to add 1 wei because the last point of stETH cannot be transferred
    // and 1 more for wstETH (TODO: is it the same problem with wstETH?)
    // TODO: why for larget amounts of tokens we need more wei"
    uint256 ethForWsteth = 1000 + _getAmountOfEthForWsteth(amount0);
    uint256 ethForWeth = amount1;
    require(address(this).balance >= ethForWsteth + ethForWeth, "NOT_ENOUGH_ETH");

    (bool success, ) = TOKEN0.call{value: ethForWsteth}("");
    require(success, "WSTETH_MINTING_FAILED");
    IWethToken(TOKEN1).deposit{value: ethForWeth}();
    require(IERC20(TOKEN0).balanceOf(address(this)) >= amount0, "NOT_ENOUGH_WSTETH");
    require(IERC20(TOKEN1).balanceOf(address(this)) >= amount1, "NOT_ENOUGH_WETH");
  }

  function seed(uint128 _liquidity) external authAdminOrDao() returns (
    uint256 token0Seeded,
    uint256 token1Seeded
  ) {
    require(_shiftFromDesirableTick() <= MAX_DIFF_FROM_TARGET_PRICE_TICKS, "TICK_MOVEMENT_TOO_LARGE_AT_START");
    require(_pointsFromChainlinkPrice() <= MAX_DIFF_TO_CHAINLINK_POINTS, "LARGE_DIFFERENCE_TO_CHAINLINK_PRICE_AT_START");

    (token0Seeded, token1Seeded) = pool.mint(
      address(this),
      POSITION_LOWER_TICK,
      POSITION_UPPER_TICK,
      _liquidity,
      abi.encode(msg.sender) // Data field for uniswapV3MintCallback
    );

    require(_shiftFromDesirableTick() <= MAX_DIFF_FROM_TARGET_PRICE_TICKS, "TICK_MOVEMENT_TOO_LARGE");
    require(_pointsFromChainlinkPrice() <= MAX_DIFF_TO_CHAINLINK_POINTS, "LARGE_DIFFERENCE_TO_CHAINLINK_PRICE");
  }

  function uniswapV3MintCallback(
    uint256 amount0Owed,
    uint256 amount1Owed,
    bytes calldata data
  ) external override {
    require(msg.sender == address(pool));
    require(amount0Owed > 0, "AMOUNT0OWED_IS_ZERO");
    require(amount1Owed > 0, "AMOUNT1OWED_IS_ZERO");

    _exchangeEthForTokens(amount0Owed, amount1Owed);

    // // Need to add 1 wei because the last point of stETH cannot be transferred
    // // and 1 more for wstETH (TODO: is it the same problem with wstETH?)
    // uint256 ethForWsteth = 2 + _getAmountOfEthForWsteth(amount0Owed);
    // uint256 ethForWeth = amount1Owed;
    // require(address(this).balance >= ethForWsteth + ethForWeth, "NOT_ENOUGH_ETH");

    // (bool success, ) = TOKEN0.call{value: ethForWsteth}("");
    // require(success, "WSTETH_MINTING_FAILED");
    // IWethToken(TOKEN1).deposit{value: ethForWeth}();
    // require(IERC20(TOKEN0).balanceOf(address(this)) >= amount0Owed, "NOT_ENOUGH_WSTETH");
    // require(IERC20(TOKEN1).balanceOf(address(this)) >= amount1Owed, "NOT_ENOUGH_WETH");

    TransferHelper.safeTransfer(TOKEN0, address(pool), amount0Owed);
    TransferHelper.safeTransfer(TOKEN1, address(pool), amount1Owed);

    // TODO: decide use TransferHelper or just .transfer here
    // require(
    //   IERC20(TOKEN0).transfer(address(pool), amount0Owed)
    // );
    // require(
    //   IERC20(TOKEN1).transfer(address(pool), amount1Owed)
    // );
  }


  function _refundLeftoversToLidoAgent() internal {
    WstETH(TOKEN0).unwrap(IERC20(TOKEN0).balanceOf(address(this)));
    _withdrawERC20(STETH_TOKEN, IERC20(STETH_TOKEN).balanceOf(address(this)));

    IWethToken(TOKEN1).withdraw(IERC20(TOKEN1).balanceOf(address(this)));

    _withdrawETH();
  }


  function mint() external returns (
    uint256 amount0,
    uint256 amount1,
    uint128 liquidity,
    uint256 tokenId
  ) {
    uint256 amount0ToMint = 573688892681612830;
    uint256 amount1ToMint = 3219007875072315806;

    _exchangeEthForTokens(amount0ToMint, amount1ToMint);

    // TODO: Why TransferHelper.safeApprove from uniswap docs isn't in the lib?
    IERC20(TOKEN0).approve(address(nonfungiblePositionManager), amount0ToMint);
    IERC20(TOKEN1).approve(address(nonfungiblePositionManager), amount1ToMint);
    // TransferHelper.safeApprove(TOKEN0, address(nonfungiblePositionManager), amount0ToMint);
    // TransferHelper.safeApprove(TOKEN1, address(nonfungiblePositionManager), amount1ToMint);

    // struct MintParams {
    //     address token0;
    //     address token1;
    //     uint24 fee;
    //     int24 tickLower;
    //     int24 tickUpper;
    //     uint256 amount0Desired;
    //     uint256 amount1Desired;
    //     uint256 amount0Min;
    //     uint256 amount1Min;
    //     address recipient;
    //     uint256 deadline;
    // }
    INonfungiblePositionManager.MintParams memory params =
      INonfungiblePositionManager.MintParams({
        token0: TOKEN0,
        token1: TOKEN1,
        fee: pool.fee(),
        tickLower: POSITION_LOWER_TICK,
        tickUpper: POSITION_UPPER_TICK,
        amount0Desired: amount0ToMint,
        amount1Desired: amount1ToMint,
        amount0Min: 0, // TODO: specify
        amount1Min: 0,
        recipient: address(this),
        deadline: block.timestamp
      });

    // TODO: specify LIDO_AGENT as the recipient at once?
    (tokenId, liquidity, amount0, amount1) = nonfungiblePositionManager.mint(params);

    // check and transfer position NFT
    require(address(this) == nonfungiblePositionManager.ownerOf(tokenId));
    nonfungiblePositionManager.safeTransferFrom(address(this), LIDO_AGENT, tokenId);
    require(LIDO_AGENT == nonfungiblePositionManager.ownerOf(tokenId));

    _refundLeftoversToLidoAgent();
  }

  /**
    * @dev Whenever an {IERC721} `tokenId` token is transferred to this contract via {IERC721-safeTransferFrom}
    * by `operator` from `from`, this function is called.
    *
    * It must return its Solidity selector to confirm the token transfer.
    * If any other value is returned or the interface is not implemented by the recipient, the transfer will be reverted.
    *
    * The selector can be obtained in Solidity with `IERC721Receiver.onERC721Received.selector`.
    */
  function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4)
    {
      // TODO: remove because uni-v3 doesn't use safeTranferFrom
      require(false, "GOT NFT!");

      (, , address token0, address token1, , , , uint128 liquidity, , , , ) =
            nonfungiblePositionManager.positions(tokenId);
      
      // TODO: Is returning selector like this correct?
      return this.onERC721Received.selector;
    }

  function _getAmountOfEthForWsteth(uint256 _amountOfWsteth) internal view returns (uint256) {
    return (_amountOfWsteth * WstETH(TOKEN0).stEthPerToken()) / 1e18;
  }

  function _shiftFromDesirableTick() internal view returns (uint24) {
    // TODO: add abs and calc in if/else without conversion to int24
    (, int24 currentTick, , , , , ) = pool.slot0();
    int24 shift = currentTick - DESIRED_TICK;
    if (shift < 0) {
      shift = -shift;
    }
    return uint24(shift);
  }

  function _diffInPointsBetweenTwoPrices(uint256 chainlinkPrice, uint256 spotPrice)
    internal view returns (uint256 difference)
  {
    int chainlinkPrice_ = int(chainlinkPrice);
    int spotPrice_ = int(spotPrice);

    int diff = ((spotPrice_ - chainlinkPrice_) * int(TOTAL_POINTS)) / 1e18;
    if (diff < 0)
      diff = -diff;

    difference = uint256(diff);
  }


  function _pointsFromChainlinkPrice() internal view returns (uint256) {
    return _diffInPointsBetweenTwoPrices(_getChainlinkBasedWstethPrice(), _getSpotPrice());
  }

  function _withdrawERC20(address _token, uint256 _amount) internal {
    emit ERC20Withdrawn(msg.sender, _token, _amount);
    TransferHelper.safeTransfer(_token, LIDO_AGENT, _amount);
    // require(IERC20(_token).transfer(LIDO_AGENT, _amount));
  }

  /**
    * Transfers all of the ERC20-token (defined by the `_token` contract address)
    * to the Lido agent address.
    *
    * @param _token an ERC20-compatible token
    */
  function withdrawERC20(address _token, uint256 _amount) external authAdminOrDao() {
    _withdrawERC20(_token, _amount);
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
      // Performs check with `require` itself. Doesn't return bool as `transfer` for ERC20 does.
      IERC721(_token).safeTransferFrom(address(this), LIDO_AGENT, _tokenId);
  }

  function _withdrawETH() internal {
    emit EthWithdrawn(msg.sender, address(this).balance);
    (bool success, ) = LIDO_AGENT.call{value: address(this).balance}("");
    require(success);
  }

  function withdrawETH() external authAdminOrDao() {
    _withdrawETH();
  }

}
