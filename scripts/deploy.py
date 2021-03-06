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

    print(
        f'Going to deploy with the following parameters:\n'
        f'  ETH_TO_SEED: {formatE18(ETH_TO_SEED)}\n'
        f'  INITIAL_DESIRED_TICK: {INITIAL_DESIRED_TICK}\n'
        f'  MAX_TICK_DEVIATION: {MAX_TICK_DEVIATION}\n'
        f'  MAX_ALLOWED_DESIRED_TICK_CHANGE: {MAX_ALLOWED_DESIRED_TICK_CHANGE}\n'
    )

    if not skip_confirmation:
        reply = input('Are they correct? (yes/no)\n')
        if reply != 'yes':
            print("Operator hasn't approved correctness of the parameters. Deployment stopped.")
            sys.exit(1)

    provider = UniV3LiquidityProvider.deploy(
        ETH_TO_SEED,
        INITIAL_DESIRED_TICK,
        MAX_TICK_DEVIATION,
        MAX_ALLOWED_DESIRED_TICK_CHANGE,
        {'from': deployer}
    )

    # TODO: Show parameters of event LiquidityParametersUpdated
    
    write_deploy_address(provider.address)

    assert read_deploy_address() == provider.address
