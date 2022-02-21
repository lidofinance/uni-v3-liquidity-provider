//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "../UniV3LiquidityProvider.sol";


contract TestUniV3LiquidityProvider is 
    IERC721Receiver,
    IUniswapV3MintCallback,
    UniV3LiquidityProvider
{

    function priceDeviationPoints(uint256 priceOne, uint256 priceTwo)
        public view returns (uint256 difference)
    {
        return _priceDeviationPoints(priceOne, priceTwo);
    }

    function deviationFromDesiredTick() external view returns (uint24) {
        return _deviationFromDesiredTick();
    }

    function getAmountOfEthForWsteth(uint256 _amountOfWsteth) external view returns (uint256) {
        return _getAmountOfEthForWsteth(_amountOfWsteth);
    }
    
    function getChainlinkBasedWstethPrice() external view returns (uint256) {
        return _getChainlinkBasedWstethPrice();
    }

    function getCurrentPriceTick() external view returns (int24) {
        (, int24 currentTick, , , , , ) = POOL.slot0();
        return currentTick;
    }

    function getSpotPrice() external view returns (uint256) {
        return _getSpotPrice();
    }

    function getPositionLiquidity() external view returns (uint128) {
        (uint128 liquidity, , , , ) = POOL.positions(POSITION_ID);
        return liquidity;
    }

    function getPositionTokenOwner(uint256 _tokenId) external view returns (address) {
        return NONFUNGIBLE_POSITION_MANAGER.ownerOf(_tokenId);
    }

    function refundLeftoversToLidoAgent() external {
        _refundLeftoversToLidoAgent();
    }

    function exchangeEthForTokens(uint256 amount0, uint256 amount1) external {
        _exchangeEthForTokens(amount0, amount1);
    }

    function calcTokenAmounts(uint128 _liquidity) external authAdminOrDao() returns (
        uint256 token0Seeded,
        uint256 token1Seeded
    ) {
        // require(_deviationFromDesiredTick() <= MAX_TICK_DEVIATION, "TICK_MOVEMENT_TOO_LARGE_AT_START");
        // require(_deviationFromChainlinkPricePoints() <= MAX_DIFF_TO_CHAINLINK_POINTS, "LARGE_DIFFERENCE_TO_CHAINLINK_PRICE_AT_START");

        (token0Seeded, token1Seeded) = POOL.mint(
            address(this),
            POSITION_LOWER_TICK,
            POSITION_UPPER_TICK,
            _liquidity,
            abi.encode(msg.sender) // Data field for uniswapV3MintCallback
        );

        // require(_deviationFromDesiredTick() <= MAX_TICK_DEVIATION, "TICK_MOVEMENT_TOO_LARGE");
        // require(_deviationFromChainlinkPricePoints() <= MAX_DIFF_TO_CHAINLINK_POINTS, "LARGE_DIFFERENCE_TO_CHAINLINK_PRICE");
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override
    {
        require(msg.sender == address(POOL));
        require(amount0Owed > 0, "AMOUNT0OWED_IS_ZERO");
        require(amount1Owed > 0, "AMOUNT1OWED_IS_ZERO");

        _exchangeEthForTokens(amount0Owed, amount1Owed);

        TransferHelper.safeTransfer(TOKEN0, address(POOL), amount0Owed);
        TransferHelper.safeTransfer(TOKEN1, address(POOL), amount1Owed);
    }
    

    /**
     * @dev We expect it not to be executed as Uniswap-v3 doesn't use safeTransferFrom
     * Will revert if called to alert.
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4)
    {
        require(false, "UNEXPECTED_POSITION_NFT");

        (, , address token0, address token1, , , , uint128 liquidity, , , , ) =
            NONFUNGIBLE_POSITION_MANAGER.positions(tokenId);
        
        return this.onERC721Received.selector;
    }

}
