// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BizSwap} from "../src/BizSwap.sol";

/// @notice Deploy BizSwap (UUPS) to Arc Mainnet (chainId 5042).
contract DeployMainnet is Script {
    uint256 internal constant CHAIN_ID = 5042;
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
        require(block.chainid == CHAIN_ID, "DeployMainnet: wrong chainId (expected 5042 for Arc Mainnet)");

        string memory confirm = vm.envString("CONFIRM_MAINNET");
        require(
            keccak256(bytes(confirm)) == keccak256(bytes("true")),
            "DeployMainnet: set CONFIRM_MAINNET=true to proceed (WARNING: Arc Mainnet moves real USDC)"
        );

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(deployerKey != 0, "DeployMainnet: DEPLOYER_PRIVATE_KEY is required");
        address deployer = vm.addr(deployerKey);
        address admin = _getEnvAddress("ADMIN", deployer);
        address minter = _getEnvAddress("MINTER", deployer);
        address revenueWallet = _getEnvAddress("REVENUE_WALLET", deployer);
        address upgrader = _getEnvAddress("UPGRADER", deployer);

        vm.startBroadcast(deployerKey);

        BizSwap impl = new BizSwap();
        bytes memory initData = abi.encodeCall(
            BizSwap.initialize, (admin, minter, revenueWallet, upgrader, CANONICAL_USDC, "BizSwap", "BIZ")
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        BizSwap biz = BizSwap(address(proxy));

        vm.stopBroadcast();

        console2.log("Network:          Arc Mainnet");
        console2.log("Chain ID:         ", CHAIN_ID);
        console2.log("Implementation:   ", address(impl));
        console2.log("Proxy (BizSwap):  ", address(proxy));
        console2.log("USDC:             ", CANONICAL_USDC);
        console2.log("Admin:            ", admin);
        console2.log("Upgrader:         ", upgrader);
        console2.log("Minter:           ", minter);
        console2.log("Revenue:          ", revenueWallet);
        console2.log("Fee bps:          ", biz.PLATFORM_FEE_BPS());

        // Automatically update deployments/mainnet-5042.json on live broadcasts
        if (block.timestamp > 1_000_000_000) {
            string memory jsonPath = "./deployments/mainnet-5042.json";
            vm.writeJson(vm.toString(address(proxy)), jsonPath, ".proxy");
            vm.writeJson(vm.toString(address(impl)), jsonPath, ".implementation");
            vm.writeJson(vm.toString(CANONICAL_USDC), jsonPath, ".usdc");
            vm.writeJson(vm.toString(admin), jsonPath, ".admin");
            vm.writeJson(vm.toString(upgrader), jsonPath, ".upgrader");
            vm.writeJson(vm.toString(minter), jsonPath, ".minter");
            vm.writeJson(vm.toString(revenueWallet), jsonPath, ".revenueWallet");
            vm.writeJson(vm.toString(block.timestamp), jsonPath, ".deployedAt");
        }
    }
}
