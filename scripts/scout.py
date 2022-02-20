# from brownie import accounts, interface, contract
from brownie import *
from pprint import pprint

import sys
import os.path
sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import ETH_TO_SEED, formatE18, POOL, LIQUIDITY


deployer = accounts[0]

pool = interface.IUniswapV3Pool(POOL)

provider = TestUniV3LiquidityProvider.deploy({'from': deployer})


def print_stats():
    info = {}
    info['chainlink-based wsteth price'] = formatE18(provider.getChainlinkBasedWstethPrice())
    info['current price'] = formatE18(provider.getSpotPrice())
    info['current tick'] = provider.getCurrentPriceTick()
    info['in-range liquidity'] = formatE18(pool.liquidity())
    pprint(info)


def get_amounts_for_liquidity(liquidity):
    tx = provider.seed(liquidity)
    wstethAmount, wethAmount = tx.return_value
    return wstethAmount, wethAmount


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


def main():
    print_stats()

    calc_seeding_params(ETH_TO_SEED, LIQUIDITY)
    
    print_stats()


main()