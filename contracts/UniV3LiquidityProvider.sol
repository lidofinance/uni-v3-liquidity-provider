//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { LowGasSafeMath } from "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import { TransferHelper } from "@uniswap/v3-core/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-core/contracts/libraries/SqrtPriceMath.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import { INonfungiblePositionManager } from '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface IWETH {
    function deposit() external payable;
    function withdraw(uint wad) external;
}


interface IWstETH {
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _stETHAmount) external returns (uint256);
    function stEthPerToken() external view returns (uint256);
    function getStETHByWstETH(uint256 _wstETHAmount) external view returns (uint256);
}

// NB: Considerations about math precision
// To reduce the impact of rounding errors we use "Ray Math" taken from AAVE protocol
// A Ray is a unit with 27 decimals of precision.
// Variables storing values with 27 digits of precision are named with suffix "E27"

contract UniV3LiquidityProvider {
    using LowGasSafeMath for uint256;

    /// WstETH/Weth Uniswap V3 pool
    IUniswapV3Pool public constant POOL = IUniswapV3Pool(0xD340B57AAcDD10F96FC1CF10e15921936F41E29c);

    /// Uniswap V3 contract for seeding liquidity minting position NFT for any pool
    INonfungiblePositionManager public constant NONFUNGIBLE_POSITION_MANAGER =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    address public constant WSTETH_TOKEN = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH
    address public constant WETH_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH

    address public constant STETH_TOKEN = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant LIDO_AGENT = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;

    uint256 public constant ONE_E27 = 1e27;

    int24 public immutable POSITION_LOWER_TICK;
    int24 public immutable POSITION_UPPER_TICK;
    bytes32 public immutable POSITION_ID;

    /// Tick range which bounds tick range specified in mint()
    int24 public immutable MIN_ALLOWED_TICK;
    int24 public immutable MAX_ALLOWED_TICK;

    /// Amount of ETH to use to provide liquidity
    uint256 public immutable ETH_TO_SEED;

    /// Contract admin
    address public admin;

    /// Emitted when ETH is received by the contract
    event EthReceived(
        uint256 amount
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

    /// Emitted when the ERC20 `token` refunded
    /// to the Lido agent address by `requestedBy` sender.
    event ERC20Refunded(
        address indexed requestedBy,
        address indexed token,
        uint256 amount
    );

    /// Emitted when the ERC721-compatible `token` (NFT) refunded
    /// to the Lido treasure address by `requestedBy` sender.
    event ERC721Refunded(
        address indexed requestedBy,
        address indexed token,
        uint256 tokenId
    );

    /// Emitted when new admin is set
    event AdminSet(address indexed admin);

    /**
     * @param _ethAmount Amount of Ether on the contract used for providing liquidity
     * @param _minAllowedTick Min pool tick for which liquidity is allowed to be provided
     * @param _maxAllowedTick Max pool tick for which liquidity is allowed to be provided
     */
    constructor(
        uint256 _ethAmount,
        int24 _positionLowerTick,
        int24 _positionUpperTick,
        int24 _minAllowedTick,
        int24 _maxAllowedTick
    ) {
        require(_positionLowerTick < _positionUpperTick);
        require(_minAllowedTick < _maxAllowedTick);
        require(_minAllowedTick >= _positionLowerTick);
        require(_maxAllowedTick <= _positionUpperTick);

        admin = msg.sender;

        ETH_TO_SEED = _ethAmount;

        POSITION_LOWER_TICK = _positionLowerTick;
        POSITION_UPPER_TICK = _positionUpperTick;
        POSITION_ID = keccak256(abi.encodePacked(address(NONFUNGIBLE_POSITION_MANAGER), _positionLowerTick, _positionUpperTick));

        MIN_ALLOWED_TICK = _minAllowedTick;
        MAX_ALLOWED_TICK = _maxAllowedTick;
    }

    receive() external payable {
        emit EthReceived(msg.value);
    }

    modifier authAdminOrDao() {
        require(msg.sender == admin || msg.sender == LIDO_AGENT, "AUTH_ADMIN_OR_LIDO_AGENT");
        _;
    }

    function setAdmin(address _admin) external authAdminOrDao() {
        emit AdminSet(_admin);
        admin = _admin;
    }

    /**
     * Update desired tick and provide liquidity to the pool
     * 
     * @param _minTick Min pool tick for which liquidity is to be provided
     * @param _maxTick Max pool tick for which liquidity is to be provided
     */
    function mint(int24 _minTick, int24 _maxTick) external authAdminOrDao() returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 wstethAmount,
        uint256 wethAmount
    ) {
        require(_minTick >= MIN_ALLOWED_TICK && _maxTick <= MAX_ALLOWED_TICK,
            'DESIRED_MIN_OR_MAX_TICK_IS_OUT_OF_ALLOWED_RANGE');

        (, int24 tick, , , , , ) = POOL.slot0();
        require(_minTick <= tick && tick <= _maxTick, "TICK_DEVIATION_TOO_BIG_AT_START");

        (uint256 desWsteth, uint256 desWeth) = _calcTokenAmountsFromCurrentPoolSqrtPrice(ETH_TO_SEED);

        _wrapEthToTokens(desWsteth, desWeth);

        (uint256 minWsteth, uint256 minWeth) = _calcMinTokenAmounts(_minTick, _maxTick);

        IERC20(WSTETH_TOKEN).approve(address(NONFUNGIBLE_POSITION_MANAGER), desWsteth);
        IERC20(WETH_TOKEN).approve(address(NONFUNGIBLE_POSITION_MANAGER), desWeth);

        INonfungiblePositionManager.MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: WSTETH_TOKEN,
                token1: WETH_TOKEN,
                fee: POOL.fee(),
                tickLower: POSITION_LOWER_TICK,
                tickUpper: POSITION_UPPER_TICK,
                amount0Desired: desWsteth,
                amount1Desired: desWeth,
                amount0Min: minWsteth,
                amount1Min: minWeth,
                recipient: LIDO_AGENT,
                deadline: block.timestamp
            });
        (tokenId, liquidity, wstethAmount, wethAmount) = NONFUNGIBLE_POSITION_MANAGER.mint(params);

        require(LIDO_AGENT == NONFUNGIBLE_POSITION_MANAGER.ownerOf(tokenId));
        require(wstethAmount >= minWsteth, "WSTETH_AMOUNT_TOO_LITTLE");
        require(wethAmount >= minWeth, "WETH_AMOUNT_TOO_LITTLE");

        (, tick, , , , , ) = POOL.slot0();
        require(_minTick <= tick && tick <= _maxTick, "TICK_DEVIATION_TOO_BIG_AFTER_MINT");

        IERC20(WSTETH_TOKEN).approve(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(WETH_TOKEN).approve(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        emit LiquidityProvided(tokenId, liquidity, wstethAmount, wethAmount);

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
        if (amount > 0) {
            emit EthRefunded(msg.sender, amount);
            (bool success, ) = LIDO_AGENT.call{value: amount}("");
            require(success);
        }
    }

    function _refundERC20(address _token, uint256 _amount) internal {
        emit ERC20Refunded(msg.sender, _token, _amount);
        TransferHelper.safeTransfer(_token, LIDO_AGENT, _amount);
    }

    /**
     * Calc needed token ratio at given price tick for the liquidity position
     *
     * @param _tick Price tick
     * @return wstEthOverWEthRatio (wstethAmount / wethAmount)
     */
    function _calcTokensRatio(int24 _tick) internal view returns (uint256 wstEthOverWEthRatio) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_tick);
        return _calcTokensRatioFromSqrtPrice(sqrtPriceX96);
    }

    function _calcTokensRatioFromSqrtPrice(uint160 _sqrtPriceX96) internal view
        returns (uint256 wstEthOverWEthRatioE27)
    {
        // We care only of ratio of tokens here, so the exact amount of liquidity isn't important
        // But the amount must be large enough to provide sufficient precision
        int128 liquidity = 1e27;  

        int256 wstethAmountE27 = SqrtPriceMath.getAmount0Delta(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(POSITION_UPPER_TICK),
            liquidity
        );
        int256 wethAmountE27 = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtRatioAtTick(POSITION_LOWER_TICK),
            _sqrtPriceX96,
            liquidity
        );
        require(wstethAmountE27 > 0);
        require(wethAmountE27 > 0);

        wstEthOverWEthRatioE27 = uint256((wstethAmountE27 * 1e27) / wethAmountE27);
    }

    function _mulE27(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a * _b) / ONE_E27;
    }

    function _divE27(uint256 _nominator, uint256 _denominator) internal pure returns (uint256) {
        return (_nominator * ONE_E27) / _denominator;
    }

    /**
     * Calc token amounts from wsteth/weth ratio
     *
     * @param _ratioE27 wsteth/weth target ratio with e27 precision
     * @param _ethAmount eth amount to use
     * @return wstethAmount Amounts of wsteth
     * @return wethAmount Amount of weth
     */
    function _calcTokenAmountsFromRatio(uint256 _ratioE27, uint256 _ethAmount) internal view
        returns (uint256 wstethAmount, uint256 wethAmount)
    {
        // The system from which the formulas derived:
        //   ratio = wsteth / weth
        //   eth = stEthPerToken * wsteth + weth
        //
        // The formulas used for calculation
        //   weth = eth / (ratio * stEthPerToken + 1)
        //   wsteth = ratio * weth

        uint256 wstethPriceE27 = _getAmountOfEthForWsteth(ONE_E27);

        uint256 denominatorE27 = ONE_E27 + _mulE27(_ratioE27, wstethPriceE27);

        uint256 wethAmountE27 = _divE27(_ethAmount * 1e9, denominatorE27);

        wstethAmount = _mulE27(wethAmountE27, _ratioE27) / 1e9;
        wethAmount = wethAmountE27 / 1e9;
    }

    function _calcTokenAmountsFromCurrentPoolSqrtPrice(uint256 _ethAmount) internal view
        returns (uint256 wstethAmount, uint256 wethAmount)
    {
        (uint160 sqrtRatioX96, , , , , , ) = POOL.slot0(); 
        uint256 ratio = _calcTokensRatioFromSqrtPrice(sqrtRatioX96);
        return _calcTokenAmountsFromRatio(ratio, _ethAmount);
    }

    function _calcTokenAmounts(int24 _tick, uint256 _ethAmount) internal view
        returns (uint256 wstethAmount, uint256 wethAmount)
    {
        uint256 ratio = _calcTokensRatio(_tick);
        return _calcTokenAmountsFromRatio(ratio, _ethAmount);
    }

    function _calcMinTokenAmounts(int24 _minTick, int24 _maxTick) internal view
        returns (
            uint256 minWsteth,
            uint256 minWeth
    ) {
        int24 minTick = _minTick - 1;
        int24 maxTick = _maxTick + 1;
        (uint256 wstethForMinTick, uint256 wethForMinTick) = _calcTokenAmounts(minTick, ETH_TO_SEED);
        (uint256 wstethForMaxTick, uint256 wethForMaxTick) = _calcTokenAmounts(maxTick, ETH_TO_SEED);

        minWsteth = wstethForMaxTick;
        minWeth = wethForMinTick;
    }

    function _getAmountOfEthForWsteth(uint256 _amountOfWsteth) internal view returns (uint256) {
        return IWstETH(WSTETH_TOKEN).getStETHByWstETH(_amountOfWsteth) + 1;
    }

    function _wrapEthToTokens(uint256 _wstethAmount, uint256 _wethAmount) internal {
        uint256 ethForWsteth = _getAmountOfEthForWsteth(_wstethAmount);
        uint256 ethForWeth = _wethAmount;
        require(address(this).balance >= ethForWsteth + ethForWeth, "NOT_ENOUGH_ETH");

        (bool success, ) = WSTETH_TOKEN.call{value: ethForWsteth}("");
        require(success, "WSTETH_MINTING_FAILED");

        IWETH(WETH_TOKEN).deposit{value: ethForWeth}();

        require(IERC20(WSTETH_TOKEN).balanceOf(address(this)) >= _wstethAmount, "NOT_ENOUGH_WSTETH");
        require(IERC20(WETH_TOKEN).balanceOf(address(this)) >= _wethAmount, "NOT_ENOUGH_WETH");
    }

    function _refundLeftoversToLidoAgent() internal {
        uint256 wstethAmount = IERC20(WSTETH_TOKEN).balanceOf(address(this));
        if (wstethAmount > 0) {
            IWstETH(WSTETH_TOKEN).unwrap(wstethAmount);
        }

        _refundERC20(STETH_TOKEN, IERC20(STETH_TOKEN).balanceOf(address(this)));

        uint256 wethAmount = IERC20(WETH_TOKEN).balanceOf(address(this));
        if (wethAmount > 0) {
            IWETH(WETH_TOKEN).withdraw(wethAmount);
        }

        _refundETH();
    }
}
