from brownie import *
from pprint import pprint

import sys
import os.path
sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import *
from .utils import *


def main(deployer=None, skip_confirmation=False):
    if deployer is None:
        deployer = accounts[0]  # for dev environment
    
    print(f'DEPLOYER is {deployer}')
    
    provider_address = read_deploy_address()
    provider = UniV3LiquidityProvider.at(provider_address)

    print(
        f'Going to provide liquidity to Uni-v3 pool with the following parameters:\n'
        f'  min tick: {MIN_TICK}\n'
        f'  max tick: {MAX_TICK}\n'
        f'  eth to seed: {formatE18(provider.ETH_TO_SEED())}\n'
        f'  eth on the contract: {formatE18(provider.balance())}\n'
        f'  position lower tick: {provider.POSITION_LOWER_TICK()}\n'
        f'  position upper tick: {provider.POSITION_UPPER_TICK()}\n'
    )

    if not skip_confirmation:
        reply = input('Is this correct? (yes/no)\n')
        if reply != 'yes':
            print("Operator hasn't approved correctness of the parameters. Deployment stopped.")
            sys.exit(1)

    tx = provider.mint(MIN_TICK, MAX_TICK)
    token_id, liquidity, wsteth_amount, weth_amount = tx.return_value

    print(
        f'Liquidity provided:\n'
        f'  position token is: {token_id}\n'
        f'  amount of liquidity: {liquidity}\n'
        f'  wsteth amount: {formatE18(wsteth_amount)}\n'
        f'  weth amount: {formatE18(weth_amount)}\n'
    )

    return tx
    