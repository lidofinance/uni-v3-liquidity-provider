from brownie import *

import sys
import os.path
sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import *
from .utils import *


def main(token_id=None, liquidity=None):
    provider_address = read_deploy_address()

    provider = UniV3LiquidityProvider.at(provider_address)
    pool = interface.IUniswapV3Pool(POOL)
    position_manager = interface.INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER)
    steth_token = interface.ERC20(STETH_TOKEN) 
    weth_token = interface.WETH(WETH_TOKEN)
    wsteth_token = interface.WSTETH(WSTETH_TOKEN) 
    lido_agent = accounts.at(LIDO_AGENT, force=True)

    if token_id is None:
        assert liquidity is None

        admin = DEV_MULTISIG

        accounts[0].transfer(admin, toE18(1))

        tick_liquidity_before = pool.liquidity()
        leftovers_checker = leftovers_refund_checker(
            provider, steth_token, wsteth_token, weth_token, lido_agent, Helpers)

        tx = provider.mint(MIN_TICK, MAX_TICK, {'from': admin})
        print_mint_return_value(tx.return_value)
        token_id, liquidity, _, _ = tx.return_value
        leftovers_checker.check(tx, need_check_agent_balance=False)
    else:
        assert liquidity is not None

        tick_liquidity_before = None
        liquidity = int(liquidity)
        token_id = int(token_id)

    assert_liquidity_provided(provider, pool, position_manager, token_id, liquidity, tick_liquidity_before, lido_agent)

    print("The test has passed, it's alright!")
