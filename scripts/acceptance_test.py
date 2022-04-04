from unittest import skip
from brownie import *
from pprint import pprint

import sys
import os.path
sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import *
from .utils import *


def main():
    accounts[0].transfer(DEV_MULTISIG, toE18(1))

    provider_address = read_deploy_address()

    provider = UniV3LiquidityProvider.at(provider_address)

    pool = interface.IUniswapV3Pool(POOL)
    position_manager = interface.INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER)

    tick_liquidity_before = pool.liquidity()

    tx = provider.mint(MIN_TICK, MAX_TICK)
    print_mint_return_value(tx.return_value)
    token_id, liquidity, _, _ = tx.return_value
    leftovers_checker.check(tx, need_check_agent_balance=False)

    assert_liquidity_provided(provider, pool, position_manager, token_id, liquidity, tick_liquidity_before)
