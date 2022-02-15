from eth_account import Account
import pytest
from brownie import Contract, accounts, ZERO_ADDRESS, chain, reverts, ETH_ADDRESS
from conftest import WETH_TOKEN

ETH_TO_USE = 100 * 1e18
LIQUIDITY = 300 * 1e18

LIDO_AGENT = "0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c"


def get_balance(address):
    return Contract.from_abi("Foo", address, "").balance()


def test_getAmountOfEthForWsteth(the_contract):
    r = the_contract.getAmountOfEthForWsteth(1e18) / 1e18
    assert 1.0 < r < 2.0


def test_withdrawERC20(deployer, the_contract, weth_token):
    amount = 1e10

    with reverts('ONLY_ADMIN_OR_DAO_CAN'):
        the_contract.withdrawERC20(WETH_TOKEN, {'from': accounts[2]})

    weth_token.deposit({'from': deployer, 'value': amount})
    weth_token.transfer(the_contract.address, amount, {'from': deployer})
    assert weth_token.balanceOf(the_contract.address) == amount
    assert weth_token.balanceOf(deployer) == 0

    agent_balance_before = weth_token.balanceOf(LIDO_AGENT)
    the_contract.withdrawERC20(WETH_TOKEN)
    assert weth_token.balanceOf(LIDO_AGENT) == agent_balance_before + amount


def test_withdrawETH(deployer, the_contract):
    balance_before = get_balance(LIDO_AGENT)
    amount = 1e18

    with reverts('ONLY_ADMIN_OR_DAO_CAN'):
        the_contract.withdrawETH({'from': accounts[2]})

    deployer.transfer(the_contract.address, amount)
    the_contract.withdrawETH()

    deployer.transfer(the_contract.address, amount)
    the_contract.withdrawETH({'from': LIDO_AGENT})

    assert balance_before + 2 * amount == get_balance(LIDO_AGENT)


def disable_test_withdrawERC721(deployer, the_contract):
    assert False


def test_priceDiffToChainlink(the_contract):
    diff = the_contract.calcSpotToChainlinkPriceAbsDiff(1059942733650492541866266407236800000, 1060801733107162407)
    assert diff < 50

    diff = the_contract.calcSpotToChainlinkPriceAbsDiff(1055542733650492541866266407236800000, 1060801733107162407)
    assert diff > 50


def test_exchangeForTokens(deployer, the_contract, wsteth_token):
    assert wsteth_token.balanceOf(the_contract.address) == 0
    deployer.transfer(the_contract.address, ETH_TO_USE)
    wsteth_needed = 1e16

    eth_for_wsteth = the_contract.getAmountOfEthForWsteth(wsteth_needed)
    the_contract.exchangeForTokens(eth_for_wsteth, 0)
    assert wsteth_token.balanceOf(the_contract.address) == wsteth_needed


def test_seed_happy_path(deployer, the_contract, steth_token, helpers):
    deployer.transfer(the_contract.address, ETH_TO_USE)

    balance = steth_token.balanceOf(the_contract.address)
    print(f"{balance=}")

    currentTickBefore = the_contract.getCurrentPriceTick();
    spotPrice = the_contract.getSpotPrice()
    print(f'spot price = {spotPrice}')

    tx = the_contract.seed(LIQUIDITY)
    # TODO: check pool size / position changed

    # print([x / 10**18 for x in tx.return_value])

    currentTickAfter = the_contract.getCurrentPriceTick();

    spotPrice = the_contract.getSpotPrice()
    print(f'new spot price = {spotPrice}')

    print(f'currentPriceTick (before/after): {currentTickBefore}/{currentTickAfter}')



def test_seed_spot_prices_too_far_at_start(deployer, the_contract, the_pool, swapper):
    weth_to_swap = 100e18  # will cause ~ 63 movement shift at the time or writing the test
    currentTickBefore = the_contract.getCurrentPriceTick();
    swapper.swapWeth({'from': deployer, 'value': weth_to_swap})
    currentTickAfter = the_contract.getCurrentPriceTick();
    print(f'currentPriceTick (before/after): {currentTickBefore}/{currentTickAfter}')

    deployer.transfer(the_contract.address, ETH_TO_USE)
    
    with reverts('TICK_MOVEMENT_TOO_LARGE_AT_START'):
        the_contract.seed(LIQUIDITY)


def test_seed_success_if_small_price_tick_movement(deployer, the_contract, the_pool, swapper):
    weth_to_swap = 30e18  # will cause ~ 18 ticks movement at the time or writing the test

    currentTickBefore = the_contract.getCurrentPriceTick();
    swapper.swapWeth({'from': deployer, 'value': weth_to_swap})
    currentTickAfter = the_contract.getCurrentPriceTick();

    print(f'currentPriceTick (before/after): {currentTickBefore}/{currentTickAfter}')

    deployer.transfer(the_contract.address, ETH_TO_USE)
    
    the_contract.seed(LIQUIDITY)
    # TODO: check pool size / position changed


def test_seed_fails_due_to_chainlink_price_moved_much():
    # TODO: need to mock chainlink for this
    pass