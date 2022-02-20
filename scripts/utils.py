from brownie import Contract


def toE18(x):
    return round(x * 1e18)

def formatE18(num):
    floating_num = num / 1e18
    return f'{floating_num:.4f} ({num})'

def get_balance(address):
    return Contract.from_abi("Foo", address, "").balance()