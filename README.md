# Purpose
The goal of this contract is to deposit liquidity on contract's balance into UniV3 wstETH/WETH Pool.
It aims to avoid loosing more than X% (presumably 0.5%, but it's a subject of change in config.py) on slippage & protected from the frontrun.
In case slippage is higher than X%, or the price is more than X% off 
the "chainlink-based wstETH price" (steth price feed data * wstETH/stETH ratio), or the ratio between assets is off — revert the tx.

Variable "X" above is specified as price range during providing liquidity. And the price range is limited by a wide range which is set upon contract deployment. It's done so to make DAO get sure that admin cannot specify any stupid or malicious price range for slippage/frontrun protection.

If the liquidity provision ended successfully, send the position NFT & the remainder of the assets to the Lido DAO Agent contract.

Contract would wield ETHs, so in order to provide liquidity the portion of funds are to be converted to wstETH first.

Both methods for seeding liquidity & returning the tokens are guarded: only DAO agent & contract admin are able to call them.

# Dependencies
The only dependency is eth-brownie >= 1.17.2 which is likely already installed globally, so there this no package manager files in the repo.

# Contract interface
In happy path scenario there is a single function which is supposed to be called after the deployment:

    /**
     * Update desired tick and provide liquidity to the pool
     * 
     * @param _minTick Min pool tick for which liquidity is to be provided
     * @param _maxTick Max pool tick for which liquidity is to be provided
     */
    function mint(int24 _minTick, int24 _maxTick) external authAdminOrDao() returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 wstethAmount,
        uint256 wethAmount);

A tick is an integer which corresponds to some value on a grid of wsteth/weth prices. The tick can easily be calculated from the price. For more details see [here](https://uniswap.org/whitepaper-v3.pdf) at section 6.1.

**NB**: Seeding liquidity is called "minting" throughout the README because the liquidity is provided by means of UniV3 NonfungiblePositionManager which mints NFT to the position owner.

# Parameters
Parameters are to be specified in `config.py` file before deployment and before providing liquidity. One part of the parameters are related to the deployment and the other to the liquidity minting.

## Deployment parameters
Section "Parameters used for contract deployment" of `config.py`. These parameters are to be specified right before contract deployment depending on current pool state.

`ETH_TO_SEED` amount of eth on the contract to be used for seeding the liquidity.

`POSITION_LOWER_TICK` and `POSITION_UPPER_TICK` liquidity position range. For the details on how the parameters are supposed to be specified see [the snapshot voting](https://snapshot.org/#/lido-snapshot.eth/proposal/0xefb45e54b77d782e0ae3cebd76e0b1bedcc70778289fd561bc0d063eb3598dae).

`MIN_ALLOWED_TICK` and `MAX_ALLOWED_TICK` range of prices in pool ticks within which admin or the dao will be able to set smaller range of acceptable wsteth/weth price for providing liquidity 

## Minting liquidity
Section "Parameters used for liquidity minting" of `config.py`.

`MIN_TICK` and `MAX_TICK` pool price range to be used for slippage/frontrun protection.

# Scripts

## Explore pool state
Script `scripts/scout.py` looks up current pool parameters.

    brownie run scripts/scout.py main --network development

## Deployment
Script `scripts/deploy.py` deploys the contract and sets multisig address as contract address. All the parameters and multisig address is taken from `config.py`. For automatic source code verification on Etherscan specify your token: `export ETHERSCAN_TOKEN=<YourToken>`.

    brownie run scripts/deploy.py main <brownie account id> <priority_fee, eg "2 wei"> <max_fee, eg "300 gwei"> --network <target network>

## Acceptance test
Is supposed to be run twice:
- after the deployment and seeding the contract with needed amount of ether;

        brownie run scripts/acceptance_test.py main --network development

- after providing the liquidity for the pool

        brownie run scripts/acceptance_test.py main <token_id> <liquidity> --network development

    where `<token_id>` and `<liquidity>` are to be taken from event `LiquidityProvided` created during liquidity provision

## Seed the liquidity
Script `scripts/mint.py` calls contract's `mint()` with parameters specified in `config.py`.

It can either:

- create transaction calldata (for sending from multisig)

        brownie run scripts/mint.py main False --network <target network>

- execute the transaction

        brownie run scripts/mint.py main True <brownie account id> --network <target network>
