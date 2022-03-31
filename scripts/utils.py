from brownie import Contract, interface
from math import floor, sqrt, log
from pprint import pprint
import os


def toE18(x):
    return round(x * 1e18)

def fromE18(x):
    return x / 1e18

def formatE18(num):
    floating_num = num / 1e18
    return f'{floating_num:.4f} ({floor(num)})'

def get_balance(address):
    return Contract.from_abi("Foo", address, "").balance()

def deviation_percent(value, base):
    return 100 * abs((value - base) / base)

def get_tick_from_price(price):
    return floor(log(sqrt(price), sqrt(1.0001)))

def get_price_from_tick(tick):
    return 1.0001**tick

def get_tick_positions_liquidity(pool, tick):
    (liquidity_gross, _, _, _, _, _, _, _) = pool.ticks(tick)
    return liquidity_gross

def print_provider_params(provider):
    pprint({
        'desiredWsteth': formatE18(provider.desiredWsteth()),
        'desiredWeth': formatE18(provider.desiredWeth()),
        'minWsteth': formatE18(provider.minWsteth()),
        'minWeth': formatE18(provider.minWeth()),
        'desiredTick': provider.desiredTick(),
    })

def print_mint_return_value(mint_return_value):
    token_id, liquidity, amount0, amount1 = mint_return_value
    pprint({
        'wsteth_used': formatE18(amount0),
        'weth_used': formatE18(amount1),
        'liquidity': formatE18(liquidity),
        'token_id': token_id,
    })

def get_deploy_address_path():
    return os.path.join(
        os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)),
        'deploy-address.txt'
    )

def write_deploy_address(address):
    with open(get_deploy_address_path(), 'w') as fp:
        fp.write(address)

def read_deploy_address():
    with open(get_deploy_address_path(), 'r') as fp:
        return fp.read()
