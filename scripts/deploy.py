from brownie import *
from pprint import pprint

import sys
import os.path
sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import *
from .utils import *


def main(deployer=None):
    if deployer is None:
        deployer == accounts[0]  # for dev environment
    
    pprint({
        'deployer': deployer,
    })

    provider = UniV3LiquidityProvider.deploy(
        ETH_TO_SEED,
        INITIAL_DESIRED_TICK,
        MAX_TICK_DEVIATION,
        MAX_ALLOWED_DESIRED_TICK_CHANGE,
        {'from': deployer})
    
    write_deploy_address(provider.address)