// It will narrow down the way we call the functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/mockV3Aggregator.sol";

// Price feed
// wbtc
//

contract Handler is Test {
    // What is this supposed to do?
    // Hey, don't call redeemCollateral unless there is collateral to redeem
    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;

    ERC20Mock public weth;
    ERC20Mock public wbtc;

    uint256 public timesMintIsCalled;
    address[] public userWithCollateralDeposited;
    MockV3Aggregator public ethUsdPricefeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc;


        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPricefeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (userWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = userWithCollateralDeposited[addressSeed % userWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);
    
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        if(maxDscToMint < 0){
            return;
        }
    
        amount = bound(amount, 0, uint256(maxDscToMint));
        if(amount == 0){
            return;
        }
    
        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    // RedeemCollateral
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getcollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE); // Between 1 and 1000 tokens

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        // double push
        userWithCollateralDeposited.push(msg.sender);
    }

    // Helper Function
    function _getcollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } 
        return wbtc;    
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getcollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(address(collateral), msg.sender);
    
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if(amountCollateral == 0){
            return;
        }

        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    function updateCollateralPrice(uint96 newPrice) public {
        int256 newPriceInt = int256(uint256(newPrice));
        ethUsdPricefeed.updateAnswer(newPriceInt);
        
    }
 
    function invariant_gettersShouldNotRevert() public view {
        dsce.getAccountCollateralValue(msg.sender);
        dsce.getAccountInformation(msg.sender);
        dsce.getAdditionalFeedPrecision();
        dsce.getCollateralBalanceOfUser(msg.sender, address(weth));
        dsce.getCollateralBalanceOfUser(msg.sender, address(wbtc));
        dsce.getCollateralTokenPriceFeed(address(weth));
        dsce.getCollateralTokenPriceFeed(address(wbtc));
        dsce.getCollateralTokens();
        dsce.getDsc();
        dsce.getHealthFactor(msg.sender);
        dsce.getLiquidationBonus();
        dsce.getLiquidationPrecision();
        dsce.getLiquidationThreshold();
        dsce.getMinHealthFactor();
        dsce.getPrecision();
        dsce.getTokenAmountFromUsd(address(weth), 1e18);
        dsce.getTokenAmountFromUsd(address(wbtc), 1e18);
        dsce.getUsdValue(address(weth), 1e18);
        dsce.getUsdValue(address(wbtc), 1e18);
        dsce.calculateHealthFactor(1e18, 1e18);
    }
}
