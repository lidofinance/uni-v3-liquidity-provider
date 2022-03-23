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
    tx = provider.mint(desired_tick)
    token_id, liquidity, wsteth_amount, weth_amount = tx.return_value

    # TODO: Show parameters of event LiquidityProvided

    return tx
    