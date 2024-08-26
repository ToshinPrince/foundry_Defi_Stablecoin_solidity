// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DCSEngine} from "../src/DSCEngine.sol";


contract DeployDSC is Script {
    function run() external returns (DecentralizedStableCoin, DCSEngine) {
        vm.startBroadcast();
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();
        DCSEngine engine = new DCSEngine(,,dsc.address);
        vm.stopBroadcast();
    }
}
