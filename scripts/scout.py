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
    INITIAL_DESIRED_TICK,
    MAX_TICK_DEVIATION,
    MAX_ALLOWED_DESIRED_TICK_CHANGE,
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
        f'  abs deviation from chainlink price = {diff_from_chainlink:.2}%\n'
    )

    # TODO: ? print some info about existing positions


def get_amounts_for_liquidity(liquidity):
    tx = provider.calcTokenAmountsByPool(liquidity)
    wstethAmount, wethAmount = tx.return_value
    return wstethAmount, wethAmount


def calc_token_amounts(eth_to_use):
    deployer.transfer(provider.address, toE18(300))

    wsteth_example_amount, weth_example_amount = get_amounts_for_liquidity(toE18(50))
    # print((wsteth_example_amount, weth_example_amount))

    wsteth_to_weth_ratio = wsteth_example_amount / weth_example_amount
    # print(wsteth_to_weth_ratio)

    weth_amount = eth_to_use / (1 + wsteth_to_weth_ratio * wsteth_token.stEthPerToken() / 1e18)
    wsteth_amount = weth_amount * wsteth_to_weth_ratio

    return wsteth_amount, weth_amount


def shift_spot_price(eth_amount):
    weth_to_swap = eth_amount
    swapper.swapWeth({'from': deployer, 'value': weth_to_swap})


def calc_seeding_params(eth_amount, liquidity):
    print({'provider balance': formatE18(provider.balance())})
    deployer.transfer(provider.address, eth_amount)

    print({'provider balance': formatE18(provider.balance())})

    wsteth_amount, weth_amount = get_amounts_for_liquidity(liquidity)

    print({'provider balance': formatE18(provider.balance())})

    eth_used_percent = 100 * (eth_amount - provider.balance()) / eth_amount
    pprint({
        'wsteth amount': formatE18(wsteth_amount),
        'weth amount': formatE18(weth_amount),
        'eth left': formatE18(provider.balance()),
        'eth used': f'{eth_used_percent:.1f}%',
        'weth/wsteth ratio': f'{weth_amount / wsteth_amount:.3f}'
    })


def print_amounts_calculated_by_pool():
    wsteth_amount, weth_amount = calc_token_amounts(ETH_TO_SEED - provider.ETH_AMOUNT_MARGIN())

    eth_used = wsteth_amount * wsteth_token.stEthPerToken() / 1e18  + weth_amount

    pprint({
        'input eth': formatE18(ETH_TO_SEED),
        'wsteth_amount': formatE18(wsteth_amount),
        'weth_amount': formatE18(weth_amount),
        'wsteth/weth ratio': wsteth_amount / weth_amount,
        'eth_used (approx)': formatE18(eth_used),
    })


def main():
    print_stats()
