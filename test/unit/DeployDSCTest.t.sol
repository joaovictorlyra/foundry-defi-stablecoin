// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/deployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

contract DeployDSCTest is Test {
    DeployDSC deployer;

    function setUp() public {
        deployer = new DeployDSC();
    }

    function testDeployReturnsValidContracts() public {
        (DecentralizedStableCoin dsc, DSCEngine engine, HelperConfig config) = deployer.run();
        
        // Verify contracts are deployed
        assertTrue(address(dsc) != address(0), "DSC should be deployed");
        assertTrue(address(engine) != address(0), "Engine should be deployed");
        assertTrue(address(config) != address(0), "Config should be deployed");
    }

    function testDSCOwnershipTransferredToEngine() public {
        (DecentralizedStableCoin dsc, DSCEngine engine,) = deployer.run();
        
        // DSC owner should be the engine
        assertEq(dsc.owner(), address(engine), "DSC owner should be the engine");
    }

    function testEngineHasCorrectDSCAddress() public {
        (DecentralizedStableCoin dsc, DSCEngine engine,) = deployer.run();
        
        assertEq(engine.getDsc(), address(dsc), "Engine should reference correct DSC");
    }

    function testEngineHasCorrectCollateralTokens() public {
        (, DSCEngine engine, HelperConfig config) = deployer.run();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc,) = 
            config.activeNetworkConfig();
        
        address[] memory collateralTokens = engine.getCollateralTokens();
        
        assertEq(collateralTokens.length, 2, "Should have 2 collateral tokens");
        assertEq(collateralTokens[0], weth, "First token should be WETH");
        assertEq(collateralTokens[1], wbtc, "Second token should be WBTC");
    }

    function testEngineHasCorrectPriceFeeds() public {
        (, DSCEngine engine, HelperConfig config) = deployer.run();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc,) = 
            config.activeNetworkConfig();
        
        assertEq(
            engine.getCollateralTokenPriceFeed(weth), 
            wethUsdPriceFeed, 
            "WETH price feed should match"
        );
        assertEq(
            engine.getCollateralTokenPriceFeed(wbtc), 
            wbtcUsdPriceFeed, 
            "WBTC price feed should match"
        );
    }

    function testDeploymentOnAnvilNetwork() public {
        // This will use the default Anvil network from HelperConfig
        vm.chainId(31337); // Anvil chain ID
        
        (DecentralizedStableCoin dsc, DSCEngine engine, HelperConfig config) = deployer.run();
        
        assertTrue(address(dsc) != address(0));
        assertTrue(address(engine) != address(0));
        
        // Verify mocks were created
        (address wethUsdPriceFeed,,address weth,,) = config.activeNetworkConfig();
        assertTrue(wethUsdPriceFeed != address(0), "Mock price feed should exist");
        assertTrue(weth != address(0), "Mock WETH should exist");
    }

    function testTokenAddressesAndPriceFeedsMatch() public {
        (, DSCEngine engine, HelperConfig config) = deployer.run();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc,) = 
            config.activeNetworkConfig();
        
        address[] memory collateralTokens = engine.getCollateralTokens();
        
        // Verify each token has a corresponding price feed
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            address priceFeed = engine.getCollateralTokenPriceFeed(collateralTokens[i]);
            assertTrue(priceFeed != address(0), "Each token should have a price feed");
        }
    }
}
