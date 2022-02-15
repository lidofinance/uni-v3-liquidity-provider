import pytest
from brownie import ZERO_ADDRESS, Contract

STETH_TOKEN = "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84"
WETH_TOKEN = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
WSTETH_TOKEN = "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0"
POOL = "0xD340B57AAcDD10F96FC1CF10e15921936F41E29c"


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
def the_pool(interface):
    return interface.IUniswapV3PoolActions(POOL)

@pytest.fixture(scope='function')
def the_contract(deployer, TestUniV3LiquidityProvider):
    return TestUniV3LiquidityProvider.deploy({'from': deployer})

# making scope 'module' causes "This contract no longer exists" errors
@pytest.fixture(scope='function')
def swapper(deployer, TokensSwapper):
    return TokensSwapper.deploy({'from': deployer})


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
