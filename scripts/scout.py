from brownie import *
from pprint import pprint

import sys
import os.path
sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import *
from .utils import deviation_percent, toE18, formatE18


deployer = accounts[0]

pool = interface.IUniswapV3Pool(POOL)
wsteth_token = interface.WSTETH(WSTETH_TOKEN)
weth_token = interface.WSTETH(WETH_TOKEN)

provider = TestUniV3LiquidityProvider.deploy(
    ETH_TO_SEED,
    POSITION_LOWER_TICK,
    POSITION_UPPER_TICK,
    MIN_ALLOWED_TICK,
    MAX_ALLOWED_TICK,
    {'from': deployer})

swapper = TokensSwapper.deploy({'from': deployer})


def print_stats():
    diff_from_chainlink = deviation_percent(provider.getSpotPrice(), provider.getChainlinkBasedWstethPrice())
    total_wsteth_in_pool = wsteth_token.balanceOf(POOL)
    total_weth_in_pool = weth_token.balanceOf(POOL)

    print(
        f'Current state:\n'
        f'  total wsteth / weth in pool = {formatE18(total_wsteth_in_pool)} / {formatE18(total_weth_in_pool)}\n'
        f'  current pool tick = {provider.getCurrentPriceTick()}\n'
        f'  current pool price = {formatE18(provider.getSpotPrice())}\n'
        f'  chainlink-based wsteth price = {formatE18(provider.getChainlinkBasedWstethPrice())}\n'
        f'  pool price abs deviation from chainlink-based price = {diff_from_chainlink:.2}%\n'
    )

    # TODO: ? print some info about existing positions


def main():
    print_stats()
