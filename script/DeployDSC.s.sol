// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DCSEngine} from "../src/DSCEngine.sol";
import {HeplerConfig} from "../script/HelperConfig.s.sol";

contract DeployDSC is Script {
    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function run() external returns (DecentralizedStableCoin, DCSEngine) {
        HeplerConfig config = new HeplerConfig();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            config.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast();
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();
        DCSEngine engine = new DCSEngine(tokenAddresses, priceFeedAddresses, address(dsc));
        dsc.transferOwnership(address(engine));
        vm.stopBroadcast();
        return (dsc, engine);
    }
}
