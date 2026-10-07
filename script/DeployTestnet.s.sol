// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BizSwap} from "../src/BizSwap.sol";

/// @notice Deploy BizSwap (UUPS) to Arc Testnet (chainId 5042002).
contract DeployTestnet is Script {
    uint256 internal constant CHAIN_ID = 5042002;
    address internal constant CANONICAL_USDC = 0x3600000000000000000000000000000000000000;

    function run() external {
        require(block.chainid == CHAIN_ID, "DeployTestnet: wrong chainId (expected 5042002 for Arc Testnet)");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address admin = vm.envAddress("ADMIN");
        address minter = vm.envAddress("MINTER");
        address revenueWallet = vm.envAddress("REVENUE_WALLET");

        vm.startBroadcast(deployerKey);

        BizSwap impl = new BizSwap();
        bytes memory initData =
            abi.encodeCall(BizSwap.initialize, (deployer, minter, revenueWallet, CANONICAL_USDC, "BizSwap", "BIZ"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        BizSwap biz = BizSwap(address(proxy));

        biz.configureInstrument(0, 1000, 1_000);
        biz.configureInstrument(1, 1000, 10_000);
        biz.configureInstrument(2, 1000, 100_000);

        // Product schedule defaults already set in initialize; grant intended admin
        if (admin != deployer) {
            biz.grantRole(biz.DEFAULT_ADMIN_ROLE(), admin);
            biz.grantRole(biz.DISTRIBUTOR_ROLE(), admin);
            biz.renounceRole(biz.DEFAULT_ADMIN_ROLE(), deployer);
            biz.renounceRole(biz.DISTRIBUTOR_ROLE(), deployer);
        }

        vm.stopBroadcast();

        console2.log("Network:          Arc Testnet");
        console2.log("Chain ID:         ", CHAIN_ID);
        console2.log("Implementation:   ", address(impl));
        console2.log("Proxy (BizSwap):  ", address(proxy));
        console2.log("USDC:             ", CANONICAL_USDC);
        console2.log("Admin:            ", admin);
        console2.log("Minter:           ", minter);
        console2.log("Revenue:          ", revenueWallet);
        console2.log("Fee bps:          ", biz.PLATFORM_FEE_BPS());

        // Automatically update deployments/testnet-5042002.json
        string memory jsonPath = "./deployments/testnet-5042002.json";
        vm.writeJson(vm.toString(address(proxy)), jsonPath, ".proxy");
        vm.writeJson(vm.toString(address(impl)), jsonPath, ".implementation");
        vm.writeJson(vm.toString(CANONICAL_USDC), jsonPath, ".usdc");
        vm.writeJson(vm.toString(admin), jsonPath, ".admin");
        vm.writeJson(vm.toString(minter), jsonPath, ".minter");
        vm.writeJson(vm.toString(revenueWallet), jsonPath, ".revenueWallet");
        vm.writeJson(vm.toString(block.timestamp), jsonPath, ".deployedAt");
    }
}
