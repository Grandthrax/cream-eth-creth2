from itertools import count
from brownie import Wei, reverts
from useful_methods import stateOfStrat, stateOfVault, deposit,wait, withdraw, harvest,assertCollateralRatio
import brownie



    

def test_sweep(web3,strategy, dai,cdai, gov, comp):
    with brownie.reverts("!want"):
        strategy.sweep(dai, {"from": gov})

    with brownie.reverts("!protected"):
        strategy.sweep(comp, {"from": gov})

    with brownie.reverts("!protected"):
        strategy.sweep(cdai, {"from": gov})

    cbat = "0x6c8c6b02e7b2be14d4fa6022dfd6d75921d90e4e"

    strategy.sweep(cbat, {"from": gov})

    

def test_apr_creth(web3, chain, cream, vault, enormousrunningstrategy, whale, gov, currency, strategist):
    enormousrunningstrategy.setProfitFactor(1, {"from": strategist} )
    assert(enormousrunningstrategy.profitFactor() == 1)

    enormousrunningstrategy.setMinCompToSell(1, {"from": gov})
    enormousrunningstrategy.setMinWant(0, {"from": gov})
    assert enormousrunningstrategy.minCompToSell() == 1

    startingBalance = vault.totalAssets()

    stateOfStrat(enormousrunningstrategy, currency, cream)
    stateOfVault(vault, enormousrunningstrategy)

    for i in range(10):
        
        waitBlock = 100
        print(f'\n----wait {waitBlock} blocks----')
        wait(waitBlock, chain)
        
        harvest(enormousrunningstrategy, strategist, vault)
        stateOfStrat(enormousrunningstrategy, currency, cream)
        stateOfVault(vault, enormousrunningstrategy)
        #print(vault.creditAvailable(enormousrunningstrategy)/1e18)

        profit = (vault.totalAssets() - startingBalance).to('ether')
        strState = vault.strategies(enormousrunningstrategy)
        totalReturns = strState[6]
        totaleth = totalReturns.to('ether')
        print(f'Real Profit: {profit:.5f}')
        difff= profit-totaleth
        print(f'Diff: {difff}')

        blocks_per_year = 2_300_000
        assert startingBalance != 0
        time =(i+1)*waitBlock
        assert time != 0
        apr = (totalReturns/startingBalance) * (blocks_per_year / time)
        print(f'implied apr: {apr:.8%}')
    vault.withdraw(vault.balanceOf(whale), {'from': whale})
    stateOfStrat(enormousrunningstrategy, currency, cream)
    stateOfVault(vault, enormousrunningstrategy)




def test_getting_too_close_to_liq(web3, chain, comp, vault, largerunningstrategy, whale, gov, dai):

    stateOfStrat(largerunningstrategy, dai, comp)
    stateOfVault(vault, largerunningstrategy)
    largerunningstrategy.setCollateralTarget(Wei('0.74999999999 ether'), {"from": gov} )
    deposit(Wei('1000 ether'), whale, dai, vault)

    balanceBefore = vault.totalAssets()
    collat = 0

    while collat < largerunningstrategy.collateralTarget() / 1.001e18:

        largerunningstrategy.harvest({'from': gov})
        deposits, borrows = largerunningstrategy.getCurrentPosition()
        collat = borrows / deposits

        stateOfStrat(largerunningstrategy, dai, comp)
        stateOfVault(vault, largerunningstrategy)
        assertCollateralRatio(largerunningstrategy)

    print(largerunningstrategy.getblocksUntilLiquidation())
    assert largerunningstrategy.tendTrigger(1e18) == True
    largerunningstrategy.tend({'from': gov})
    assertCollateralRatio(largerunningstrategy)
    stateOfStrat(largerunningstrategy, dai, comp)
    stateOfVault(vault, largerunningstrategy)

    largerunningstrategy.setCollateralTarget(Wei('0.73 ether'), {"from": gov} )
    assert largerunningstrategy.tendTrigger(1e18) == False
    largerunningstrategy.tend({'from': gov})
    assertCollateralRatio(largerunningstrategy)
    stateOfStrat(largerunningstrategy, dai, comp)
    stateOfVault(vault, largerunningstrategy)



def test_harvest_trigger(web3, chain, comp, vault, largerunningstrategy, whale, gov, dai):
    largerunningstrategy.setMinCompToSell(Wei('0.01 ether'), {"from": gov} )

    assert largerunningstrategy.harvestTrigger(Wei('1 ether')) == False

    #sleep a day
    chain.sleep(86401)
    chain.mine(1)
    assert largerunningstrategy.harvestTrigger(Wei('1 ether')) == True

    largerunningstrategy.harvest({"from": gov})

    assert largerunningstrategy.harvestTrigger(Wei('0.0002 ether')) == False
    deposit(Wei('100 ether'), whale, dai, vault)
    assert largerunningstrategy.harvestTrigger(Wei('0.0002 ether')) == True
    assert largerunningstrategy.harvestTrigger(Wei('0.006 ether')) == False

    largerunningstrategy.harvest({"from": gov})

    times = 0
    while largerunningstrategy.harvestTrigger(Wei('0.0002 ether')) == False:
        wait(50, chain)
        print(largerunningstrategy.predictCompAccrued().to('ether'), ' comp prediction')
        times = times + 1
        assert times < 10

    assert times > 3
    
    largerunningstrategy.harvest({"from": gov})

