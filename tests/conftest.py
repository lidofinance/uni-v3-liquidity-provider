import pytest
from brownie import ZERO_ADDRESS, Contract

import sys
import os.path
sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import *


@pytest.fixture(scope='function', autouse=True)
def shared_setup(fn_isolation):
    pass

@pytest.fixture(scope='module')
def deployer(accounts):
    return accounts[0]

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
def lido_agent():
    return Contract.from_abi("Foo", LIDO_AGENT, "")

@pytest.fixture(scope='function')
def provider(deployer, TestUniV3LiquidityProvider):
    return TestUniV3LiquidityProvider.deploy(
        ETH_TO_SEED,
        INITIAL_DESIRED_TICK,
        MAX_TICK_DEVIATION,
        MAX_ALLOWED_DESIRED_TICK_CHANGE,
        {'from': deployer})

# making scope 'module' causes "This contract no longer exists" errors
@pytest.fixture(scope='function')
def swapper(deployer, TokensSwapper):
    return TokensSwapper.deploy({'from': deployer})

# making scope 'module' causes "This contract no longer exists" errors
@pytest.fixture(scope='function')
def nft_mock(deployer, ERC721Mock):
    return ERC721Mock.deploy({'from': deployer})


class Helpers:
    @staticmethod
    def filter_events_from(addr, events):
        return list(filter(lambda evt: evt.address == addr, events))

    @staticmethod
    def assert_single_event_named(evt_name, tx, evt_keys_dict = None, source = None):
        receiver_events = tx.events[evt_name]
        if source is not None:
            receiver_events = Helpers.filter_events_from(source, receiver_events)
        assert len(receiver_events) == 1
        if evt_keys_dict is not None:
            assert dict(receiver_events[0]) == evt_keys_dict
        return receiver_events[0]

    @staticmethod
    def assert_no_events_named(evt_name, tx):
        assert evt_name not in tx.events

    @staticmethod
    def get_events(tx):
        assert tx.events.keys()

    @staticmethod
    def equal_with_precision(actual, expected, max_diff = None, max_diff_percent = None):
        if max_diff is None:
            max_diff = (max_diff_percent / 100) * expected
        return abs(actual - expected) <= max_diff

    @staticmethod
    def get_price(feed, inverse = False):
        decimals = feed.decimals()
        answer = feed.latestAnswer()
        if inverse:
            return  (10 ** decimals) / answer
        return answer / (10 ** decimals)

    @staticmethod
    def get_cross_price(priceA, priceB):
        return (priceA * priceB)


@pytest.fixture(scope='module')
def helpers():
    return Helpers
