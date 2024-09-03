// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DCSEngine
 * @author Toshin Prince
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    /////////////////////
    //errors          //
    ///////////////////
    error DCSEngine__NeedMoreThanZero();
    error DCSEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DCSEngine__NotAllowedToken();
    error DCSEngine__TransferFailed();
    error DCSEngine__BreakHealthFactor(uint256 userHealthFactor);
    error DCSEngine__MintFailed();
    error DCSEngine__HealthFactorOk();
    error DCSEngine__HealthFactorNotImproved();

    //////////////////////////////////////////
    //State Variables //
    ////////////////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //This means 10% Bonus.

    mapping(address tokenAddress => address pricefeedAddress) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////////////////////////
    //Events //
    ////////////////////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemedTo, address token, uint256 amount);

    /////////////////////
    //Modifiers       //
    ///////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DCSEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DCSEngine__NotAllowedToken();
        }
        _;
    }

    /////////////////////
    //Functions       //
    ///////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        //USD PriceFeed
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DCSEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////
    //External Functions//
    /////////////////////

    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The Amount of the collateral to deposit
     * @param amountDscToMint  The Amount of the decentralized stable coin to mint
     * @notice this function will deposit your collateral and mint DSC in one transation.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral the amount of the collateral to deposit
     * 
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DCSEngine__TransferFailed();
        }
    }

    /**
     *
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to Burn
     * This function burns DSC and redeem underlying collateral in one transaction.
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral already checks health factor
    }

    // In order to redeem collateral:
    // 1. Health Factor must be over 1 After collateral pulled.
    // DRY: Don't repeat your Self.
    //CEI: Check, Effects, Intractions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of Decentralized stable coin to mint
     * @notice they must have more collateral value than the threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DCSEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit...
    }

    //if we do start nearing undercollaterization, we need someone to liquidate position

    //$100 ETH backing $50 DSC
    //$20 ETH back $50 DSC <- DSC is't Worth $1

    //$75 Eth backing $50 DSC
    //Liquidator will take $75 backing and burns off the $50 DSC

    //If someone is almost undercollatarized, we will pay you to liquidate them!

    /**
     *
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user The user who have broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the user health factor
     * @notice you can partially liquidate a user.
     * @notice you will get a liquidation bonus for taking the users funds.
     * @notice This function working assumes that the protocol will be roughly 200% overcollateralized in order for this to work.
     * @notice A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate anyone
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     * Follows CEI: Checks, Effects, Interactions.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //need to check health factor of user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            // revert DCSEngine__BreakHealthFactor(startingUserHealthFactor);
            revert DCSEngine__HealthFactorOk();
        }
        // we want to burn their DSC "Debt"
        // And take their collateral
        // Bad user: $140 ETH, $100 DSC
        // debtToCover = $100
        // $100 of DSC == ??ETh
        // 0.05 ETH

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        // Add give then a 10% bonus
        // So we are giving the liquidator $110 of WETH for $100 of DSC
        // We should implement a features to liquidate in the event the protocol is insolvent
        // And sweep extra amount money into Treasury

        //0.05 * 0.1 = 0.055. Getting 0.055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        //We need to burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DCSEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external {}

    ///////////////////////////////////////
    //Private and Internal View Functions//
    //////////////////////////////////////

    /**
     * @dev Low-Level internal function, do not call unless the function calling it is
     * Checking for health factor being Broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);

        // This conditional is hypothitically unreachable
        if (!success) {
            revert DCSEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        //_calculateHealthFactorAfter
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DCSEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Return how close to liqudation user is
     * If the user is below 1, then the user gets liqudated
     */
    function _healthFactor(address user) private view returns (uint256) {
        //Total DSC Minted
        //Total Collateral Value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        // $150 ETH / 100 DSC = 1.5
        // 150 * 50 = 7500 / 100 = (75/100) < 1

        // $1000 ETH / 100 DSC
        // 1000 * 50 = 50000 / 100 = (500/100) > 1
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    //1. Check Health Factor(do they have enough collateral?).
    //2. Revert if they don't.
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DCSEngine__BreakHealthFactor(userHealthFactor);
        }
    }

    ////////////////////////////////////////
    //Public and External view Functions //
    //////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        //price of ETH Token
        //$/ETH ETH ??
        //$2000/ETH. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        //(10e18 * 1e18) / ($2000e18 * 1e18)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral token, get the amount they have deposited, and map it to
        //the price, to get the USD value.
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface PriceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = PriceFeed.latestRoundData();
        //1 ETH = $1000
        //The return value from CL will be 1000*10^8
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }
}
