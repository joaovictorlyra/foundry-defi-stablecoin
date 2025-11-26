// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract HelperConfigTest is Test {
    HelperConfig config;

    function setUp() public {
        config = new HelperConfig();
    }

    function testAnvilConfigCreated() public {
        vm.chainId(31337);
        HelperConfig newConfig = new HelperConfig();
        
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) = 
            newConfig.activeNetworkConfig();
        
        assertTrue(wethUsdPriceFeed != address(0), "WETH price feed should exist");
        assertTrue(wbtcUsdPriceFeed != address(0), "WBTC price feed should exist");
        assertTrue(weth != address(0), "WETH should exist");
        assertTrue(wbtc != address(0), "WBTC should exist");
        assertEq(deployerKey, newConfig.DEFAULT_ANVIL_PRIVATE_KEY());
    }

    function testSepoliaConfigHasCorrectAddresses() public {
        vm.chainId(11155111);
        HelperConfig sepoliaConfig = new HelperConfig();
        
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) = 
            sepoliaConfig.activeNetworkConfig();
        
        assertEq(wethUsdPriceFeed, 0x694AA1769357215DE4FAC081bf1f309aDC325306);
        assertEq(wbtcUsdPriceFeed, 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43);
        assertEq(weth, 0xdd13E55209Fd76AfE204dBda4007C227904f0a81);
        assertEq(wbtc, 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063);
        assertEq(deployerKey, 0);
    }

    function testAnvilMockPriceFeedsWork() public {
        vm.chainId(31337);
        HelperConfig anvilConfig = new HelperConfig();
        
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed,,,) = 
            anvilConfig.activeNetworkConfig();
        
        MockV3Aggregator ethFeed = MockV3Aggregator(wethUsdPriceFeed);
        MockV3Aggregator btcFeed = MockV3Aggregator(wbtcUsdPriceFeed);
        
        assertEq(ethFeed.decimals(), 8);
        assertEq(btcFeed.decimals(), 8);
        assertEq(ethFeed.latestAnswer(), anvilConfig.ETH_USD_PRICE());
        assertEq(btcFeed.latestAnswer(), anvilConfig.WBTC_USD_PRICE());
    }

    function testAnvilMockTokensAreMintable() public {
        vm.chainId(31337);
        HelperConfig anvilConfig = new HelperConfig();
        
        (,, address weth, address wbtc,) = anvilConfig.activeNetworkConfig();
        
        address testUser = makeAddr("testUser");
        
        ERC20Mock(weth).mint(testUser, 100 ether);
        ERC20Mock(wbtc).mint(testUser, 50 ether);
        
        assertEq(ERC20Mock(weth).balanceOf(testUser), 100 ether);
        assertEq(ERC20Mock(wbtc).balanceOf(testUser), 50 ether);
    }

    function testConstants() public view {
        assertEq(config.DECIMALS(), 8);
        assertEq(config.ETH_USD_PRICE(), 2000e8);
        assertEq(config.WBTC_USD_PRICE(), 1000e8);
        assertTrue(config.DEFAULT_ANVIL_PRIVATE_KEY() != 0);
    }

    function testGetOrCreateAnvilEthConfigIsCached() public {
        // First call creates the config
        HelperConfig.NetworkConfig memory config1 = config.getOrCreateAnvilEthConfig();
        
        // Second call should return the same addresses (cached)
        HelperConfig.NetworkConfig memory config2 = config.getOrCreateAnvilEthConfig();
        
        assertEq(config1.wethUsdPriceFeed, config2.wethUsdPriceFeed);
        assertEq(config1.wbtcUsdPriceFeed, config2.wbtcUsdPriceFeed);
        assertEq(config1.weth, config2.weth);
        assertEq(config1.wbtc, config2.wbtc);
    }
}
