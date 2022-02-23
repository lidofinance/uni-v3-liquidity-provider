from brownie import *
from pprint import pprint

import sys
import os.path
sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import *
from .utils import get_diff_in_percent, toE18, formatE18


deployer = accounts[0]

pool = interface.IUniswapV3Pool(POOL)
wsteth_token = interface.WSTETH(WSTETH_TOKEN)

provider = TestUniV3LiquidityProvider.deploy(
    ETH_TO_SEED,
    DESIRED_TICK,
    MAX_TICK_DEVIATION,
    MAX_ALLOWED_DESIRED_TICK_CHANGE,
    {'from': deployer})

swapper = TokensSwapper.deploy({'from': deployer})


def print_stats():
    info = {}
    info['chainlink-based wsteth price'] = formatE18(provider.getChainlinkBasedWstethPrice())
    info['current price'] = formatE18(provider.getSpotPrice())
    info['current tick'] = provider.getCurrentPriceTick()
    info['in-range liquidity'] = formatE18(pool.liquidity())

    # TODO: calc total pool liquidity / info about existing positions

    diff_from_chainlink = get_diff_in_percent(provider.getSpotPrice(), provider.getChainlinkBasedWstethPrice())
    info['diff from chainlink price'] = f'{diff_from_chainlink:.2}%'
    pprint(info)


def get_amounts_for_liquidity(liquidity):
    tx = provider.calcTokenAmounts(liquidity)
    wstethAmount, wethAmount = tx.return_value
    return wstethAmount, wethAmount


def calc_token_amounts(eth_to_use):
    deployer.transfer(provider.address, toE18(300))

    wsteth_example_amount, weth_example_amount = get_amounts_for_liquidity(toE18(50))
    print((wsteth_example_amount, weth_example_amount))

    wsteth_to_weth_ratio = wsteth_example_amount / weth_example_amount
    print(wsteth_to_weth_ratio)

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


def dev():
    print_stats()

    shift_spot_price(toE18(75))

    print_stats()


def main_swap_wsteth():
    swapper.swapWsteth({'from': deployer, 'value': toE18(10.4)})

    wsteth_amount, weth_amount = calc_token_amounts(ETH_TO_SEED - provider.ETH_AMOUNT_MARGIN())

    eth_used = wsteth_amount * wsteth_token.stEthPerToken() / 1e18  + weth_amount

    print_stats()
    pprint({
        'input eth': formatE18(ETH_TO_SEED),
        'wsteth_amount': formatE18(wsteth_amount),
        'weth_amount': formatE18(weth_amount),
        'wsteth/weth ratio': wsteth_amount / weth_amount,
        'eth_used': formatE18(eth_used),
    })


def main_swap_weth():
    swapper.swapWeth({'from': deployer, 'value': toE18(75)})

    wsteth_amount, weth_amount = calc_token_amounts(ETH_TO_SEED - provider.ETH_AMOUNT_MARGIN())

    eth_used = wsteth_amount * wsteth_token.stEthPerToken() / 1e18  + weth_amount

    print_stats()
    pprint({
        'input eth': formatE18(ETH_TO_SEED),
        'wsteth_amount': formatE18(wsteth_amount),
        'weth_amount': formatE18(weth_amount),
        'wsteth/weth ratio': wsteth_amount / weth_amount,
        'eth_used': formatE18(eth_used),
    })


def main():
    wsteth_amount, weth_amount = calc_token_amounts(ETH_TO_SEED - provider.ETH_AMOUNT_MARGIN())

    eth_used = wsteth_amount * wsteth_token.stEthPerToken() / 1e18  + weth_amount

    print_stats()
    pprint({
        'input eth': formatE18(ETH_TO_SEED),
        'wsteth_amount': formatE18(wsteth_amount),
        'weth_amount': formatE18(weth_amount),
        'wsteth/weth ratio': wsteth_amount / weth_amount,
        'eth_used': formatE18(eth_used),
    })