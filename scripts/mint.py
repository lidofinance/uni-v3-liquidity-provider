from brownie import *

import sys
import os.path
sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import *
from .utils import *


def main(execute_tx, deployer_account=None, priority_fee='2 gwei', max_fee='300 gwei', skip_confirmation=False):
    """`deployer_account` in live environment can either be:
        - brownie account name: use the account
        - None: save tx calldata for use in multisig
    """
    if not skip_confirmation:
        assert not get_is_live()
    
    if type(execute_tx) != bool:
        assert execute_tx in ['True', 'False'], "'execute_tx' can only by True or False"
        execute_tx = True if execute_tx == 'True' else False
    
    if execute_tx:
        if skip_confirmation:
            deployer_address = deployer_account
        else:
            assert deployer_account is not None, 'Please specify brownie account to use'
            deployer_address = accounts.load(deployer_account)
    else:
        deployer_address = None

    print(f'DEPLOYER is {deployer_address}')
    
    provider_address = read_deploy_address()
    provider = UniV3LiquidityProvider.at(provider_address)

    print(
        f'Going to provide liquidity to Uni-v3 pool with the following parameters:\n'
        f'  min tick: {MIN_TICK} (price {get_price_from_tick(MIN_TICK):.4f})\n'
        f'  max tick: {MAX_TICK} (price {get_price_from_tick(MAX_TICK):.4f})\n'
        f'  eth to seed: {formatE18(provider.ETH_TO_SEED())}\n'
        f'  eth on the contract: {formatE18(provider.balance())}\n'
        f'  position lower tick: {provider.POSITION_LOWER_TICK()} (price {get_price_from_tick(POSITION_LOWER_TICK):.4f})\n'
        f'  position upper tick: {provider.POSITION_UPPER_TICK()} (price {get_price_from_tick(POSITION_UPPER_TICK):.4f})\n'
    )

    if execute_tx:
        tx_params = {
            'from': deployer_address,
            "priority_fee": priority_fee,
            "max_fee": max_fee
        }

        if not skip_confirmation:
            print(
                f'  from: {tx_params["from"]}\n'
                f'  priority_fee: {tx_params["priority_fee"]}\n'
                f'  max_fee: {tx_params["max_fee"]}\n'
            )
            reply = input(f'The transaction will be executed on chain ({network.show_active()}).\n'
                          f'Are these parameters correct? (yes/no)\n')
            if reply != 'yes':
                print("Operator hasn't approved correctness of the parameters. Deployment stopped.")
                sys.exit(1)
            print()

        tx = provider.mint(MIN_TICK, MAX_TICK, tx_params)
        token_id, liquidity, wsteth_amount, weth_amount = tx.return_value

        print(
            f'Liquidity provided:\n'
            f'  position token is: {token_id}\n'
            f'  amount of liquidity: {liquidity}\n'
            f'  wsteth amount: {formatE18(wsteth_amount)}\n'
            f'  weth amount: {formatE18(weth_amount)}\n'
        )

        return tx
    else:
        calldata_path = get_mint_calldata_path()
        calldata = provider.mint.encode_input(MIN_TICK, MAX_TICK)
        with open(calldata_path, 'w') as fp:
            fp.write(calldata)
        print(f'Transaction calldata is written to {calldata_path}')

        return calldata_path


    