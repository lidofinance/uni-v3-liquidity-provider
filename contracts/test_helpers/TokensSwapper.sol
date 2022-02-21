//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3SwapCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";


interface IWethToken is IERC20 {
    function deposit() external payable;
}


contract TokensSwapper is IUniswapV3SwapCallback {
    IUniswapV3Pool public constant POOL = IUniswapV3Pool(0xD340B57AAcDD10F96FC1CF10e15921936F41E29c);
    IWethToken public constant WETH_TOKEN = IWethToken(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // Set no limit to allow an arbitrary slippage
    function swapWsteth(int256 _amount) external {
        uint160 sqrtPriceLimitX96 = 0;

        POOL.swap(
            msg.sender,
            true, // true for token0 to token1
            _amount,
            sqrtPriceLimitX96,
            abi.encode(msg.sender)
        );
    }

    function swapWeth() external payable {
        uint256 amount = msg.value;
        bool zeroForOne = false;

        // Set no limit to allow an arbitrary slippage
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;

        require(address(this).balance >= amount);

        WETH_TOKEN.deposit{value: amount}();
        require(WETH_TOKEN.balanceOf(address(this)) >= amount);

        // WETH_TOKEN.approve(address(POOL), amount);

        (int256 amount0Delta, int256 amount1Delta) = POOL.swap(
            address(this), // msg.sender,
            zeroForOne,
            int256(amount),
            sqrtPriceLimitX96,
            abi.encode(msg.sender)
        );
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override
    {
        require(msg.sender == address(POOL));
        require(amount0Delta <= 0, "FFF");

        // if (amount0Delta > 0) {
        //   WSTETH_TOKEN.transfer(address(POOL), uint256(amount0Delta));
        // }
        // } else
        if (amount1Delta > 0) {
            WETH_TOKEN.transfer(address(POOL), uint256(amount1Delta));
        }
    }
}