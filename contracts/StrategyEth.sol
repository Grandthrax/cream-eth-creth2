// SPDX-License-Identifier: MIT

pragma experimental ABIEncoderV2;
pragma solidity 0.6.12;

import "@openzeppelinV3/contracts/token/ERC20/IERC20.sol";
import "@openzeppelinV3/contracts/math/SafeMath.sol";
import "@openzeppelinV3/contracts/math/Math.sol";
import "@openzeppelinV3/contracts/utils/Address.sol";
import "@openzeppelinV3/contracts/token/ERC20/SafeERC20.sol";
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";

import "../../interfaces/yearn/Vault.sol";
import "../../interfaces/uniswap/Uni.sol";

import "./Interfaces/Compound/CErc20I.sol";
import "./Interfaces/Compound/ComptrollerI.sol";

contract StrategyEthCreth2 is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public weth;
    address public creth2;
    address public yvCreth2;
    address public unirouter;
    string public constant override name = "StrategyEthCreth2";

    uint256 public ethToCreth2 = 50000;
    uint256 public denominator = 100000;

    uint256

    constructor(
        address _vault,
        address _weth,
        address _creth,
        address _creth2,
        address _yvCreth2,
        address _unirouter
    ) public BaseStrategy(_vault) {
        weth = _weth;
        creth = _creth;
        creth2 = _creth2
        yvCreth2 = _yvCreth2;
        unirouter = _unirouter;

        IERC20(creth2).safeApprove(yvCreth2, uint256(-1));
        IERC20(creth).safeApprove(creth, uint256(-1));
        IERC20(creth2).safeApprove(creth2, uint256(-1));
    }

    function protectedTokens() internal override view returns (address[] memory) {
        address[] memory protected = new address[](3);
        // want is eth, which is protected by default
        protected[0] = creth2;
        protected[1] = creth;
        protected[2] = yvCreth2;
        return protected;
    }

    // todo: this
    function estimatedTotalAssets() public override view returns (uint256) {
        uint256 underlying = underlyingBalanceStored();
        return balanceOfWant().add(balanceOfStake()).add(balanceOfAsset());
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment) {
        // We might need to return want to the vault
        if (_debtOutstanding > 0) {
            uint256 _amountFreed = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }

        uint256 balanceOfWantBefore = balanceOfWant();

        // in case there's any stray eth, this will sweep for want
        uint256 ethBalance = address(this).balance();
        if (assetBalance > 0) {
            ethToWeth(assetBalance);
        }

        _profit = balanceOfWant().sub(balanceOfWantBefore);
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        //emergency exit is dealt with in prepareReturn
        if (emergencyExit) {
            return;
        }

        // turn eth to weth - just so that funds are held in weth instead of eth.
        uint256 _ethBalance = address(this).balance;
        if (_ethBalance > 0) {
            swapEthtoWeth(_ethBalance);
        }

        uint256 _wantAvailable = balanceOfWant().sub(_debtOutstanding);
        if (_wantAvailable > 0) {
             // turn weth to Eth
            swapWethtoEth(_wantAvailable);
            uint256 _availableFunds = address(this).balance;

            CErc20I(creth).mint{value: _availableFunds}(_availableFunds);
            uint256 borrowLimit = IERC20(creth).balanceOf(address(this)).mul(ethToCreth2).div(denominator).mul(creth2Value());
            CErc20I(creth2).borrow(borrowLimit);

            Vault(yvCreth2).depositAll();
        }

    }

    function exitPosition(uint256 _debtOutstanding)
        internal
        override
        returns (
          uint256 _profit,
          uint256 _loss,
          uint256 _debtPayment
        )
    {

        Vault(yvCreth2).withdrawAll();
        uint256 assetBalance = IERC20(creth2).balanceOf(address(this));
        CErc20I(creth2).repayBorrow(assetBalance);
        uint256 crethBalance = IERC20(creth).balanceOf(address(this));
        CErc20I(creth).redeem(crethBalance);
        uint256 ethBalance = address(this).balance();
        swapEthtoWeth(ethBalance);
        return prepareReturn(_debtOutstanding);
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _amountFreed) {
        if (balanceOfWant() < _amountNeeded) {
            // We need to sell stakes to get back more want
            _withdrawSome(_amountNeeded.sub(balanceOfWant()));
        }

        _amountFreed = balanceOfWant();
    }

    /*
     * _amount is in terms of Weth and needs to be converted
     * Logic needs to account for the LTV of weth:creth2 to know how much to withdraw from yvCreth2
     */
    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        uint256 wantValue = (_amount).mul(creth2Value());
        uint256 creth2LTV = ethToCreth2.div(denominator);
        uint256 vaultShare = Vault(yvCreth2).getPricePerFullShare();
        uint256 vaultWithdraw = wantValue.div(vaultShare).mul(creth2LTV);
        Vault(yvCreth2).withdraw(vaultWithdraw);
        // now repay creth2 balance.
        uint256 assetBalance = IERC20(creth2).balanceOf(address(this));
        CErc20I(creth2).repayBorrow(assetBalance);
        // now withdraw _amount
        CErc20I(creth).redeem(_amount);
        uint256 ethBalance = address(this).balance();
        swapEthtoWeth(ethBalance);
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        want.transfer(_newStrategy, balanceOfWant());
        IERC20(creth).transfer(_newStrategy, IERC20(creth).balanceOf(address(this)));
        IERC20(creth2).transfer(_newStrategy, IERC20(creth2).balanceOf(address(this)));
        IERC20(yvCreth2).transfer(_newStrategy, IERC20(yvCreth2).balanceOf(address(this)));
    }

    // todo: this. Needs creth2Rate function
    function balanceOfDeposit() public view returns (uint256) {
        uint256 assetBalance = IERC20(creth).balanceOf(address(this));
        uint256 creth2Rate = creth2Value();
        return assetBalance.mul(creth2Rate);
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceOfStake() public view returns (uint256) {
        uint256 vaultShares = IERC20(yvCreth2).balanceOf(address(this));
        uint256 vaultPrice = Vault(yvCreth2).getPricePerFullShare();
        return vaultBalance = vaultShares.mul(vaultPrice);
    }

    // turns ether into weth
    function swapEthtoWeth(uint256 convert) internal {
        if (convert > 0) {
            IWeth(weth).deposit{value: convert}();
        }
    }

    // turns weth into ether
    function swapWethtoEth(uint256 convert) internal {
        if (convert > 0) {
            IWeth(weth).withdraw(convert);
        }
    }

    //todo: this function will return ratio of creth2:eth
    function creth2Value() return (uint256) {

}

}
