from pprint import pprint
from eth_account import Account
import pytest
from brownie import Contract, accounts, ZERO_ADDRESS, chain, reverts, ETH_ADDRESS

import sys
import os.path

from scripts.utils import formatE18, get_balance

sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import toE18, ETH_TO_SEED, WETH_TOKEN, WSTETH_TOKEN, LIDO_AGENT


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
        if args != [None, None, None]:
            return False  # to re-raise the exception

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

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
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

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.withdrawETH({'from': accounts[2]})

    deployer.transfer(provider.address, amount)
    provider.withdrawETH()

    deployer.transfer(provider.address, amount)
    provider.withdrawETH({'from': LIDO_AGENT})

    assert balance_before + 2 * amount == get_balance(LIDO_AGENT)


def disable_test_withdrawERC721(deployer, provider):
    assert False


def test_diff_between_two_prices_points(provider):
    assert 0 == provider.priceDeviationPoints(toE18(1), toE18(1))
    assert 5000 == provider.priceDeviationPoints(toE18(2), toE18(1))
    assert provider.TOTAL_POINTS() == provider.priceDeviationPoints(toE18(1), toE18(2))
    assert provider.TOTAL_POINTS() == provider.priceDeviationPoints(toE18(2), toE18(0))
    with reverts('ZERO_BASE_PRICE'):
        assert provider.TOTAL_POINTS() == provider.priceDeviationPoints(toE18(0), toE18(2))
    
    assert 2 == provider.priceDeviationPoints(toE18(1.060505), toE18(1.060775))
    assert 298 == provider.priceDeviationPoints(toE18(1.03), toE18(1.060775))


def test_mint_happy_path(deployer, provider, steth_token, wsteth_token, weth_token, lido_agent):
    deployer.transfer(provider.address, ETH_TO_SEED)

    # currentTickBefore = provider.getCurrentPriceTick();
    # spotPrice = provider.getSpotPrice()
    # print(f'spot price = {spotPrice}')

    liquidityBefore = provider.getPositionLiquidity()
    assert liquidityBefore == 0

    with assert_leftovers_refunded(provider, steth_token, wsteth_token,
                                   weth_token, lido_agent, need_check_agent_balance=False):
        tx = provider.mint()
        amount0, amount1, liquidity, token_id = tx.return_value
        pprint({
            'wsteth_used': formatE18(amount0),
            'weth_used': formatE18(amount1),
            'liquidity': formatE18(liquidity),
            'token_id': token_id,
        })
    
    assert provider.getPositionTokenOwner(token_id) == LIDO_AGENT

    # TODO: check pool position liquidity increment

    # liquidityAfter = provider.getPositionLiquidity()
    # assert liquidityAfter == LIQUIDITY

    # currentTickAfter = provider.getCurrentPriceTick();

    # spotPrice = provider.getSpotPrice()
    # print(f'new spot price = {spotPrice}')

    # print(f'currentPriceTick (before/after): {currentTickBefore}/{currentTickAfter}')
    # print(f'position liquidity (before/after): {liquidityBefore}/{liquidityAfter}')


def disabled_test_mint_succeeds_if_small_price_deviation(deployer, provider, swapper):
    deployer.transfer(provider.address, ETH_TO_SEED)

    weth_to_swap = toE18(30)  # will cause ~ 18 ticks movement at the time or writing the test

    tickBefore = provider.getCurrentPriceTick();
    swapper.swapWeth({'from': deployer, 'value': weth_to_swap})
    tickAfter = provider.getCurrentPriceTick();

    assert abs(tickAfter - provider.DESIRED_TICK()) < provider.MAX_TICK_DEVIATION()
    # assert abs(tickBefore - tickAfter) < provider.

    print(f'currentPriceTick (before/after): {tickBefore}/{tickAfter}')

    tx = provider.mint()
    amount0, amount1, liquidity, token_id = tx.return_value
    assert provider.getPositionTokenOwner(token_id) == LIDO_AGENT


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


def test_calc_token_amounts(deployer, provider, helpers):
    liquidity = ETH_TO_SEED / 10
    deployer.transfer(provider.address, ETH_TO_SEED)

    currentTickBefore = provider.getCurrentPriceTick();
    spotPrice = provider.getSpotPrice()
    # print(f'spot price = {spotPrice}')

    liquidityBefore = provider.getPositionLiquidity()
    assert liquidityBefore == 0

    tx = provider.calcTokenAmounts(liquidity)

    # wsteth_seeded, weth_seeded = [x / 10**18 for x in tx.return_value]
    # wsteth_seeded, weth_seeded = [x for x in tx.return_value]
    # print(f'seeded: wsteth = {wsteth_seeded}, weth = {weth_seeded}')

    # liquidityAfter = 
    assert provider.getPositionLiquidity() == liquidity

    # currentTickAfter = provider.getCurrentPriceTick();

    # spotPrice = provider.getSpotPrice()
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


def todo_test_seed_fails_due_to_chainlink_price_moved_much():
    # TODO: need to mock chainlink for this
    pass

def todo_test_compare_parameters():
    # params in contract and in config.py
    pass


