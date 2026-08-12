// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {BizSwap} from "../src/BizSwap.sol";

/// @notice Upgrade BizSwap proxy to a new implementation.
contract Upgrade is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxyAddr = vm.envAddress("PROXY_ADDRESS");

        vm.startBroadcast(deployerKey);

        BizSwap newImpl = new BizSwap();
        BizSwap(proxyAddr).upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        console2.log("Proxy:              ", proxyAddr);
        console2.log("New implementation: ", address(newImpl));
    }
}
