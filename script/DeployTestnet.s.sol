// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BizSwap} from "../src/BizSwap.sol";

/// @notice Deploy BizSwap (UUPS) to Arc Testnet (chainId 5042002).
contract DeployTestnet is Script {
    uint256 internal constant CHAIN_ID = 5042002;
    address internal constant CANONICAL_USDC = 0x3600000000000000000000000000000000000000;

    function _getEnvAddress(string memory key, address fallbackAddr) internal view returns (address) {
        try vm.envString(key) returns (string memory val) {
            if (bytes(val).length == 0) return fallbackAddr;
            return vm.parseAddress(val);
        } catch {
            return fallbackAddr;
        }
    }

    function run() external {
        require(block.chainid == CHAIN_ID, "DeployTestnet: wrong chainId (expected 5042002 for Arc Testnet)");

        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY", uint256(0xf776f736e398908c34b448f6301ddc9a5630c5ce96f2f595b80313ca9a339915)
        );
        address deployer = vm.addr(deployerKey);
        address admin = _getEnvAddress("ADMIN", deployer);
        address minter = _getEnvAddress("MINTER", deployer);
        address revenueWallet = _getEnvAddress("REVENUE_WALLET", deployer);

        vm.startBroadcast(deployerKey);

        BizSwap impl = new BizSwap();
        bytes memory initData =
            abi.encodeCall(BizSwap.initialize, (admin, minter, revenueWallet, CANONICAL_USDC, "BizSwap", "BIZ"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        BizSwap biz = BizSwap(address(proxy));

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
