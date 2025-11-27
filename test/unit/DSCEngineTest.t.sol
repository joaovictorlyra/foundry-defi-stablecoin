// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSC} from "../../script/deployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/mockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public amountToMint;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, ) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(LIQUIDATOR, STARTING_ERC20_BALANCE); // give liquidator some alternate collateral
    }

    ///////////////////////
    // constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.
        DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength.selector);
        new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(dsc)
        );
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedEth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedEth, actualWeth);
    }

    /////////////////
    // Price Tests //
    /////////////////
    function testGetUsdValue() public {
        // 15e18 * 2,000/ETH = 30,000e18
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////

function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        ranToken.mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(ranToken)));
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }
 
    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

    // deposit then redeem partial collateral and assert storage + balances update
    function testDepositAndRedeemUpdatesBalances() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 redeemAmount = 3 ether;
        dsce.redeemCollateral(weth, redeemAmount);
        vm.stopPrank();

        // check remaining collateral via getAccountInformation -> convert USD back to token amount
        ( , uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 remainingTokenAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(remainingTokenAmount, AMOUNT_COLLATERAL - redeemAmount);
        // contract should hold the remaining collateral
        assertEq(ERC20Mock(weth).balanceOf(address(dsce)), AMOUNT_COLLATERAL - redeemAmount);
    }

    // mint then burn flow: mint DSC (requires collateral) and then burn it, check accounting
    function testMintAndBurnUpdatesAccounting() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 mintAmount = 1_000 ether; // safe small amount
        dsce.mintDsc(mintAmount);
        (uint256 totalDscMintedBefore, ) = dsce.getAccountInformation(USER);
        assertEq(totalDscMintedBefore, mintAmount);
        assertEq(dsc.balanceOf(USER), mintAmount);

        // approve DSCEngine to pull DSC for burning
        dsc.approve(address(dsce), mintAmount);
        dsce.burnDsc(mintAmount);
        (uint256 totalDscMintedAfter, ) = dsce.getAccountInformation(USER);
        assertEq(totalDscMintedAfter, 0);
        assertEq(dsc.balanceOf(USER), 0);
        vm.stopPrank();
    }

    // liquidation scenario:
    // - USER deposits weth and mints some DSC
    // - LIQUIDATOR deposits wbtc and mints some DSC (so they have tokens to burn)
    // - we drop weth price only (by interacting with the weth price feed mock) to make USER undercollateralized
    // - LIQUIDATOR approves DSCEngine to pull DSC and calls liquidate -> receives collateral + bonus
    function testLiquidationFlow() public {
        // 1) USER deposits and mints (healthy initially)
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        // At $2000/ETH, 10 ETH = $20,000 collateral
        // With 50% threshold, can safely mint up to $10,000 DSC
        uint256 userMint = 5_000 ether; // mint $5,000 to be safe
        dsce.mintDsc(userMint);
        vm.stopPrank();

        // 2) LIQUIDATOR deposits different collateral (wbtc) and mints DSC to be able to burn
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(wbtc).approve(address(dsce), STARTING_ERC20_BALANCE);
        dsce.depositCollateral(wbtc, STARTING_ERC20_BALANCE);
        uint256 liquidatorMint = 5_000 ether;
        dsce.mintDsc(liquidatorMint);
        dsc.approve(address(dsce), liquidatorMint);
        vm.stopPrank();

        // 3) Crash weth price from $2000 to $900 (not as extreme)
        // This makes USER undercollateralized
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(900e8));
        // Now USER has $9,000 collateral (10 ETH * $900) but $5,000 DSC debt
        // Adjusted collateral: $9,000 * 50% = $4,500 
        // Health factor: $4,500 / $5,000 = 0.9 < 1 (undercollateralized!)

        // 4) Liquidator covers debt to improve health factor
        // Let's cover $1,000 DSC, which requires ~1.11 ETH at $900
        // With 10% bonus: 1.11 * 1.1 = ~1.22 ETH (well within the 10 ETH available)
        uint256 debtToCover = 1_000 ether;
        vm.prank(LIQUIDATOR);
        dsce.liquidate(weth, USER, debtToCover);

        // After liquidation: user's debt reduced
        (uint256 userDscAfter, ) = dsce.getAccountInformation(USER);
        assertEq(userDscAfter, userMint - debtToCover);

        // Liquidator should receive collateral (token amount + bonus)
        uint256 tokenAmount = dsce.getTokenAmountFromUsd(weth, debtToCover);
        uint256 bonus = (tokenAmount * 10) / 100;
        uint256 expectedReceived = tokenAmount + bonus;
        assertEq(ERC20Mock(weth).balanceOf(LIQUIDATOR), expectedReceived);
    }

    ///////////////////////////////
    // depositCollateralAndMintDSC Tests //
    ///////////////////////////////
    
    function testCanDepositCollateralAndMintDSC() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        
        uint256 amountToMint = 1000 ether;
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, amountToMint);
        assertGt(collateralValueInUsd, 0);
        assertEq(dsc.balanceOf(USER), amountToMint);
        vm.stopPrank();
    }

    ///////////////////////////////
    // redeemCollateralForDsc Tests //
    ///////////////////////////////
    
    function testCanRedeemCollateralForDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, 1000 ether);
        
        dsc.approve(address(dsce), 500 ether);
        dsce.redeemCollateralForDsc(weth, 2 ether, 500 ether);
        
        (uint256 totalDscMinted, ) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 500 ether);
        assertEq(ERC20Mock(weth).balanceOf(USER), 2 ether);
        vm.stopPrank();
    }

    function testRedeemCollateralForDscRevertsIfHealthFactorBroken() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, 5000 ether);
        
        dsc.approve(address(dsce), 100 ether);
        vm.expectRevert();
        dsce.redeemCollateralForDsc(weth, 9 ether, 100 ether); // trying to redeem too much
        vm.stopPrank();
    }

    ///////////////////////////////
    // mintDsc Tests //
    ///////////////////////////////
    
    function testMintDscRevertsIfHealthFactorBroken() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        
        // Try to mint too much DSC
        vm.expectRevert();
        dsce.mintDsc(15000 ether); // way over collateralization limit
        vm.stopPrank();
    }

    function testMintDscRevertsIfAmountIsZero() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
    }

    ///////////////////////////////
    // burnDsc Tests //
    ///////////////////////////////
    
    function testBurnDscRevertsIfAmountIsZero() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
    }

    function testBurnDscRevertsIfTransferFails() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(1000 ether);
        
        // Don't approve, so transfer will fail
        vm.expectRevert();
        dsce.burnDsc(500 ether);
        vm.stopPrank();
    }

    ///////////////////////////////
    // liquidate Tests //
    ///////////////////////////////
    
    function testLiquidateRevertsIfHealthFactorOk() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(1000 ether);
        vm.stopPrank();
        
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, 500 ether);
    }

    function testLiquidateRevertsIfDebtToCoverIsZero() public {
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.liquidate(weth, USER, 0);
    }

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision()));
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        uint256 expectedHealthFactor =
        dsce.calculateHealthFactor(dsce.getUsdValue(weth, AMOUNT_COLLATERAL), amountToMint);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function testLiquidateRevertsIfTokenNotAllowed() public {
        ERC20Mock fakeToken = new ERC20Mock();
        
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.liquidate(address(fakeToken), USER, 100 ether);
    }

    function testLiquidateRevertsIfHealthFactorNotImproved() public {
        // Setup user with collateral and debt
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(5000 ether);
        vm.stopPrank();

        // Setup liquidator
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(wbtc).approve(address(dsce), STARTING_ERC20_BALANCE);
        dsce.depositCollateral(wbtc, STARTING_ERC20_BALANCE);
        dsce.mintDsc(5000 ether);
        dsc.approve(address(dsce), 5000 ether);
        vm.stopPrank();

        // Crash price drastically to make user very undercollateralized
        // At $18/ETH, user has $180 collateral but $5000 debt
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(18e8));

        // Try to liquidate but the amount is so small it doesn't help
        // Even covering 100 DSC leaves them with $4900 debt vs $180 collateral
        // The bonus also drains more collateral than the debt covered
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        dsce.liquidate(weth, USER, 100 ether);
    }

    ///////////////////////////////
    // redeemCollateral Tests //
    ///////////////////////////////
    
    function testRedeemCollateralRevertsIfAmountIsZero() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
    }

    function testRedeemCollateralRevertsIfHealthFactorBroken() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(5000 ether);
        
        vm.expectRevert();
        dsce.redeemCollateral(weth, 9 ether); // would break health factor
        vm.stopPrank();
    }

    ///////////////////////////////
    // View Function Tests //
    ///////////////////////////////
    
    function testGetAccountInformation() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(1000 ether);
        
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 1000 ether);
        assertEq(collateralValueInUsd, 20000 ether); // 10 ETH * $2000
    }

    function testCalculateHealthFactor() public view {
        uint256 totalDscMinted = 1000 ether;
        uint256 collateralValueInUsd = 4000 ether;
        
        uint256 healthFactor = dsce.calculateHealthFactor(totalDscMinted, collateralValueInUsd);
        // (4000 * 50 / 100) * 1e18 / 1000 = 2e18
        assertEq(healthFactor, 2e18);
    }

    function testCalculateHealthFactorReturnsMaxIfNoDebt() public view {
        uint256 healthFactor = dsce.calculateHealthFactor(0, 1000 ether);
        assertEq(healthFactor, type(uint256).max);
    }

    function testGetHealthFactor() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(1000 ether);
        
        uint256 healthFactor = dsce.getHealthFactor(USER);
        assertGt(healthFactor, 1e18); // should be healthy
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens.length, 2);
        assertEq(collateralTokens[0], weth);
        assertEq(collateralTokens[1], wbtc);
    }

    function testGetDsc() public view {
        assertEq(dsce.getDsc(), address(dsc));
    }

    function testGetCollateralTokenPriceFeed() public view {
        assertEq(dsce.getCollateralTokenPriceFeed(weth), ethUsdPriceFeed);
        assertEq(dsce.getCollateralTokenPriceFeed(wbtc), btcUsdPriceFeed);
    }

    function testGetConstants() public view {
        assertEq(dsce.getPrecision(), 1e18);
        assertEq(dsce.getAdditionalFeedPrecision(), 1e10);
        assertEq(dsce.getLiquidationThreshold(), 50);
        assertEq(dsce.getLiquidationBonus(), 10);
        assertEq(dsce.getLiquidationPrecision(), 100);
        assertEq(dsce.getMinHealthFactor(), 1e18);
    }

    ///////////////////////////////
    // Multiple Collateral Tests //
    ///////////////////////////////
    
    function testDepositMultipleCollateralTypes() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), 5 ether);
        dsce.depositCollateral(weth, 5 ether);
        
        // Mint some wbtc for user
        ERC20Mock(wbtc).mint(USER, 2 ether);
        ERC20Mock(wbtc).approve(address(dsce), 2 ether);
        dsce.depositCollateral(wbtc, 2 ether);
        vm.stopPrank();
        
        (, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        // 5 ETH * $2000 + 2 BTC * $1000 = $10,000 + $2,000 = $12,000
        assertEq(collateralValueInUsd, 12000 ether);
    }

    function testGetAccountCollateralValueWithMultipleTokens() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), 3 ether);
        dsce.depositCollateral(weth, 3 ether);
        
        ERC20Mock(wbtc).mint(USER, 1 ether);
        ERC20Mock(wbtc).approve(address(dsce), 1 ether);
        dsce.depositCollateral(wbtc, 1 ether);
        vm.stopPrank();
        
        uint256 totalValue = dsce.getAccountCollateralValue(USER);
        // 3 ETH * $2000 + 1 BTC * $1000 = $7,000
        assertEq(totalValue, 7000 ether);
    }

    ///////////////////////////////
    // Edge Cases & Additional Coverage //
    ///////////////////////////////

    function testDepositCollateralEmitsEvent() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        
        vm.expectEmit(true, true, false, true);
        emit DSCEngine.CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRedeemCollateralEmitsEvent() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        
        vm.expectEmit(true, true, true, true);
        emit DSCEngine.CollateralRedeemed(USER, USER, weth, 2 ether);
        dsce.redeemCollateral(weth, 2 ether);
        vm.stopPrank();
    }

    function testLiquidationPaysIncentive() public {
        // Setup scenario similar to testLiquidationFlow
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(5000 ether);
        vm.stopPrank();

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(wbtc).approve(address(dsce), STARTING_ERC20_BALANCE);
        dsce.depositCollateral(wbtc, STARTING_ERC20_BALANCE);
        dsce.mintDsc(5000 ether);
        dsc.approve(address(dsce), 5000 ether);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(900e8));

        uint256 debtToCover = 1000 ether;
        uint256 liquidatorBalanceBefore = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        
        vm.prank(LIQUIDATOR);
        dsce.liquidate(weth, USER, debtToCover);
        
        uint256 liquidatorBalanceAfter = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 received = liquidatorBalanceAfter - liquidatorBalanceBefore;
        
        // Should receive more than just the debt covered (due to 10% bonus)
        uint256 tokenAmount = dsce.getTokenAmountFromUsd(weth, debtToCover);
        assertGt(received, tokenAmount);
    }

    function testCannotDepositZeroCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCannotRedeemZeroCollateral() public depositedCollateral {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
    }

    function testDepositCollateralRevertsOnTransferFailure() public {
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL); // No approval = transfer fails
        vm.stopPrank();
    }

    function testHealthFactorCanImprove() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(5000 ether);
        
        uint256 healthFactorBefore = dsce.getHealthFactor(USER);
        
        // Add more collateral to improve health factor
        ERC20Mock(weth).mint(USER, 5 ether);
        ERC20Mock(weth).approve(address(dsce), 5 ether);
        dsce.depositCollateral(weth, 5 ether);
        
        uint256 healthFactorAfter = dsce.getHealthFactor(USER);
        assertGt(healthFactorAfter, healthFactorBefore);
        vm.stopPrank();
    }

    function testMultipleMintAndBurnCycles() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Mint cycle 1
        dsce.mintDsc(1000 ether);
        assertEq(dsc.balanceOf(USER), 1000 ether);

        // Mint cycle 2
        dsce.mintDsc(500 ether);
        assertEq(dsc.balanceOf(USER), 1500 ether);

        // Burn cycle 1
        dsc.approve(address(dsce), 800 ether);
        dsce.burnDsc(800 ether);
        assertEq(dsc.balanceOf(USER), 700 ether);

        // Burn cycle 2
        dsc.approve(address(dsce), 700 ether);
        dsce.burnDsc(700 ether);
        assertEq(dsc.balanceOf(USER), 0);
        
        vm.stopPrank();
    }

    function testCanRedeemAllCollateralWithNoDebt() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        
        // Redeem all without minting any DSC
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        
        assertEq(ERC20Mock(weth).balanceOf(USER), AMOUNT_COLLATERAL);
        (, uint256 collateralValue) = dsce.getAccountInformation(USER);
        assertEq(collateralValue, 0);
        vm.stopPrank();
    }
}