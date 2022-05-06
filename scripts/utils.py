from brownie import Contract, network, accounts
from math import floor, sqrt, log
from pprint import pprint
import os


def toE18(x):
    return round(x * 1e18)

def fromE18(x):
    return x / 1e18

def formatE18(num):
    floating_num = num / 1e18
    return f'{floating_num:.4f} ({floor(num)})'

def get_balance(address):
    return Contract.from_abi("Foo", address, "").balance()

def deviation_percent(value, base):
    return 100 * abs((value - base) / base)

def get_tick_from_price(price):
    return floor(log(sqrt(price), sqrt(1.0001)))

def get_price_from_tick(tick):
    return 1.0001**tick

def get_tick_positions_liquidity(pool, tick):
    (liquidity_gross, _, _, _, _, _, _, _) = pool.ticks(tick)
    return liquidity_gross

def print_provider_params(provider):
    pprint({
        'desiredWsteth': formatE18(provider.desiredWsteth()),
        'desiredWeth': formatE18(provider.desiredWeth()),
        'minWsteth': formatE18(provider.minWsteth()),
        'minWeth': formatE18(provider.minWeth()),
        'desiredTick': provider.desiredTick(),
    })

def print_mint_return_value(mint_return_value):
    token_id, liquidity, amount0, amount1 = mint_return_value
    pprint({
        'wsteth_used': formatE18(amount0),
        'weth_used': formatE18(amount1),
        'liquidity': formatE18(liquidity),
        'token_id': token_id,
    })

def get_deploy_address_path():
    network_name = network.show_active()
    return os.path.join(
        os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)),
        f'deploy-{network_name}-address.txt'
    )

def get_mint_calldata_path():
    network_name = network.show_active()
    return os.path.join(
        os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)),
        f'mint-{network_name}-calldata.txt'
    )

def write_deploy_address(address):
    with open(get_deploy_address_path(), 'w') as fp:
        fp.write(address)

def read_deploy_address():
    with open(get_deploy_address_path(), 'r') as fp:
        return fp.read()

def get_dev_deployer_address():
    return accounts[0]

def get_is_live():
    dev_networks = [
        "development",
        "hardhat",
        "hardhat-fork",
        "mainnet-fork",
        "goerli-fork"
    ]
    return network.show_active() not in dev_networks


def assert_liquidity_provided(provider, pool, position_manager, token_id, expected_liquidity, tick_liquidity_before, lido_agent):
    assert position_manager.ownerOf(token_id) == lido_agent.address

    position_liquidity, _, _, tokensOwed0, tokensOwed1 = pool.positions(provider.POSITION_ID())

    assert tokensOwed0 == 0
    assert tokensOwed1 == 0

    assert position_liquidity == expected_liquidity, f'{position_liquidity} != {expected_liquidity}'

    if tick_liquidity_before is not None:
        current_tick_liquidity = pool.liquidity()
        assert current_tick_liquidity == tick_liquidity_before + expected_liquidity


class leftovers_refund_checker():
    """Check provider and agent states before and after refunding and/or minting"""
    def __init__(self, provider, steth_token, wsteth_token, weth_token, lido_agent, helpers):
        self.provider = provider
        self.steth_token = steth_token
        self.wsteth_token = wsteth_token
        self.weth_token = weth_token
        self.lido_agent = lido_agent
        self.helpers = helpers

        self.agent_eth_before = self.lido_agent.balance()
        self.agent_steth_before = self.steth_token.balanceOf(self.lido_agent.address)
        self.eth_leftover = self.provider.balance()
        self.weth_leftover = self.weth_token.balanceOf(self.provider.address)
        self.wsteth_leftover = self.wsteth_token.balanceOf(self.provider.address)

    def check(self, tx, need_check_agent_balance=False):
        assert self.provider.balance() == 0
        assert self.weth_token.balanceOf(self.provider.address) == 0
        assert self.steth_token.balanceOf(self.provider.address) <= 1
        assert self.wsteth_token.balanceOf(self.provider.address) == 0

        token_id, liquidity, amount0, amount1 = tx.return_value
        self.helpers.assert_single_event_named('LiquidityProvided', tx, evt_keys_dict={
            'tokenId': token_id,
            'liquidity': liquidity,
            'wstethAmount': amount0,
            'wethAmount': amount1,
        })

        if need_check_agent_balance:
            assert self.lido_agent.balance() - self.agent_eth_before \
                == self.eth_leftover + self.weth_leftover

            assert deviation_percent(
                self.steth_token.balanceOf(self.lido_agent.address) - self.agent_steth_before,
                self.wsteth_leftover * self.wsteth_token.stEthPerToken() / 1e18
            ) < 0.001  # 0.001%


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