// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin dsc;
    address public owner;
    address public user = makeAddr("user");

    function setUp() public {
        owner = address(this);
        dsc = new DecentralizedStableCoin();
    }

    function testNameAndSymbol() public view {
        assertEq(dsc.name(), "Decentralized StableCoin");
        assertEq(dsc.symbol(), "DSC");
    }

    function testOwnerIsDeployer() public view {
        assertEq(dsc.owner(), owner);
    }

    function testMintRevertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        dsc.mint(user, 100 ether);
    }

    function testMintRevertsIfToAddressIsZero() public {
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MintToZeroAddress.selector);
        dsc.mint(address(0), 100 ether);
    }

    function testMintRevertsIfAmountIsZero() public {
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.mint(user, 0);
    }

    function testMintSuccessfully() public {
        uint256 amount = 100 ether;
        bool success = dsc.mint(user, amount);
        
        assertTrue(success);
        assertEq(dsc.balanceOf(user), amount);
        assertEq(dsc.totalSupply(), amount);
    }

    function testBurnRevertsIfNotOwner() public {
        dsc.mint(user, 100 ether);
        
        vm.prank(user);
        vm.expectRevert();
        dsc.burn(50 ether);
    }

    function testBurnRevertsIfAmountIsZero() public {
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.burn(0);
    }

    function testBurnRevertsIfAmountExceedsBalance() public {
        dsc.mint(owner, 100 ether);
        
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        dsc.burn(200 ether);
    }

    function testBurnSuccessfully() public {
        uint256 mintAmount = 100 ether;
        uint256 burnAmount = 30 ether;
        
        dsc.mint(owner, mintAmount);
        dsc.burn(burnAmount);
        
        assertEq(dsc.balanceOf(owner), mintAmount - burnAmount);
        assertEq(dsc.totalSupply(), mintAmount - burnAmount);
    }

    function testTransferOwnership() public {
        address newOwner = makeAddr("newOwner");
        dsc.transferOwnership(newOwner);
        
        assertEq(dsc.owner(), newOwner);
    }

    function testCanTransferTokens() public {
        uint256 amount = 100 ether;
        dsc.mint(owner, amount);
        
        dsc.transfer(user, 50 ether);
        
        assertEq(dsc.balanceOf(user), 50 ether);
        assertEq(dsc.balanceOf(owner), 50 ether);
    }

    function testCanApproveAndTransferFrom() public {
        uint256 amount = 100 ether;
        dsc.mint(owner, amount);
        
        dsc.approve(user, 50 ether);
        
        vm.prank(user);
        dsc.transferFrom(owner, user, 30 ether);
        
        assertEq(dsc.balanceOf(user), 30 ether);
        assertEq(dsc.allowance(owner, user), 20 ether);
    }
}
