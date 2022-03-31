from contextlib import AsyncExitStack
from mimetypes import init
from pprint import pprint
from eth_account import Account
import pytest
from brownie import Contract, accounts, ZERO_ADDRESS, chain, reverts, ETH_ADDRESS

import sys
import os.path

from scripts.utils import *
import scripts.deploy
import scripts.mint

sys.path.append(
    os.path.abspath(os.path.join(os.path.dirname(__file__), os.path.pardir)))
from config import *


def assert_liquidity_provided(provider, pool, position_manager, token_id, expected_liquidity, tick_liquidity_before):
    assert position_manager.ownerOf(token_id) == LIDO_AGENT

    position_liquidity, _, _, tokensOwed0, tokensOwed1 = pool.positions(provider.POSITION_ID())
    current_tick_liquidity = pool.liquidity()

    assert tokensOwed0 == 0
    assert tokensOwed1 == 0
    assert current_tick_liquidity == tick_liquidity_before + expected_liquidity
    assert position_liquidity == expected_liquidity


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
        self.agent_steth_before = self.steth_token.balanceOf(self.lido_agent.address)
        self.eth_leftover = self.provider.balance()
        self.weth_leftover = self.weth_token.balanceOf(self.provider.address)
        self.wsteth_leftover = self.wsteth_token.balanceOf(self.provider.address)

    def __exit__(self, *args):
        assert self.provider.balance() == 0
        assert self.weth_token.balanceOf(self.provider.address) == 0
        assert self.steth_token.balanceOf(self.provider.address) <= 1
        assert self.wsteth_token.balanceOf(self.provider.address) == 0

        if self.need_check_agent_balance:
            assert self.lido_agent.balance() - self.agent_eth_before \
                == self.eth_leftover + self.weth_leftover

            assert deviation_percent(
                self.steth_token.balanceOf(self.lido_agent.address) - self.agent_steth_before,
                self.wsteth_leftover * self.wsteth_token.stEthPerToken() / 1e18
            ) < 0.001  # 0.001%


def assert_contract_params_after_deployment(provider):
    assert POOL == provider.POOL()
    assert WSTETH_TOKEN == provider.TOKEN0()
    assert WETH_TOKEN == provider.TOKEN1()
    assert STETH_TOKEN == provider.STETH_TOKEN()
    assert LIDO_AGENT == provider.LIDO_AGENT()

    assert POSITION_LOWER_TICK == provider.POSITION_LOWER_TICK()
    assert POSITION_UPPER_TICK == provider.POSITION_UPPER_TICK()
    assert MIN_ALLOWED_TICK == provider.MIN_ALLOWED_TICK()
    assert MAX_ALLOWED_TICK == provider.MAX_ALLOWED_TICK()
    assert ETH_TO_SEED == provider.ETH_TO_SEED()


def test_addresses(provider):
    assert_contract_params_after_deployment(provider)


def test_deploy_script(deployer, UniV3LiquidityProvider):
    scripts.deploy.main(deployer, skip_confirmation=True)
    contract_address = read_deploy_address()
    provider = UniV3LiquidityProvider.at(contract_address)
    assert provider.admin() == deployer

    assert_contract_params_after_deployment(provider)


def test_deploy_script_and_mint_script(deployer, UniV3LiquidityProvider, pool, position_manager):
    scripts.deploy.main(deployer, skip_confirmation=True)
    contract_address = read_deploy_address()
    provider = UniV3LiquidityProvider.at(contract_address)
    assert provider.admin() == deployer
    tick_liquidity_before = pool.liquidity()

    assert_contract_params_after_deployment(provider)

    deployer.transfer(provider.address, ETH_TO_SEED)
    tx = scripts.mint.main(deployer, skip_confirmation=True)
    token_id, liquidity, _, _ = tx.return_value

    assert_liquidity_provided(provider, pool, position_manager, token_id, liquidity, tick_liquidity_before)


def test_eth_received(deployer, provider, helpers):
    amount = toE18(1)
    tx = deployer.transfer(provider.address, amount)
    helpers.assert_single_event_named('EthReceived', tx, source=provider.address,
        evt_keys_dict = {'amount': amount})


def test_refund_eth(deployer, provider, helpers):
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


def test_refund_erc20(deployer, provider, weth_token, helpers):
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


def test_refund_erc721(deployer, provider, nft_mock, helpers):
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


def test_only_admin_or_dao_can_set_admin(deployer, provider):
    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.setAdmin(accounts[1], {'from': accounts[1]})

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.setAdmin(accounts[1], {'from': POOL})


def test_only_admin_or_dao_can_mint(deployer, provider):
    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.mint(MIN_TICK, MAX_TICK, {'from': accounts[1]})

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.mint(MIN_TICK, MAX_TICK, {'from': POOL})

    with reverts('NOT_ENOUGH_ETH'):
        provider.mint(MIN_TICK, MAX_TICK, {'from': LIDO_AGENT})

    with reverts('NOT_ENOUGH_ETH'):
        provider.mint(MIN_TICK, MAX_TICK, {'from': deployer})


def test_only_admin_or_dao_can_refund(deployer, provider):
    dummy_address = '0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0'

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.refundERC721(dummy_address, 0, {'from': accounts[1]})

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.refundERC20(dummy_address, 0, {'from': accounts[1]})

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.refundETH({'from': accounts[1]})


def test_only_admin_or_dao_can_close_position(deployer, provider):
    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.closeLiquidityPosition({'from': POOL})

    with reverts('AUTH_ADMIN_OR_LIDO_AGENT'):
        provider.closeLiquidityPosition({'from': accounts[1]})


def test_set_admin(deployer, provider, helpers):
    assert provider.admin() == deployer

    new_admin = accounts[1]
    tx = provider.setAdmin(new_admin, {'from': LIDO_AGENT})
    helpers.assert_single_event_named('AdminSet', tx, evt_keys_dict = {'admin': new_admin} )
    assert provider.admin() == new_admin

    tx = provider.setAdmin(deployer, {'from': new_admin})
    helpers.assert_single_event_named('AdminSet', tx, evt_keys_dict = {'admin': deployer} )
    assert provider.admin() == deployer


def test_calc_token_amounts_from_pool_sqrt_price(deployer, TestUniV3LiquidityProvider, swapper):
    def check_token_amounts(provider):
        tick = provider.getCurrentPriceTick()
        our_wsteth, our_weth = provider.calcTokenAmountsFromCurrentPoolSqrtPrice(ETH_TO_SEED)

        print(f'our wsteth/weth {formatE18(our_wsteth)} / {formatE18(our_weth)}')

        liquidity = provider.getLiquidityForAmounts(our_wsteth, our_weth)

        tx = provider.calcTokenAmountsByPool(liquidity)
        pool_wsteth, pool_weth = tx.return_value

        print(
            f'Token amounts for tick {tick}\n'
            f'     wsteth (our/pool): {formatE18(our_wsteth)} / {formatE18(pool_wsteth)}  (difference {formatE18(abs(pool_wsteth - our_wsteth))})\n'
            f'     weth   (our/pool): {formatE18(our_weth)} / {formatE18(pool_weth)}  (difference {formatE18(abs(pool_weth - our_weth))})\n'
        )

        assert our_wsteth - pool_wsteth == 0, f'wsteth diff {formatE18(pool_wsteth - our_wsteth)}'  
        assert our_weth - pool_weth < 10, f'weth diff {formatE18(pool_weth - our_weth)}'  


    # Loop making swaps to change pool state
    for _ in range(10):
        provider_instance = TestUniV3LiquidityProvider.deploy(
            ETH_TO_SEED,
            POSITION_LOWER_TICK,
            POSITION_UPPER_TICK,
            MIN_ALLOWED_TICK,
            MAX_ALLOWED_TICK,
            {'from': deployer})

        deployer.transfer(provider_instance.address, ETH_TO_SEED)

        check_token_amounts(provider_instance)

        swapper.swapWsteth({'from': deployer, 'value': toE18(9)})


def test_wrap_eth_to_tokens_for_multiple_pool_states(deployer, wsteth_token, weth_token, TestUniV3LiquidityProvider, swapper):
    def check_for_provider(provider):
        tick = provider.getCurrentPriceTick()

        deployer.transfer(provider.address, ETH_TO_SEED)
        wsteth, weth = provider.calcTokenAmountsFromCurrentPoolSqrtPrice(ETH_TO_SEED)
        provider.wrapEthToTokens(wsteth, weth)
        
        assert wsteth_token.balanceOf(provider.address) == wsteth
        assert weth_token.balanceOf(provider.address) == weth

        print(f'tick: {tick},  eth left: {provider.balance()} wei')
        assert provider.balance() < 2
    
    for _ in range(10):
        swapper.swapWsteth({'from': deployer, 'value': toE18(11)})

        provider_instance = TestUniV3LiquidityProvider.deploy(
            ETH_TO_SEED,
            POSITION_LOWER_TICK,
            POSITION_UPPER_TICK,
            MIN_ALLOWED_TICK,
            MAX_ALLOWED_TICK,
            {'from': deployer})

        check_for_provider(provider_instance)


def test_amounts_pool_calculations_after_negative_tick_shift(deployer, provider, swapper):
    """Not a test but an illustration of deviation of amounts calculated by
       us and by pool.
    Do:
    - take current tick of the pool
    - calc token amounts by our contract
    - calc liquidity amount for these amounts of tokens
    - calc amounts of tokens by pool, given the liquidity
    - compare calculated token amounts
    - 
    - shift pool current tick
    - repeat the checks
    """
    deployer.transfer(provider.address, toE18(100000))
    eth = ETH_TO_SEED

    def check_token_amounts():
        tick = provider.getCurrentPriceTick()
        # our_amount0, our_amount1 = provider.calcTokenAmounts(tick, eth)
        our_amount0, our_amount1 = provider.calcTokenAmountsFromCurrentPoolSqrtPrice(eth)

        liquidity = provider.getLiquidityForAmounts(our_amount0, our_amount1)

        tx = provider.calcTokenAmountsByPool(liquidity)
        pool_amount0, pool_amount1 = tx.return_value

        print(
            f'Token amounts for tick {tick}\n'
            f'     our: {formatE18(our_amount0)}, {formatE18(our_amount1)}\n'
            f'    pool: {formatE18(pool_amount0)}, {formatE18(pool_amount1)}\n'
        )
    
    check_token_amounts()
    swapper.swapWsteth({'from': deployer, 'value': toE18(320)})
    check_token_amounts()


def test_mint_happy_path(deployer, provider, pool, position_manager, steth_token, wsteth_token, weth_token, lido_agent, helpers):
    deployer.transfer(provider.address, ETH_TO_SEED)

    # check there is no position we'd like to add yet
    assert 0 == get_tick_positions_liquidity(pool, provider.POSITION_LOWER_TICK())
    assert 0 == get_tick_positions_liquidity(pool, provider.POSITION_UPPER_TICK())

    tick_liquidity_before = pool.liquidity()

    with assert_leftovers_refunded(provider, steth_token, wsteth_token,
                                   weth_token, lido_agent, need_check_agent_balance=False):
        tx = provider.mint(MIN_TICK, MAX_TICK)
        print_mint_return_value(tx.return_value)
        token_id, liquidity, amount0, amount1 = tx.return_value

        helpers.assert_single_event_named('LiquidityProvided', tx, evt_keys_dict={
            'tokenId': token_id,
            'liquidity': liquidity,
            'wstethAmount': amount0,
            'wethAmount': amount1,
        })

    assert_liquidity_provided(provider, pool, position_manager, token_id, liquidity, tick_liquidity_before)

def test_mint_succeeds_if_small_negative_tick_deviation(deployer, provider, pool, position_manager, swapper):
    deployer.transfer(provider.address, ETH_TO_SEED)

    eth_to_swap = SMALL_NEGATIVE_TICK_DEVIATION_WSTETH_SWAP_ETH_AMOUNT

    tickBefore = provider.getCurrentPriceTick()
    swapper.swapWsteth({'from': deployer, 'value': eth_to_swap})
    tickAfter = provider.getCurrentPriceTick()
    tick_liquidity_before = pool.liquidity()

    print(f'tick (before/after): {tickBefore}/{tickAfter}')
    print(f'tick deviation from pool current: {abs(tickAfter - tickBefore)}')

    assert MIN_TICK <= tickAfter <= MAX_TICK

    tx = provider.mint(MIN_TICK, MAX_TICK)
    token_id, liquidity, _, _ = tx.return_value
    print_mint_return_value(tx.return_value)

    assert_liquidity_provided(provider, pool, position_manager, token_id, liquidity, tick_liquidity_before)


def test_mint_succeeds_if_small_positive_tick_deviation(deployer, provider, pool, position_manager, swapper):
    deployer.transfer(provider.address, ETH_TO_SEED)

    weth_to_swap = SMALL_POSITIVE_TICK_DEVIATION_WETH_SWAP_AMOUNT

    tickBefore = provider.getCurrentPriceTick()
    swapper.swapWeth({'from': deployer, 'value': weth_to_swap})
    tickAfter = provider.getCurrentPriceTick()
    tick_liquidity_before = pool.liquidity()

    print(f'tick (before/after): {tickBefore}/{tickAfter}')
    print(f'tick deviation from pool current: {abs(tickAfter - tickBefore)}')

    assert MIN_TICK <= tickAfter <= MAX_TICK

    tx = provider.mint(MIN_TICK, MAX_TICK)
    token_id, liquidity, _, _ = tx.return_value
    print_mint_return_value(tx.return_value)

    assert_liquidity_provided(provider, pool, position_manager, token_id, liquidity, tick_liquidity_before)


def test_mint_fails_if_large_tick_deviation(deployer, provider, swapper):
    deployer.transfer(provider.address, ETH_TO_SEED)

    # amount of token needed to swap to move the price far enough
    # the value need to be adjusted accordingly to the current pool state
    weth_to_swap = LARGE_TICK_DEVIATION_WETH_SWAP_AMOUNT

    tickBefore = provider.getCurrentPriceTick();
    swapper.swapWeth({'from': deployer, 'value': weth_to_swap})
    tickAfter = provider.getCurrentPriceTick();

    print(f'tick (before/after): {tickBefore}/{tickAfter}')

    assert tickAfter > MAX_TICK

    with reverts('TICK_DEVIATION_TOO_BIG_AT_START'):
        provider.mint(MIN_TICK, MAX_TICK)


def test_attempt_to_change_desired_tick_too_much(provider):
    with reverts('DESIRED_MIN_OR_MAX_TICK_IS_OUT_OF_ALLOWED_RANGE'):
        provider.mint(provider.MIN_ALLOWED_TICK() - 1, MAX_TICK)

    with reverts('DESIRED_MIN_OR_MAX_TICK_IS_OUT_OF_ALLOWED_RANGE'):
        provider.mint(MIN_TICK, provider.MAX_ALLOWED_TICK() + 1)


def test_wrap_eth_to_arbitrary_token_amounts(deployer, provider, wsteth_token, weth_token):
    weth_amount = toE18(20.1234)
    wsteth_amount = toE18(30.98)
    deployer.transfer(provider.address, toE18(200))

    assert 0 == wsteth_token.balanceOf(provider.address)
    provider.wrapEthToTokens(wsteth_amount, weth_amount)
    assert weth_token.balanceOf(provider.address) == weth_amount
    assert wsteth_amount == wsteth_token.balanceOf(provider.address)


def test_wrap_wsteth(deployer, wsteth_token):
    eth_amount = toE18(100)

    deployer.transfer(wsteth_token.address, eth_amount)

    wsteth = wsteth_token.balanceOf(deployer)
    assert (wsteth * wsteth_token.stEthPerToken()) / 1e18 == eth_amount


def test_get_amount_of_eth_for_wsteth(deployer, provider, wsteth_token):
    wsteth = 100 * 1e18
    eth_from_contract = provider.getAmountOfEthForWsteth(wsteth)
    eth = (wsteth_token.stEthPerToken() * wsteth) // 1e18
    assert 0 == eth_from_contract - eth
    deployer.transfer(wsteth_token.address, eth)

    assert wsteth == wsteth_token.balanceOf(deployer)


def test_calc_desired_token_amounts(provider, wsteth_token):
    eth_amount = toE18(600)
    wsteth, weth = provider.calcTokenAmounts(591, eth_amount)
    assert eth_amount == wsteth * wsteth_token.stEthPerToken() / 1e18 + weth


def test_tickMath_getTickAtSqrtRatio(provider):
    """Illustration of difference between sqrtRatio in between of ticks
    and sqrtRatio calculated from tick"""
    sqrtRatioMiddleX96 = (provider.getSqrtRatioAtTick(932) + provider.getSqrtRatioAtTick(933)) // 2
    tickForMiddle = provider.getTickAtSqrtRatio(sqrtRatioMiddleX96)
    sqrtRatioFromTickX96 = provider.getSqrtRatioAtTick(tickForMiddle)
    assert sqrtRatioFromTickX96 != sqrtRatioMiddleX96


def test_calc_amount_of_eth_for_wsteth_by_wsteth_token(deployer, wsteth_token):
    wsteth = 100 * 1e18
    eth = wsteth_token.getStETHByWstETH(wsteth)
    deployer.transfer(wsteth_token.address, eth)
    assert wsteth == wsteth_token.balanceOf(deployer) + 1  # 1 wei isn't converted to


def test_get_amount_of_eth_for_wsteth(deployer, provider, wsteth_token):
    wsteth = 100 * 1e18
    eth = provider.getAmountOfEthForWsteth(wsteth)
    deployer.transfer(wsteth_token.address, eth)
    assert wsteth == wsteth_token.balanceOf(deployer)  # the 1 wei is taken into account inside of getAmountOfEthForWsteth 


def test_close_liquidity_position(deployer, provider, position_manager, steth_token, wsteth_token, weth_token, lido_agent, swapper, helpers):
    deployer.transfer(provider.address, ETH_TO_SEED)

    agent_steth_before = steth_token.balanceOf(LIDO_AGENT)
    agent_eth_before = lido_agent.balance()

    tx = provider.mint(MIN_TICK, MAX_TICK)
    token_id, _, wsteth_provided, weth_provided = tx.return_value
    print(
        f'liquidity provided:\n'
        f'  wsteth={formatE18(wsteth_provided)}\n'
        f'  weth={formatE18(weth_provided)}\n'
    )

    assert position_manager.ownerOf(token_id) == LIDO_AGENT

    position_manager.transferFrom(LIDO_AGENT, provider, token_id, {'from': LIDO_AGENT})
    assert position_manager.ownerOf(token_id) == provider

    # swap a bit to have non-zero fees
    # swapper.swapWeth({'from': deployer, 'value': toE18(0.1)})
    # swapper.swapWeth({'from': deployer, 'value': toE18(83)})
    # TODO: Why large swap increases eth lost? How much is acceptable/expected?
    # TODO: Why colletion of fees collected unexpectedly change eth_lost?
    # TODO: Do we need closeLiquidityPosition unhappy path? priced moved out of the position? priced moved a lot?

    tx = provider.closeLiquidityPosition()
    wsteth_returned, weth_returned, wsteth_fees, weth_fees = tx.return_value
    fees_in_eth = weth_fees + wsteth_token.getStETHByWstETH(wsteth_fees)

    helpers.assert_single_event_named('LiquidityRetracted', tx, evt_keys_dict={
        'wstethAmount': wsteth_returned,
        'wethAmount': weth_returned,
        'wstethFeesCollected': wsteth_fees,
        'wethFeesCollected': weth_fees,
    })

    assert wsteth_fees == 0  # we've done no wstEth swaps thus no wsteth fees
    # assert weth_fees > 0

    # print(
    #     f'contract balances:\n'
    #     f'  wsteth={formatE18(wsteth_token.balanceOf(provider.address))}\n'
    #     f'  weth={formatE18(weth_token.balanceOf(provider.address))}\n'
    # )

    print(
        f'position liquidity withdrawn:\n'
        f'  wsteth = {formatE18(wsteth_returned)}\n'
        f'  weth = {formatE18(weth_returned)}\n'
        f'  wsteth fees = {formatE18(wsteth_fees)}\n'
        f'  weth fees = {formatE18(weth_fees)}\n'
        f'  fees in eth = {formatE18(fees_in_eth)}\n'
    )

    assert provider.balance() == 0
    assert weth_token.balanceOf(provider.address) == 0
    assert steth_token.balanceOf(provider.address) <= 1
    assert wsteth_token.balanceOf(provider.address) == 0

    eth_lost = ETH_TO_SEED - (
        lido_agent.balance() - agent_eth_before + steth_token.balanceOf(LIDO_AGENT) - agent_steth_before
    ) + fees_in_eth
    print(f'eth_lost = {formatE18(eth_lost)} ({(100 * eth_lost / ETH_TO_SEED):.2f}%)')

    assert eth_lost < 10  # 10 wei

    with reverts('ERC721: owner query for nonexistent token'):
        position_manager.ownerOf(token_id)
