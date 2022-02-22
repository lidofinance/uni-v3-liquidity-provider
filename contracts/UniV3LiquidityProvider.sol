//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { LowGasSafeMath } from "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import { TransferHelper } from "@uniswap/v3-core/contracts/libraries/TransferHelper.sol";

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

    address public admin;

    /// WstETH/Weth Uniswap V3 pool
    IUniswapV3Pool public constant POOL = IUniswapV3Pool(0xD340B57AAcDD10F96FC1CF10e15921936F41E29c);

    /// Uniswap V3 contract for seeding liquidity minting position NFT for any pool
    INonfungiblePositionManager public constant NONFUNGIBLE_POSITION_MANAGER =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    address public constant TOKEN0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH
    address public constant TOKEN1 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address public constant STETH_TOKEN = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant CHAINLINK_STETH_ETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address public constant LIDO_AGENT = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;

    uint256 public constant TOTAL_POINTS = 10000; // amount of points in 100%

    int24 public constant POSITION_LOWER_TICK = -1630; // spot price 0.8496
    int24 public constant POSITION_UPPER_TICK = 970; // spot price 1.1019
    bytes32 public immutable POSITION_ID;


    /// The pool price tick we'd like not to be moved too far away from
    int24 public immutable DESIRED_TICK;

    /// Max deviation from chainlink-based price % (expressed in points)
    uint256 public immutable MAX_DEVIATION_FROM_CHAINLINK_POINTS;

    /// Note this value is a subject of logarithm based calculations, it is not just
    /// that "1" corresponds to 0.01% as it might seem. But might be very close at current price
    uint24 public immutable MAX_TICK_DEVIATION;

    /// Desired amounts of tokens for providing liquidity to the pool
    uint256 public immutable DESIRED_WSTETH;
    uint256 public immutable DESIRED_WETH;

    /// Max deviation from desired amounts of tokens in points (percents)
    uint256 public immutable MAX_TOKEN_AMOUNT_CHANGE_POINTS;

    /// Min amounts of tokens for providing liquidity to the pool
    /// Calculated based on MAX_TOKEN_AMOUNT_CHANGE_POINTS
    uint256 public immutable WSTETH_MIN;
    uint256 public immutable WETH_MIN;

    /// Emitted when liquidity provided to UniswapV3 pool and
    /// liquidity position NFT is minted
    event LiquidityProvided(
        uint256 tokenId,
        uint128 liquidity,
        uint256 wstethAmount,
        uint256 wethAmount
    );

    /// Emitted when ETH is withdrawn to Lido agent contract
    event EthWithdrawn(address requestedBy, uint256 amount);

    /**
     * Emitted when the ERC20 `token` withdrawn
     * to the Lido agent address by `requestedBy` sender.
     */
    event ERC20Withdrawn(
        address indexed requestedBy,
        address indexed token,
        uint256 amount
    );

    /**
     * Emitted when the ERC721-compatible `token` (NFT) withdrawn
     * to the Lido treasure address by `requestedBy` sender.
     */
    event ERC721Withdrawn(
        address indexed requestedBy,
        address indexed token,
        uint256 tokenId
    );

    event AdminSet(address admin);

    constructor(
        int24 desiredTick,
        uint256 desiredWsteth,
        uint256 desiredWeth,
        uint256 maxDeviationFromChainlinkPricePoints,
        uint24 maxTickDeviation,
        uint256 maxTokenAmountChangePoints
    ) {
        admin = msg.sender;

        POSITION_ID = keccak256(abi.encodePacked(address(this), POSITION_LOWER_TICK, POSITION_UPPER_TICK));

        DESIRED_TICK = desiredTick;
        MAX_DEVIATION_FROM_CHAINLINK_POINTS = maxDeviationFromChainlinkPricePoints;
        MAX_TOKEN_AMOUNT_CHANGE_POINTS = maxTokenAmountChangePoints;
        MAX_TICK_DEVIATION = maxTickDeviation;
        DESIRED_WSTETH = desiredWsteth;
        DESIRED_WETH = desiredWeth;

        WSTETH_MIN = (desiredWsteth * (TOTAL_POINTS - maxTokenAmountChangePoints)) / TOTAL_POINTS;
        WETH_MIN = (desiredWeth * (TOTAL_POINTS - maxTokenAmountChangePoints)) / TOTAL_POINTS;
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

    function mint() external returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) {
        require(_deviationFromChainlinkPricePoints() <= MAX_DEVIATION_FROM_CHAINLINK_POINTS,
            "LARGE_DEVIATION_FROM_CHAINLINK_PRICE_AT_START");
        require(_deviationFromDesiredTick() <= MAX_TICK_DEVIATION, "TICK_DEVIATION_TOO_MUCH_AT_START");

        _exchangeEthForTokens(DESIRED_WSTETH, DESIRED_WETH);

        IERC20(TOKEN0).approve(address(NONFUNGIBLE_POSITION_MANAGER), DESIRED_WSTETH);
        IERC20(TOKEN1).approve(address(NONFUNGIBLE_POSITION_MANAGER), DESIRED_WETH);

        INonfungiblePositionManager.MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: TOKEN0,
                token1: TOKEN1,
                fee: POOL.fee(),
                tickLower: POSITION_LOWER_TICK,
                tickUpper: POSITION_UPPER_TICK,
                amount0Desired: DESIRED_WSTETH,
                amount1Desired: DESIRED_WETH,
                amount0Min: WSTETH_MIN,
                amount1Min: WETH_MIN,
                recipient: LIDO_AGENT,
                deadline: block.timestamp
            });

        (tokenId, liquidity, amount0, amount1) = NONFUNGIBLE_POSITION_MANAGER.mint(params);

        emit LiquidityProvided(tokenId, liquidity, amount0, amount1);

        require(amount0 >= WSTETH_MIN, "AMOUNT0_TOO_LITTLE");
        require(amount1 >= WETH_MIN, "AMOUNT1_TOO_LITTLE");
        require(LIDO_AGENT == NONFUNGIBLE_POSITION_MANAGER.ownerOf(tokenId));

        _refundLeftoversToLidoAgent();
    }

    /**
     * Transfers given amount of the ERC20-token to Lido agent
     *
     * @param _token an ERC20-compatible token
     * @param _amount amount of the token
     */
    function withdrawERC20(address _token, uint256 _amount) external authAdminOrDao() {
        _withdrawERC20(_token, _amount);
    }

    /**
     * Transfers a given token_id of an ERC721-compatible NFT to Lido agent
     *
     * @param _token an ERC721-compatible token
     * @param _tokenId minted token id
     */
    function withdrawERC721(address _token, uint256 _tokenId) external authAdminOrDao() {
        emit ERC721Withdrawn(msg.sender, _token, _tokenId);
        // Doesn't return bool as `transfer` for ERC20 does, because it performs 'require' check inside
        IERC721(_token).safeTransferFrom(address(this), LIDO_AGENT, _tokenId);
    }

    function withdrawETH() external authAdminOrDao() {
        _withdrawETH();
    }

    function _withdrawERC20(address _token, uint256 _amount) internal {
        emit ERC20Withdrawn(msg.sender, _token, _amount);
        TransferHelper.safeTransfer(_token, LIDO_AGENT, _amount);
    }

    function _withdrawETH() internal {
        emit EthWithdrawn(msg.sender, address(this).balance);
        (bool success, ) = LIDO_AGENT.call{value: address(this).balance}("");
        require(success);
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

    function _getAmountOfEthForWsteth(uint256 _amountOfWsteth) internal view returns (uint256) {
        return (_amountOfWsteth * IWstETH(TOKEN0).stEthPerToken()) / 1e18;
    }

    function _exchangeEthForTokens(uint256 amount0, uint256 amount1) internal {
        // Need to add 1 wei because the last point of stETH cannot be transferred
        // TODO: why for larger amounts of tokens we need more wei??
        uint256 ethForWsteth = 1000 + _getAmountOfEthForWsteth(amount0);
        uint256 ethForWeth = amount1;
        require(address(this).balance >= ethForWsteth + ethForWeth, "NOT_ENOUGH_ETH");

        (bool success, ) = TOKEN0.call{value: ethForWsteth}("");
        require(success, "WSTETH_MINTING_FAILED");
        IWETH(TOKEN1).deposit{value: ethForWeth}();
        require(IERC20(TOKEN0).balanceOf(address(this)) >= amount0, "NOT_ENOUGH_WSTETH");
        require(IERC20(TOKEN1).balanceOf(address(this)) >= amount1, "NOT_ENOUGH_WETH");
    }

    function _refundLeftoversToLidoAgent() internal {
        IWstETH(TOKEN0).unwrap(IERC20(TOKEN0).balanceOf(address(this)));
        _withdrawERC20(STETH_TOKEN, IERC20(STETH_TOKEN).balanceOf(address(this)));

        IWETH(TOKEN1).withdraw(IERC20(TOKEN1).balanceOf(address(this)));

        _withdrawETH();
    }

    function _deviationFromDesiredTick() internal view returns (uint24) {
        (, int24 currentTick, , , , , ) = POOL.slot0();

        return (currentTick > DESIRED_TICK)
            ? uint24(currentTick - DESIRED_TICK)
            : uint24(DESIRED_TICK - currentTick);
    }

    function _priceDeviationPoints(uint256 basePrice, uint256 price)
        internal view returns (uint256 difference)
    {
        require(basePrice > 0, "ZERO_BASE_PRICE");

        uint256 absDiff = basePrice > price
            ? basePrice - price
            : price - basePrice;

        return (absDiff * TOTAL_POINTS) / basePrice;
    }

    function _deviationFromChainlinkPricePoints() internal view returns (uint256) {
        return _priceDeviationPoints(_getChainlinkBasedWstethPrice(), _getSpotPrice());
    }

}
