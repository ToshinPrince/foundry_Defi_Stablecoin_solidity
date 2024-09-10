// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////////
    /// Constructor Test    //
    /////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DCSEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////////////////
    /// Price Test    //
    ////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        //15e18 * 2000 = 30,000e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        //$2000/ ETH = 0.05
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ////////////////////////////////////
    //// Deposit Collateral Test     //
    //////////////////////////////////

    function testRevertIfCollateralIsZero() public {
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DCSEngine__NeedMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector); //
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    // //-------------------------------------------------------------------------------------
    // ////////////////////////////////////
    // /// depositCollateralAndMintDsc ///
    // //////////////////////////////////

    // function testDepositCollateralAndMintDsc() public {
    //     vm.startPrank(USER);

    //     // // Set the expectations for the emitted event
    //     // vm.expectEmit(true, true, true, true); // Parameters for indexed events
    //     // emit CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);

    //     // Approve the contract to spend the collateral
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

    //     // Deposit collateral and mint DSC
    //     uint256 amountDscToMint = 100 ether;
    //     dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountDscToMint);

    //     vm.stopPrank();
    // }

    // ////////////////////////////////////
    // /// mintDsc ///
    // //////////////////////////////////
    // function testRevertsIfMintAmountIsZero() public {
    //     uint256 zeroAmount = 0;

    //     // Start impersonating the user
    //     vm.startPrank(USER);

    //     // Expect the minting function to revert because the amount is zero
    //     vm.expectRevert(DSCEngine.DCSEngine__NeedMoreThanZero.selector);
    //     dsce.mintDsc(zeroAmount);

    //     vm.stopPrank();
    // }

    // function testMintDscSuccessful() public {
    //     uint256 amountToMint = 100 ether; // Example amount to mint

    //     // Assuming the user has already deposited enough collateral to maintain a healthy factor
    //     vm.startPrank(USER);

    //     // Approve collateral and deposit
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

    //     // Now try to mint the DSC tokens
    //     dsce.mintDsc(amountToMint);

    //     // Check that the DSC was minted successfully
    //     assertEq(dsce.s_DSCMinted(USER), amountToMint);
    //     assertEq(i_dsc.balanceOf(USER), amountToMint);

    //     vm.stopPrank();
    // }

    // function testMintDscHealthFactorBrokenReverts() public {
    //     uint256 amountToMint = 100 ether; // Example amount to mint

    //     // Manipulate the health factor to be broken
    //     vm.startPrank(USER);

    //     // This would be some setup that breaks the health factor
    //     // E.g., if the price of the collateral drops or too much DSC is minted

    //     // Expect the mint to revert due to health factor being broken
    //     vm.expectRevert(DCSEngine__HealthFactorBroken.selector);
    //     dsce.mintDsc(amountToMint);

    //     vm.stopPrank();
    // }

    // function testMintDscMintingFailsReverts() public {
    //     uint256 amountToMint = 100 ether; // Example amount to mint

    //     vm.startPrank(USER);

    //     // Setup the necessary collateral deposit
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

    //     // Simulate a failure in the DSC mint function (e.g., mocking the mint function to return false)
    //     vm.mockCall(
    //         address(i_dsc),
    //         abi.encodeWithSelector(DSC.mint.selector, USER, amountToMint),
    //         abi.encode(false) // Simulate minting failure
    //     );

    //     // Expect minting to revert
    //     vm.expectRevert(DSCEngine.DCSEngine__MintFailed.selector);
    //     dsce.mintDsc(amountToMint);

    //     vm.stopPrank();
    // }
}
