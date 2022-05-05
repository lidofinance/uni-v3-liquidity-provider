from brownie import *

import sys
import os.path
sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import *
from .utils import *


def main(token_id, liquidity):
    provider_address = read_deploy_address()

    provider = UniV3LiquidityProvider.at(provider_address)
    pool = interface.IUniswapV3Pool(POOL)
    position_manager = interface.INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER)
    lido_agent = accounts.at(LIDO_AGENT, force=True)

    assert liquidity is not None

    tick_liquidity_before = None
    liquidity = int(liquidity)
    token_id = int(token_id)

    assert_liquidity_provided(provider, pool, position_manager, token_id, liquidity, tick_liquidity_before, lido_agent)

    print("The test has passed, it's alright!")
