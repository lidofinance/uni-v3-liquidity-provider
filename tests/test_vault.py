import pytest
from brownie import Contract, ZERO_ADDRESS, chain, reverts, ETH_ADDRESS

ETH_TO_USE = 100 * 10e18
LIQUIDITY = 30 * 10e18

def test_getAmountOfEthForWsteth(theContract):
    r = theContract.getAmountOfEthForWsteth(1e18) / 1e18
    assert 1.0 < r < 2.0

def test_calcSlippage(theContract):
    slippage = theContract.calcSlippage(1059942733650492541866266407236800000, 1060801733107162407)
    assert slippage < 50

    slippage = theContract.calcSlippage(1055542733650492541866266407236800000, 1060801733107162407)
    assert slippage > 50

def test_seed(deployer, theContract, steth_token, helpers):
    deployer.transfer(theContract.address, ETH_TO_USE)

    balance = steth_token.balanceOf(theContract.address)
    print(f"{balance=}")

    currentTickBefore = theContract.getCurrentPriceTick();
    spotPrice = theContract.getSpotPrice()
    print(f'spot price = {spotPrice}')

    tx = theContract.seed(LIQUIDITY)

    print([x / 10**18 for x in tx.return_value])

    currentTickAfter = theContract.getCurrentPriceTick();

    spotPrice = theContract.getSpotPrice()
    print(f'new spot price = {spotPrice}')

    print(f'currentPriceTick (before/after): {currentTickBefore}/{currentTickAfter}')

    assert False
