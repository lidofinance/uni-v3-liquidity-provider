from brownie import Contract
from math import floor


def toE18(x):
    return round(x * 1e18)

def formatE18(num):
    floating_num = num / 1e18
    return f'{floating_num:.4f} ({floor(num)})'

def get_balance(address):
    return Contract.from_abi("Foo", address, "").balance()

def get_diff_in_percent(base, value):
    return (value - base) / base * 100
