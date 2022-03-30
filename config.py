from scripts.utils import *

# #######################################
# Parameters used for contract deployment
# #######################################
ETH_TO_SEED = toE18(600)
MIN_ALLOWED_TICK = 637 - 100
MAX_ALLOWED_TICK = 637 + 100


# #####################################
# Parameters used for liquidity minting
# #####################################
MIN_TICK = 637 - 50
MAX_TICK = 637 + 50


# #####################################
# Parameters used for TESTING
# #####################################

# TODO: swap size for small tick deviation
# TODO: swap size for large tick deviation


# Addesses used in testing
POOL = "0xD340B57AAcDD10F96FC1CF10e15921936F41E29c"
STETH_TOKEN = "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84"
WETH_TOKEN = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
WSTETH_TOKEN = "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0"
LIDO_AGENT = "0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c"
NONFUNGIBLE_POSITION_MANAGER = "0xC36442b4a4522E871399CD717aBDD847Ab11FE88"
