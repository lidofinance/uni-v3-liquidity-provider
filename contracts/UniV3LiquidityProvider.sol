//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { LowGasSafeMath } from "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import { TransferHelper } from "@uniswap/v3-core/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-core/contracts/libraries/SqrtPriceMath.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


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


interface IWETH {
    function deposit() external payable;
    function withdraw(uint wad) external;
}


interface IWstETH {
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _stETHAmount) external returns (uint256);
    function stEthPerToken() external view returns (uint256);
}


contract UniV3LiquidityProvider {
    using LowGasSafeMath for uint256;

    /// WstETH/Weth Uniswap V3 pool
    IUniswapV3Pool public constant POOL = IUniswapV3Pool(0xD340B57AAcDD10F96FC1CF10e15921936F41E29c);

    /// Uniswap V3 contract for seeding liquidity minting position NFT for any pool
    INonfungiblePositionManager public constant NONFUNGIBLE_POSITION_MANAGER =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    address public constant TOKEN0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH
    address public constant TOKEN1 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address public constant STETH_TOKEN = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant LIDO_AGENT = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;
    address public constant CHAINLINK_STETH_ETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;

    uint256 public constant TOTAL_POINTS = 10000; // amount of points in 100%

    int24 public constant POSITION_LOWER_TICK = -1630; // spot price 0.8496
    int24 public constant POSITION_UPPER_TICK = 970; // spot price 1.1019
    bytes32 public immutable POSITION_ID;

    // Amount of ETH we don't use for calculations of token amounts
    uint256 public constant ETH_AMOUNT_MARGIN = 1e10;

    /// Note this value is a subject of logarithm based calculations, it is not just
    /// that "1" corresponds to 0.01% as it might seem. But might be very close at current price
    uint24 public MAX_TICK_DEVIATION;

    /// Specifies an allowed range for value of desiredTick set while minting
    int24 public MIN_ALLOWED_DESIRED_TICK;
    int24 public MAX_ALLOWED_DESIRED_TICK;

    address public admin;

    /// TODO: allow to change?
    uint256 public ethAmount;

    /// The pool price tick we'd like not to be moved too far away from
    int24 public desiredTick;

    /// Desired amounts of tokens for providing liquidity to the pool
    uint256 public desiredWstethAmount;
    uint256 public desiredWethAmount;

    /// Min amounts of tokens for providing liquidity to the pool
    /// Calculated based on MAX_TOKEN_AMOUNT_CHANGE_POINTS
    uint256 public minWstethAmount;
    uint256 public minWethAmount;

    /// Emitted when the liquidity parameters are modified (contains current values)
    event LiquidityParametersUpdated(
        uint256 ethAmount,
        int24 desiredTick,
        uint24 maxTickDeviation,
        int24 minAllowedDesiredTick,
        int24 maxAllowedDesiredTick,
        uint256 desiredWstethAmount,
        uint256 desiredWethAmount,
        uint256 minWstethAmount,
        uint256 minWethAmount
    );

    /// Emitted when liquidity provided to UniswapV3 pool and
    /// liquidity position NFT is minted
    event LiquidityProvided(
        uint256 tokenId,
        uint128 liquidity,
        uint256 wstethAmount,
        uint256 wethAmount
    );

    /// Emitted when ETH is refunded to Lido agent contract
    event EthRefunded(
        address requestedBy,
        uint256 amount
    );

    /**
     * Emitted when the ERC20 `token` refunded
     * to the Lido agent address by `requestedBy` sender.
     */
    event ERC20Refunded(
        address indexed requestedBy,
        address indexed token,
        uint256 amount
    );

    /**
     * Emitted when the ERC721-compatible `token` (NFT) refunded
     * to the Lido treasure address by `requestedBy` sender.
     */
    event ERC721Refunded(
        address indexed requestedBy,
        address indexed token,
        uint256 tokenId
    );

    /// Emitted when new admin is set
    event AdminSet(address indexed admin);

    constructor(
        uint256 _ethAmount,
        int24 _desiredTick,
        uint24 _maxTickDeviation,
        uint24 _maxAllowedDesiredTickChange
    ) {
        admin = msg.sender;

        POSITION_ID = keccak256(abi.encodePacked(address(this), POSITION_LOWER_TICK, POSITION_UPPER_TICK));

        ethAmount = _ethAmount - ETH_AMOUNT_MARGIN;
        MAX_TICK_DEVIATION = _maxTickDeviation;

        desiredTick = _desiredTick;
        MIN_ALLOWED_DESIRED_TICK = _desiredTick - int24(_maxAllowedDesiredTickChange);
        MAX_ALLOWED_DESIRED_TICK = _desiredTick + int24(_maxAllowedDesiredTickChange);
        _calcDesiredAndMinTokenAmounts();

        _emitEventWithCurrentLiquidityParameters();
    }

    receive() external payable {
    }

    modifier authAdminOrDao() {
        require(msg.sender == admin || msg.sender == LIDO_AGENT, "AUTH_ADMIN_OR_LIDO_AGENT");
        _;
    }

    function setAdmin(address _admin) external authAdminOrDao() {
        emit AdminSet(_admin);
        admin = _admin;
    }

    function mint(int24 _desiredTick) external authAdminOrDao() returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) {
        require(_desiredTick >= MIN_ALLOWED_DESIRED_TICK && _desiredTick <= MAX_ALLOWED_DESIRED_TICK,
            'DESIRED_TICK_IS_OUT_OF_ALLOWED_RANGE');
        desiredTick = _desiredTick;
        _calcDesiredAndMinTokenAmounts();
        _emitEventWithCurrentLiquidityParameters();

        require(_deviationFromDesiredTick() <= MAX_TICK_DEVIATION, "TICK_DEVIATION_TOO_BIG_AT_START");
        require(desiredTick > POSITION_LOWER_TICK && desiredTick < POSITION_UPPER_TICK);

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
                amount0Min: minWstethAmount,
                amount1Min: minWethAmount,
                recipient: LIDO_AGENT,
                deadline: block.timestamp
            });

        (tokenId, liquidity, amount0, amount1) = NONFUNGIBLE_POSITION_MANAGER.mint(params);
        
        IERC20(TOKEN0).approve(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(TOKEN1).approve(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        emit LiquidityProvided(tokenId, liquidity, amount0, amount1);

        require(amount0 >= minWstethAmount, "AMOUNT0_TOO_LITTLE");
        require(amount1 >= minWethAmount, "AMOUNT1_TOO_LITTLE");
        require(_deviationFromDesiredTick() <= MAX_TICK_DEVIATION, "TICK_DEVIATION_TOO_BIG_AFTER_SEEDING");
        require(LIDO_AGENT == NONFUNGIBLE_POSITION_MANAGER.ownerOf(tokenId));

        _refundLeftoversToLidoAgent();
    }

    function refundETH() external authAdminOrDao() {
        _refundETH();
    }

    /**
     * Transfers given amount of the ERC20-token to Lido agent
     *
     * @param _token an ERC20-compatible token
     * @param _amount amount of the token
     */
    function refundERC20(address _token, uint256 _amount) external authAdminOrDao() {
        _refundERC20(_token, _amount);
    }

    /**
     * Transfers a given token_id of an ERC721-compatible NFT to Lido agent
     *
     * @param _token an ERC721-compatible token
     * @param _tokenId minted token id
     */
    function refundERC721(address _token, uint256 _tokenId) external authAdminOrDao() {
        emit ERC721Refunded(msg.sender, _token, _tokenId);
        // Doesn't return bool as `transfer` for ERC20 does, because it performs 'require' check inside
        IERC721(_token).safeTransferFrom(address(this), LIDO_AGENT, _tokenId);
    }

    function _refundETH() internal {
        uint256 amount = address(this).balance;
        emit EthRefunded(msg.sender, amount);
        (bool success, ) = LIDO_AGENT.call{value: amount}("");
        require(success);
    }

    function _refundERC20(address _token, uint256 _amount) internal {
        emit ERC20Refunded(msg.sender, _token, _amount);
        TransferHelper.safeTransfer(_token, LIDO_AGENT, _amount);
    }

    /// Need to separate into a virtual function only for testing purposes
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

    function _getSpotPrice() internal view returns (uint256) {
        (uint160 sqrtRatioX96, , , , , , ) = POOL.slot0();
        return uint(sqrtRatioX96).mul(uint(sqrtRatioX96)).mul(1e18) >> (96 * 2);
    }

    /// returns desiredWstethAmount / desiredWethAmount
    function _calcDesiredTokensRatio(int24 _tick) internal view returns (uint256 wstEthOverWEthRatio) {
        int128 liquidity = 20e18;

        int256 amount0 = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtRatioAtTick(_tick),
            TickMath.getSqrtRatioAtTick(POSITION_UPPER_TICK),
            liquidity
        );
        int256 amount1 = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtRatioAtTick(POSITION_LOWER_TICK),
            TickMath.getSqrtRatioAtTick(_tick),
            liquidity
        );
        require(amount0 > 0);
        require(amount1 > 0);

        wstEthOverWEthRatio = uint256((amount0 * 1e18) / amount1);
    }

    function _calcDesiredTokenAmounts(int24 _tick, uint256 _ethAmount) internal view
        returns (uint256 amount0, uint256 amount1)
    {
        // weth_amount = eth_to_use / (1 + wsteth_to_weth_ratio * wsteth_token.stEthPerToken() / 1e18)
        // wsteth_amount = weth_amount * wsteth_to_weth_ratio

        uint256 wstEthOverWEthRatio = _calcDesiredTokensRatio(_tick);
        uint256 denom = 1e18 + (wstEthOverWEthRatio * IWstETH(TOKEN0).stEthPerToken()) / 1e18;
        amount1 = (_ethAmount * 1e18) / denom;
        amount0 = (amount1 * wstEthOverWEthRatio) / 1e18;
    }

    function _calcDesiredAndMinTokenAmounts() internal {
        (desiredWstethAmount, desiredWethAmount) = _calcDesiredTokenAmounts(desiredTick, ethAmount);

        (uint256 minWstethLower, uint256 minWethLower) =
            _calcDesiredTokenAmounts(desiredTick - int24(MAX_TICK_DEVIATION), ethAmount);
        (uint256 minWstethUpper, uint256 minWethUpper) =
            _calcDesiredTokenAmounts(desiredTick + int24(MAX_TICK_DEVIATION), ethAmount);

        minWstethAmount = minWstethUpper;
        minWethAmount = minWethLower;
    }

    function _getAmountOfEthForWsteth(uint256 _amountOfWsteth) internal view returns (uint256) {
        return (_amountOfWsteth * IWstETH(TOKEN0).stEthPerToken()) / 1e18;
    }

    function _wrapEthToTokens(uint256 _amount0, uint256 _amount1) internal {
        // Need to add 1 wei because the last point of stETH cannot be transferred
        // TODO: why for larger amounts of tokens we need more wei??
        uint256 ethForWsteth = 1000 + _getAmountOfEthForWsteth(_amount0);
        uint256 ethForWeth = _amount1;
        require(address(this).balance >= ethForWsteth + ethForWeth, "NOT_ENOUGH_ETH");

        (bool success, ) = TOKEN0.call{value: ethForWsteth}("");
        require(success, "WSTETH_MINTING_FAILED");
        IWETH(TOKEN1).deposit{value: ethForWeth}();
        require(IERC20(TOKEN0).balanceOf(address(this)) >= _amount0, "NOT_ENOUGH_WSTETH");
        require(IERC20(TOKEN1).balanceOf(address(this)) >= _amount1, "NOT_ENOUGH_WETH");
    }

    function _refundLeftoversToLidoAgent() internal {
        IWstETH(TOKEN0).unwrap(IERC20(TOKEN0).balanceOf(address(this)));
        _refundERC20(STETH_TOKEN, IERC20(STETH_TOKEN).balanceOf(address(this)));

        IWETH(TOKEN1).withdraw(IERC20(TOKEN1).balanceOf(address(this)));
        _refundETH();
    }

    function _deviationFromDesiredTick() internal view returns (uint24) {
        (, int24 currentTick, , , , , ) = POOL.slot0();

        return (currentTick > desiredTick)
            ? uint24(currentTick - desiredTick)
            : uint24(desiredTick - currentTick);
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

    function _emitEventWithCurrentLiquidityParameters() internal returns (uint256) {
        emit LiquidityParametersUpdated(
            ethAmount,
            desiredTick,
            MAX_TICK_DEVIATION,
            MIN_ALLOWED_DESIRED_TICK,
            MAX_ALLOWED_DESIRED_TICK,
            desiredWethAmount,
            desiredWstethAmount,
            minWstethAmount,
            minWethAmount
        );
    }

}
