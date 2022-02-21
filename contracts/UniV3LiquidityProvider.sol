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


contract UniV3LiquidityProvider {
    using LowGasSafeMath for uint256;

    address public admin;

    IUniswapV3Pool public constant POOL = IUniswapV3Pool(0xD340B57AAcDD10F96FC1CF10e15921936F41E29c);
    INonfungiblePositionManager public constant NONFUNGIBLE_POSITION_MANAGER =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    address public constant TOKEN0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH
    address public constant TOKEN1 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address public constant STETH_TOKEN = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant CHAINLINK_STETH_ETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address public constant LIDO_AGENT = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;

    uint256 public constant TOTAL_POINTS = 10000; // amount of points in 1000%

    int24 public constant POSITION_LOWER_TICK = -1630; // spot price 0.8496
    int24 public constant POSITION_UPPER_TICK = 970; // spot price 1.1019
    bytes32 public immutable POSITION_ID;


    /// The pool price tick we'd like not to be moved too far away from
    int24 public immutable DESIRED_TICK;

    uint256 public immutable MAX_DIFF_TO_CHAINLINK_POINTS;

    /// Corresponds to 0.5% price change from the price specified by DESIRED_TICK
    /// Note this value is a subject of logarithm based calculations, it is not just
    /// that "1" corresponds to 0.01% as it might seem
    uint24 public immutable MAX_TICK_DEVIATION;

    /// Desired amounts of tokens for providing liquidity to the pool
    uint256 public immutable WSTETH_DESIRED;
    uint256 public immutable WETH_DESIRED;

    /// Max deviation from desired amounts of tokens in points (percents)
    uint256 public immutable MAX_TOKEN_AMOUNT_CHANGE_POINTS;

    /// Min amounts of tokens for providing liquidity to the pool
    /// Calculated based on MAX_TOKEN_AMOUNT_CHANGE_POINTS
    uint256 public immutable WSTETH_MIN;
    uint256 public immutable WETH_MIN;

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


    modifier authAdminOrDao() {
        require(msg.sender == admin || msg.sender == LIDO_AGENT, "ONLY_ADMIN_OR_DAO_CAN");
        _;
    }

    constructor() {
        /// =======================================
        /// ========= PARAMETERS SECTION  =========
        /// =======================================
        DESIRED_TICK = 573; // corresponds to the price 1.0592
        uint256 wstethDesired = 4748629441952291158;
        uint256 wethDesired = 26688112256585525215;

        MAX_DIFF_TO_CHAINLINK_POINTS = 50; // 0.5%
        MAX_TICK_DEVIATION = 50; // almost corresponds to 0.5%
        uint256 maxTokenAmountChangePoints = 200; // 0.5%
        /// =======================================
        WSTETH_DESIRED = wstethDesired;
        WETH_DESIRED = wethDesired;
        MAX_TOKEN_AMOUNT_CHANGE_POINTS = maxTokenAmountChangePoints;
        /// =======================================

        admin = msg.sender;

        POSITION_ID = keccak256(abi.encodePacked(address(this), POSITION_LOWER_TICK, POSITION_UPPER_TICK));

        WSTETH_MIN = (wstethDesired * (TOTAL_POINTS - maxTokenAmountChangePoints)) / TOTAL_POINTS;
        WETH_MIN = (wethDesired * (TOTAL_POINTS - maxTokenAmountChangePoints)) / TOTAL_POINTS;
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
        (uint160 sqrtRatioX96, , , , , , ) = POOL.slot0();
        return uint(sqrtRatioX96).mul(uint(sqrtRatioX96)).mul(1e18) >> (96 * 2);
    }


    function _getAmountOfEthForWsteth(uint256 _amountOfWsteth) internal view returns (uint256) {
        return (_amountOfWsteth * WstETH(TOKEN0).stEthPerToken()) / 1e18;
    }


    function _exchangeEthForTokens(uint256 amount0, uint256 amount1) internal {
        // Need to add 1 wei because the last point of stETH cannot be transferred
        // TODO: why for larger amounts of tokens we need more wei??
        uint256 ethForWsteth = 1000 + _getAmountOfEthForWsteth(amount0);
        uint256 ethForWeth = amount1;
        require(address(this).balance >= ethForWsteth + ethForWeth, "NOT_ENOUGH_ETH");

        (bool success, ) = TOKEN0.call{value: ethForWsteth}("");
        require(success, "WSTETH_MINTING_FAILED");
        IWethToken(TOKEN1).deposit{value: ethForWeth}();
        require(IERC20(TOKEN0).balanceOf(address(this)) >= amount0, "NOT_ENOUGH_WSTETH");
        require(IERC20(TOKEN1).balanceOf(address(this)) >= amount1, "NOT_ENOUGH_WETH");
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
        require(_deviationFromChainlinkPricePoints() <= MAX_DIFF_TO_CHAINLINK_POINTS, "LARGE_DEVIATION_FROM_CHAINLINK_PRICE_AT_START");

        _exchangeEthForTokens(WSTETH_DESIRED, WETH_DESIRED);

        IERC20(TOKEN0).approve(address(NONFUNGIBLE_POSITION_MANAGER), WSTETH_DESIRED);
        IERC20(TOKEN1).approve(address(NONFUNGIBLE_POSITION_MANAGER), WETH_DESIRED);

        INonfungiblePositionManager.MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: TOKEN0,
                token1: TOKEN1,
                fee: POOL.fee(),
                tickLower: POSITION_LOWER_TICK,
                tickUpper: POSITION_UPPER_TICK,
                amount0Desired: WSTETH_DESIRED,
                amount1Desired: WETH_DESIRED,
                amount0Min: WSTETH_MIN,
                amount1Min: WETH_MIN,
                recipient: address(this),
                deadline: block.timestamp
            });

        // TODO: specify LIDO_AGENT as the recipient at once?
        (tokenId, liquidity, amount0, amount1) = NONFUNGIBLE_POSITION_MANAGER.mint(params);

        // check and transfer position NFT
        require(address(this) == NONFUNGIBLE_POSITION_MANAGER.ownerOf(tokenId));
        NONFUNGIBLE_POSITION_MANAGER.safeTransferFrom(address(this), LIDO_AGENT, tokenId);
        require(LIDO_AGENT == NONFUNGIBLE_POSITION_MANAGER.ownerOf(tokenId));

        _refundLeftoversToLidoAgent();
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


    function _withdrawERC20(address _token, uint256 _amount) internal {
        emit ERC20Withdrawn(msg.sender, _token, _amount);
        TransferHelper.safeTransfer(_token, LIDO_AGENT, _amount);
    }


    function _withdrawETH() internal {
        emit EthWithdrawn(msg.sender, address(this).balance);
        (bool success, ) = LIDO_AGENT.call{value: address(this).balance}("");
        require(success);
    }


    /**
        * Transfers given amount of the ERC20-token to Lido agent;
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
            // Doesn't return bool as `transfer` for ERC20 does, because it performs 'requrie' check inside
            IERC721(_token).safeTransferFrom(address(this), LIDO_AGENT, _tokenId);
    }

    function withdrawETH() external authAdminOrDao() {
        _withdrawETH();
    }

}
