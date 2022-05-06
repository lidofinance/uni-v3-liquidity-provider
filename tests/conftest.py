import pytest
from brownie import ZERO_ADDRESS, Contract

import sys
import os.path
sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import *
from scripts.utils import Helpers


@pytest.fixture(scope='function', autouse=True)
def shared_setup(fn_isolation):
    pass

@pytest.fixture(scope='module')
def deployer():
    return get_dev_deployer_address()

@pytest.fixture(scope='module')
def steth_token(interface):
    return interface.ERC20(STETH_TOKEN)

@pytest.fixture(scope='module')
def weth_token(interface):
    return interface.WETH(WETH_TOKEN)

@pytest.fixture(scope='module')
def wsteth_token(interface):
    return interface.WSTETH(WSTETH_TOKEN)

@pytest.fixture(scope='module')
def pool(interface):
    return interface.IUniswapV3Pool(POOL)

@pytest.fixture(scope='module')
def position_manager(interface):
    return interface.INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER)

@pytest.fixture(scope='module')
def lido_agent(accounts):
    return accounts.at(LIDO_AGENT, force=True)

@pytest.fixture(scope='function')
def provider(deployer, TestUniV3LiquidityProvider):
    return TestUniV3LiquidityProvider.deploy(
        ETH_TO_SEED,
        POSITION_LOWER_TICK,
        POSITION_UPPER_TICK,
        MIN_ALLOWED_TICK,
        MAX_ALLOWED_TICK,
        {'from': deployer})

# making scope 'module' causes "This contract no longer exists" errors
@pytest.fixture(scope='function')
def swapper(deployer, TokensSwapper):
    return TokensSwapper.deploy({'from': deployer})

# making scope 'module' causes "This contract no longer exists" errors
@pytest.fixture(scope='function')
def nft_mock(deployer, ERC721Mock):
    return ERC721Mock.deploy({'from': deployer})


@pytest.fixture(scope='module')
def helpers():
    return Helpers
