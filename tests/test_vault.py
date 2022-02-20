from eth_account import Account
import pytest
from brownie import Contract, accounts, ZERO_ADDRESS, chain, reverts, ETH_ADDRESS

import sys
import os.path

from scripts.utils import get_balance

sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import toE18, ETH_TO_SEED, LIQUIDITY, WETH_TOKEN, WSTETH_TOKEN, LIDO_AGENT


class assert_leftovers_refunded():
    def __init__(self, provider, steth_token, wsteth_token, weth_token, lido_agent, need_check_agent_balance):
        self.provider = provider
        self.steth_token = steth_token
        self.wsteth_token = wsteth_token
        self.weth_token = weth_token
        self.lido_agent = lido_agent
        self.need_check_agent_balance = need_check_agent_balance

    def __enter__(self):
        self.agent_eth_before = self.lido_agent.balance()
        self.eth_leftover = self.provider.balance()
        self.weth_leftover = self.weth_token.balanceOf(self.provider.address)

    def __exit__(self, *args):
        assert self.provider.balance() == 0
        assert self.weth_token.balanceOf(self.provider.address) == 0
        assert self.steth_token.balanceOf(self.provider.address) <= 1
        assert self.wsteth_token.balanceOf(self.provider.address) == 0

        if self.need_check_agent_balance:
            assert self.lido_agent.balance() - self.agent_eth_before \
                == self.eth_leftover + self.weth_leftover


def test_getAmountOfEthForWsteth(provider):
    r = provider.getAmountOfEthForWsteth(1e18) / 1e18
    assert 1.0 < r < 2.0


def test_withdrawERC20(deployer, provider, weth_token):
    amount = 1e10

    with reverts('ONLY_ADMIN_OR_DAO_CAN'):
        provider.withdrawERC20(WETH_TOKEN, 123456789, {'from': accounts[2]})

    weth_token.deposit({'from': deployer, 'value': amount})
    weth_token.transfer(provider.address, amount, {'from': deployer})
    assert weth_token.balanceOf(provider.address) == amount
    assert weth_token.balanceOf(deployer) == 0

    agent_balance_before = weth_token.balanceOf(LIDO_AGENT)
    provider.withdrawERC20(WETH_TOKEN, amount)
    assert weth_token.balanceOf(LIDO_AGENT) == agent_balance_before + amount


def test_withdrawETH(deployer, provider):
    balance_before = get_balance(LIDO_AGENT)
    amount = toE18(1)

    with reverts('ONLY_ADMIN_OR_DAO_CAN'):
        provider.withdrawETH({'from': accounts[2]})

    deployer.transfer(provider.address, amount)
    provider.withdrawETH()

    deployer.transfer(provider.address, amount)
    provider.withdrawETH({'from': LIDO_AGENT})

    assert balance_before + 2 * amount == get_balance(LIDO_AGENT)


def disable_test_withdrawERC721(deployer, provider):
    assert False


# TODO: restore test
# def test_price_diff_to_chaini(provider):
#     diff = provider.calcSpotToChainlinkPriceAbsDiff(1059942733650492541866266407236800000, 1060801733107162407)
#     assert diff < 50

#     diff = provider.calcSpotToChainlinkPriceAbsDiff(1055542733650492541866266407236800000, 1060801733107162407)
#     assert diff > 50


def test_mint_happy_path(deployer, provider, steth_token, wsteth_token, weth_token, lido_agent):
    deployer.transfer(provider.address, ETH_TO_SEED)

    currentTickBefore = provider.getCurrentPriceTick();
    spotPrice = provider.getSpotPrice()
    # print(f'spot price = {spotPrice}')

    liquidityBefore = provider.getPositionLiquidity()
    assert liquidityBefore == 0

    with assert_leftovers_refunded(provider, steth_token, wsteth_token,
                                   weth_token, lido_agent, need_check_agent_balance=False):
        tx = provider.mint()

    print(tx.return_value)
    amount0, amount1, liquidity, token_id = tx.return_value
    token_owner = provider.getPositionTokenOwner(token_id)
    assert token_owner == LIDO_AGENT

    # wsteth_seeded, weth_seeded = [x / 10**18 for x in tx.return_value]

    # TODO: check pool position liquidity increment

    liquidityAfter = provider.getPositionLiquidity()
    # assert liquidityAfter == LIQUIDITY

    currentTickAfter = provider.getCurrentPriceTick();

    spotPrice = provider.getSpotPrice()
    # print(f'new spot price = {spotPrice}')

    # print(f'currentPriceTick (before/after): {currentTickBefore}/{currentTickAfter}')
    # print(f'position liquidity (before/after): {liquidityBefore}/{liquidityAfter}')


def test_exchange_for_tokens(deployer, provider, wsteth_token, weth_token):
    weth_amount = toE18(20.1234)
    wsteth_amount = toE18(30.98)
    aux_wsteth_weis = 1000

    deployer.transfer(provider.address, toE18(200))
    provider.exchangeEthForTokens(wsteth_amount, weth_amount)

    assert weth_token.balanceOf(provider.address) == weth_amount
    assert wsteth_amount <= wsteth_token.balanceOf(provider.address) <= wsteth_amount + aux_wsteth_weis


def test_refund_leftovers(deployer, provider, steth_token, wsteth_token, weth_token, lido_agent):
    deployer.transfer(provider.address, toE18(20))
    provider.exchangeEthForTokens(toE18(2), toE18(3))

    with assert_leftovers_refunded(provider, steth_token, wsteth_token, weth_token,
                                   lido_agent, need_check_agent_balance=True):
        provider.refundLeftoversToLidoAgent()


def disabled_test_seed_happy_path(deployer, provider, helpers):
    deployer.transfer(provider.address, ETH_TO_SEED)

    currentTickBefore = provider.getCurrentPriceTick();
    spotPrice = provider.getSpotPrice()
    # print(f'spot price = {spotPrice}')

    liquidityBefore = provider.getPositionLiquidity()
    assert liquidityBefore == 0

    tx = provider.seed(LIQUIDITY)

    # wsteth_seeded, weth_seeded = [x / 10**18 for x in tx.return_value]
    wsteth_seeded, weth_seeded = [x for x in tx.return_value]
    # print(f'seeded: wsteth = {wsteth_seeded}, weth = {weth_seeded}')

    liquidityAfter = provider.getPositionLiquidity()
    assert liquidityAfter == LIQUIDITY

    currentTickAfter = provider.getCurrentPriceTick();

    spotPrice = provider.getSpotPrice()
    # print(f'new spot price = {spotPrice}')

    # print(f'currentPriceTick (before/after): {currentTickBefore}/{currentTickAfter}')
    # print(f'position liquidity (before/after): {liquidityBefore}/{liquidityAfter}')


def disabled_test_seed_spot_prices_too_far_at_start(deployer, provider, pool, swapper):
    weth_to_swap = toE18(100)  # will cause ~ 63 movement shift at the time or writing the test
    currentTickBefore = provider.getCurrentPriceTick();
    spotPrice = provider.getSpotPrice()
    print(f'spot price = {spotPrice}')

    swapper.swapWeth({'from': deployer, 'value': weth_to_swap})

    currentTickAfter = provider.getCurrentPriceTick();
    print(f'currentPriceTick (before/after): {currentTickBefore}/{currentTickAfter}')
    spotPrice = provider.getSpotPrice()
    print(f'spot price = {spotPrice}')

    assert False

    deployer.transfer(provider.address, ETH_TO_SEED)
    
    with reverts('TICK_MOVEMENT_TOO_LARGE_AT_START'):
        provider.seed(LIQUIDITY)


def test_seed_success_if_small_price_tick_movement(deployer, provider, pool, swapper):
    weth_to_swap = toE18(30)  # will cause ~ 18 ticks movement at the time or writing the test

    currentTickBefore = provider.getCurrentPriceTick();
    swapper.swapWeth({'from': deployer, 'value': weth_to_swap})
    currentTickAfter = provider.getCurrentPriceTick();

    print(f'currentPriceTick (before/after): {currentTickBefore}/{currentTickAfter}')

    deployer.transfer(provider.address, ETH_TO_SEED)
    
    provider.seed(LIQUIDITY)
    # TODO: check pool size / position changed


def todo_test_seed_fails_due_to_chainlink_price_moved_much():
    # TODO: need to mock chainlink for this
    pass

def todo_test_compare_parameters():
    # params in contract and in config.py
    pass


