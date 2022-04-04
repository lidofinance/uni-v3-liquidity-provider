from brownie import *
from pprint import pprint

import sys
import os.path
sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import *
from .utils import *


def main(deployer_account=None, is_test_environment=False):
    if get_is_live() is None:
        assert deployer_account is not None, 'Please set deployer deployer as the first arg of the script (see brownie run -h)'

    if deployer_account is None:
        deployer_address = get_dev_deployer_address()
    else:
        accounts.load(deployer_account)
    
    print(f'DEPLOYER is {deployer_address}')

    print(
        f'Going to deploy with the following parameters:\n'
        f'  ETH_TO_SEED: {formatE18(ETH_TO_SEED)}\n'
        f'  POSITION_LOWER_TICK: {POSITION_LOWER_TICK} (price {get_price_from_tick(POSITION_LOWER_TICK):.4f})\n'
        f'  POSITION_UPPER_TICK: {POSITION_UPPER_TICK} (price {get_price_from_tick(POSITION_LOWER_TICK):.4f})\n'
        f'  MIN_ALLOWED_TICK: {MIN_ALLOWED_TICK} (price {get_price_from_tick(MIN_ALLOWED_TICK):.4f})\n'
        f'  MAX_ALLOWED_TICK: {MAX_ALLOWED_TICK} (price {get_price_from_tick(MAX_ALLOWED_TICK):.4f})\n'
    )

    if not is_test_environment:
        reply = input('Are they correct? (yes/no)\n')
        if reply != 'yes':
            print("Operator hasn't approved correctness of the parameters. Deployment stopped.")
            sys.exit(1)

    tx_params = {'from': deployer_address, "priority_fee": "2 gwei", "max_fee": "300 gwei" }
    provider = UniV3LiquidityProvider.deploy(
        ETH_TO_SEED,
        POSITION_LOWER_TICK,
        POSITION_UPPER_TICK,
        MIN_ALLOWED_TICK,
        MAX_ALLOWED_TICK,
        tx_params,
        publish_source=not is_test_environment
    )

    write_deploy_address(provider.address)

    provider.setAdmin(DEV_MULTISIG, tx_params)

    assert read_deploy_address() == provider.address
