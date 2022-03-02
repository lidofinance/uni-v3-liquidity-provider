from pprint import pprint
from eth_account import Account
import pytest
from brownie import Contract, accounts, ZERO_ADDRESS, chain, reverts, ETH_ADDRESS

import sys
import os.path

from scripts.utils import *
import scripts.deploy

sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import *


def assert_liquidity_provided(provider, pool, token_id):
    assert provider.getPositionTokenOwner(token_id) == LIDO_AGENT

    # TODO: calc approx (or exact) liquidity threshold
    assert 0 < get_tick_positions_liquidity(pool, provider.POSITION_LOWER_TICK())
    assert 0 < get_tick_positions_liquidity(pool, provider.POSITION_UPPER_TICK())


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


def assert_contract_params_after_deployment(provider):
    assert POOL == provider.POOL()
    assert WSTETH_TOKEN == provider.TOKEN0()
    assert WETH_TOKEN == provider.TOKEN1()
    assert STETH_TOKEN == provider.STETH_TOKEN()
    assert LIDO_AGENT == provider.LIDO_AGENT()

    assert INITIAL_DESIRED_TICK == provider.desiredTick()
    assert MAX_TICK_DEVIATION == provider.MAX_TICK_DEVIATION()
    assert ETH_TO_SEED - provider.ETH_AMOUNT_MARGIN() == provider.ethAmount()


def test_addresses(provider):
    assert_contract_params_after_deployment(provider)


def test_addresses(provider):
    assert_contract_params_after_deployment(provider)


def test_deploy_script(deployer, UniV3LiquidityProvider):
    scripts.deploy.main(deployer)
    contract_address = read_deploy_address()
    provider = UniV3LiquidityProvider.at(contract_address)
    assert provider.admin() == deployer

    assert_contract_params_after_deployment(provider)


def test_get_tick_from_price():
    assert get_tick_from_price(1.060857781063038396) == 590
    assert get_tick_from_price(1.060894800215471135) == 591
    # TODO: add more


def test_calc_tokens_ratio(provider):
    def calcRatio(tick):
        ratio = provider.calcDesiredTokensRatio(tick)
        return fromE18(ratio)

    # Target ratios at the ticks are taken from calcTokenAmounts() functions
    # which uses pool mint function to get the amounts.
    # It's a question why they differ by ~0.15%
    
    # TODO: why deviation to high??
    assert deviation_percent(calcRatio(590), 0.16844922199929974) < 0.26
    assert deviation_percent(calcRatio(592), 0.16758718925546812) < 0.2
    assert deviation_percent(calcRatio(595), 0.16603384082522651) < 0.2
    assert deviation_percent(calcRatio(598), 0.164357637510406) < 0.2


def test_calc_token_amounts(provider):
    eth_amount = toE18(600) - provider.ETH_AMOUNT_MARGIN()

    wsteth, weth = provider.calcDesiredTokenAmounts(591, toE18(600))
    assert deviation_percent(wsteth, 85654282005994061824) < 0.05
    assert deviation_percent(weth, 509044590220957253632) < 0.05

    wsteth, weth = provider.calcDesiredTokenAmounts(598, eth_amount)
    assert deviation_percent(wsteth, 83960909953383759872) < 0.2
    assert deviation_percent(weth, 510842764748720177152) < 0.2


def test_getAmountOfEthForWsteth(provider):
    r = provider.getAmountOfEthForWsteth(1e18) / 1e18
    assert 1.06 < r < 1.07  # just sanity check


def test_refundETH(deployer, provider, helpers):
    balance_before = get_balance(LIDO_AGENT)
    amount1 = toE18(1)
    amount2 = toE18(2)

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.refundETH({'from': accounts[2]})

    deployer.transfer(provider.address, amount1)
    tx = provider.refundETH()
    helpers.assert_single_event_named('EthRefunded', tx, source=provider.address,
        evt_keys_dict = {'requestedBy': deployer.address, 'amount': amount1})

    deployer.transfer(provider.address, amount2)
    tx = provider.refundETH({'from': LIDO_AGENT})
    helpers.assert_single_event_named('EthRefunded', tx, source=provider.address,
        evt_keys_dict = {'requestedBy': LIDO_AGENT, 'amount': amount2})

    assert balance_before + (amount1 + amount2) == get_balance(LIDO_AGENT)
    assert provider.balance() == 0


def test_refundERC20(deployer, provider, weth_token, helpers):
    amount = 1e10

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.refundERC20(WETH_TOKEN, 123456789, {'from': accounts[2]})

    weth_token.deposit({'from': deployer, 'value': amount})
    weth_token.transfer(provider.address, amount, {'from': deployer})
    assert weth_token.balanceOf(provider.address) == amount
    assert weth_token.balanceOf(deployer) == 0

    agent_balance_before = weth_token.balanceOf(LIDO_AGENT)
    tx = provider.refundERC20(WETH_TOKEN, amount)
    helpers.assert_single_event_named('ERC20Refunded', tx, source=provider.address,
        evt_keys_dict = {'requestedBy': deployer, 'token': WETH_TOKEN, 'amount': amount})

    assert weth_token.balanceOf(LIDO_AGENT) == agent_balance_before + amount


def test_refundERC721(deployer, provider, nft_mock, helpers):
    nft = 1234
    nft_mock.mintToken(nft)
    assert nft_mock.ownerOf(nft) == deployer
    nft_mock.transferFrom(deployer, provider, nft)
    assert nft_mock.ownerOf(nft) == provider

    tx = provider.refundERC721(nft_mock, nft)
    helpers.assert_single_event_named('ERC721Refunded', tx, source=provider.address,
        evt_keys_dict = {'requestedBy': deployer, 'token': nft_mock.address, 'tokenId': nft})

    assert nft_mock.ownerOf(nft) == LIDO_AGENT
    

def test_diff_between_two_prices_points(provider):
    assert 0 == provider.priceDeviationPoints(toE18(1), toE18(1))
    assert 5000 == provider.priceDeviationPoints(toE18(2), toE18(1))
    assert provider.TOTAL_POINTS() == provider.priceDeviationPoints(toE18(1), toE18(2))
    assert provider.TOTAL_POINTS() == provider.priceDeviationPoints(toE18(2), toE18(0))
    with reverts('ZERO_BASE_PRICE'):
        assert provider.TOTAL_POINTS() == provider.priceDeviationPoints(toE18(0), toE18(2))
    
    assert 2 == provider.priceDeviationPoints(toE18(1.060505), toE18(1.060775))
    assert 298 == provider.priceDeviationPoints(toE18(1.03), toE18(1.060775))


def test_calc_desired_and_min_token_amounts(deployer, TestUniV3LiquidityProvider, helpers):
    desired_tick = INITIAL_DESIRED_TICK
    max_tick_deviation = MAX_TICK_DEVIATION

    provider = TestUniV3LiquidityProvider.deploy(
        ETH_TO_SEED,
        desired_tick,
        max_tick_deviation,
        MAX_ALLOWED_DESIRED_TICK_CHANGE,
        {'from': deployer})

    helpers.assert_single_event_named('LiquidityParametersUpdated', provider.tx, source=provider.address)
    
    eth_to_use = ETH_TO_SEED - provider.ETH_AMOUNT_MARGIN()
    
    amount0, amount1 = provider.calcDesiredTokenAmounts(desired_tick, eth_to_use)
    lowerAmount0, lowerAmount1 = provider.calcDesiredTokenAmounts(
        desired_tick - max_tick_deviation, eth_to_use)
    upperAmount0, upperAmount1 = provider.calcDesiredTokenAmounts(
        desired_tick + max_tick_deviation, eth_to_use)

    pprint({
        '0': formatE18(amount0),
        '1': formatE18(amount1),
        'l0': formatE18(lowerAmount0),
        'l1': formatE18(lowerAmount1),
        'u0': formatE18(upperAmount0),
        'u1': formatE18(upperAmount1),
    })
    assert provider.desiredWstethAmount() == amount0
    assert provider.desiredWethAmount() == amount1
    assert provider.minWstethAmount() == min(upperAmount0, lowerAmount0)
    assert provider.minWethAmount() == min(lowerAmount1, upperAmount1)


def test_only_admin_or_dao_can_set_admin(deployer, provider):
    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.setAdmin(accounts[1], {'from': accounts[1]})

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.setAdmin(accounts[1], {'from': POOL})


def test_only_admin_or_dao_can_mint(deployer, provider):
    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.mint(provider.desiredTick(), {'from': accounts[1]})

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.mint(provider.desiredTick(), {'from': POOL})

    with reverts('NOT_ENOUGH_ETH'):
        provider.mint(provider.desiredTick(), {'from': LIDO_AGENT})

    with reverts('NOT_ENOUGH_ETH'):
        provider.mint(provider.desiredTick(), {'from': deployer})


def test_only_admin_or_dao_can_refund(deployer, provider):
    dummy_address = '0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0'

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.refundERC721(dummy_address, 0, {'from': accounts[1]})

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.refundERC20(dummy_address, 0, {'from': accounts[1]})

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.refundETH({'from': accounts[1]})


def test_set_admin(deployer, provider, helpers):
    new_admin = accounts[1]
    tx = provider.setAdmin(new_admin, {'from': deployer})
    helpers.assert_single_event_named('AdminSet', tx, evt_keys_dict = {'admin': new_admin} )
    tx = provider.setAdmin(deployer, {'from': new_admin})
    helpers.assert_single_event_named('AdminSet', tx, evt_keys_dict = {'admin': deployer} )


def test_mint_happy_path(deployer, provider, pool, steth_token, wsteth_token, weth_token, lido_agent, helpers):
    deployer.transfer(provider.address, ETH_TO_SEED)

    assert 0 == get_tick_positions_liquidity(pool, provider.POSITION_LOWER_TICK())
    assert 0 == get_tick_positions_liquidity(pool, provider.POSITION_UPPER_TICK())

    with assert_leftovers_refunded(provider, steth_token, wsteth_token,
                                   weth_token, lido_agent, need_check_agent_balance=False):
        tx = provider.mint(provider.desiredTick())
        print_mint_return_value(tx.return_value)
        token_id, liquidity, amount0, amount1 = tx.return_value

        helpers.assert_single_event_named('LiquidityParametersUpdated', tx)
        helpers.assert_single_event_named('LiquidityProvided', tx, evt_keys_dict={
            'tokenId': token_id,
            'liquidity': liquidity,
            'wstethAmount': amount0,
            'wethAmount': amount1,
        })

    assert_liquidity_provided(provider, pool, token_id)


def test_mint_succeeds_if_small_tick_deviation(deployer, provider, pool, swapper):
    deployer.transfer(provider.address, ETH_TO_SEED)

    weth_to_swap = toE18(20)

    tickBefore = provider.getCurrentPriceTick();
    swapper.swapWeth({'from': deployer, 'value': weth_to_swap})
    tickAfter = provider.getCurrentPriceTick();

    print(f'tick (before/after): {tickBefore}/{tickAfter}')

    assert abs(tickAfter - provider.desiredTick()) < provider.MAX_TICK_DEVIATION()

    tx = provider.mint(provider.desiredTick())
    token_id, _, _, _ = tx.return_value
    print_mint_return_value(tx.return_value)

    assert_liquidity_provided(provider, pool, token_id)


def test_mint_fails_if_large_tick_deviation(deployer, provider, swapper):
    deployer.transfer(provider.address, ETH_TO_SEED)

    weth_to_swap = toE18(100)

    tickBefore = provider.getCurrentPriceTick();
    swapper.swapWeth({'from': deployer, 'value': weth_to_swap})
    tickAfter = provider.getCurrentPriceTick();

    print(f'tick (before/after): {tickBefore}/{tickAfter}')

    assert abs(tickAfter - provider.desiredTick()) > provider.MAX_TICK_DEVIATION()

    with reverts('TICK_DEVIATION_TOO_BIG_AT_START'):
        provider.mint(provider.desiredTick())


def test_attempt_to_change_desired_tick_too_big(deployer, provider):
    with reverts('DESIRED_TICK_IS_OUT_OF_ALLOWED_RANGE'):
        provider.mint(provider.MIN_ALLOWED_DESIRED_TICK() - 1)

    with reverts('DESIRED_TICK_IS_OUT_OF_ALLOWED_RANGE'):
        provider.mint(provider.MAX_ALLOWED_DESIRED_TICK() + 1)


def test_wrap_eth_to_tokens(deployer, provider, wsteth_token, weth_token):
    weth_amount = toE18(20.1234)
    wsteth_amount = toE18(30.98)
    aux_wsteth_weis = 1000

    deployer.transfer(provider.address, toE18(200))
    provider.wrapEthToTokens(wsteth_amount, weth_amount)

    assert weth_token.balanceOf(provider.address) == weth_amount
    assert wsteth_amount <= wsteth_token.balanceOf(provider.address) <= wsteth_amount + aux_wsteth_weis


def test_wrap_eth_to_tokens(deployer, provider, steth_token, wsteth_token, weth_token, lido_agent):
    deployer.transfer(provider.address, toE18(20))
    provider.wrapEthToTokens(toE18(2), toE18(3))

    with assert_leftovers_refunded(provider, steth_token, wsteth_token, weth_token,
                                   lido_agent, need_check_agent_balance=True):
        provider.refundLeftoversToLidoAgent()


def disabled_test_calc_token_amounts(deployer, provider, helpers):
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
