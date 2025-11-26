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

    function testDepositCollateralAndMintDscRevertsIfBreaksHealthFactor() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        
        // Calculate amount that would break health factor
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint256 collateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        
        // Try to mint MORE than allowed by health factor
        // With 50% threshold: can mint max $10,000 from $20,000 collateral
        // So minting $10,001 should fail
        uint256 amountToMint = collateralValueInUsd + 1 ether;
        
        uint256 expectedHealthFactor = 
            dsce.calculateHealthFactor(amountToMint, collateralValueInUsd);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor
            )
        );
        dsce.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }
}