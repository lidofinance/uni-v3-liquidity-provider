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

    desired_tick = MINT_DESIRED_TICK

    print(
        f'Going to provide liquidity to Uni-v3 pool with the following parameters:\n'
        f'  old desired tick: {provider.desiredTick()}\n'
        f'  new desired tick: {desired_tick}\n'
        f'  max tick deviation: {provider.MAX_TICK_DEVIATION()}\n'
        f'  eth to seed: {provider.ethAmount()}\n'
        f'  eth on the contract: {formatE18(provider.balance())}\n'
    )

    if not skip_confirmation:
        reply = input('Is this correct? (yes/no)\n')
        if reply != 'yes':
            print("Operator hasn't approved correctness of the parameters. Deployment stopped.")
            sys.exit(1)

    tx = provider.mint(desired_tick)
    token_id, liquidity, wsteth_amount, weth_amount = tx.return_value

    print(
        f'Liquidity provided:\n'
        f'  position token is: {token_id}\n'
        f'  amount of liquidity: {liquidity}\n'
        f'  wsteth amount: {wsteth_amount}\n'
        f'  weth amount: {weth_amount}\n'
    )

    return tx
    