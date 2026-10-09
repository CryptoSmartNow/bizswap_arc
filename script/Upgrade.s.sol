// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {BizSwap} from "../src/BizSwap.sol";
import {IBizSwap} from "../src/interfaces/IBizSwap.sol";

/// @notice Upgrade BizSwap proxy to a new implementation on Arc Network.
/// @dev Can be executed by either UPGRADER_ROLE (e.g. deployer) or DEFAULT_ADMIN_ROLE (admin).
contract Upgrade is Script {
    uint256 internal constant TESTNET_CHAIN_ID = 5042002;
    uint256 internal constant MAINNET_CHAIN_ID = 5042;
    address internal constant CANONICAL_USDC = 0x3600000000000000000000000000000000000000;

    function _getEnvAddress(string memory key, address fallbackAddr) internal view returns (address) {
        try vm.envString(key) returns (string memory val) {
            if (bytes(val).length == 0) return fallbackAddr;
            return vm.parseAddress(val);
        } catch {
            return fallbackAddr;
        }
    }

    function _getSignerKey() internal view returns (uint256) {
        try vm.envUint("UPGRADER_PRIVATE_KEY") returns (uint256 k) {
            if (k != 0) return k;
        } catch {}
        try vm.envUint("ADMIN_PRIVATE_KEY") returns (uint256 k) {
            if (k != 0) return k;
        } catch {}
        return
            vm.envOr(
                "DEPLOYER_PRIVATE_KEY", uint256(0xf776f736e398908c34b448f6301ddc9a5630c5ce96f2f595b80313ca9a339915)
            );
    }

    function run() external {
        string memory jsonPath = "";
        if (block.chainid == TESTNET_CHAIN_ID) {
            jsonPath = "./deployments/testnet-5042002.json";
        } else if (block.chainid == MAINNET_CHAIN_ID) {
            string memory confirm = vm.envString("CONFIRM_MAINNET");
            require(
                keccak256(bytes(confirm)) == keccak256(bytes("true")),
                "Upgrade: set CONFIRM_MAINNET=true to proceed with Arc Mainnet upgrade"
            );
            jsonPath = "./deployments/mainnet-5042.json";
        }

        address proxyAddr = _getEnvAddress("PROXY_ADDRESS", address(0));
        if (proxyAddr == address(0) && bytes(jsonPath).length > 0) {
            try vm.readFile(jsonPath) returns (string memory json) {
                proxyAddr = vm.parseJsonAddress(json, ".proxy");
            } catch {}
        }
        require(proxyAddr != address(0), "Upgrade: PROXY_ADDRESS not set and not found in deployment file");

        uint256 signerKey = _getSignerKey();
        address signer = vm.addr(signerKey);

        BizSwap biz = BizSwap(proxyAddr);
        bool hasUpgraderRole = biz.hasRole(biz.UPGRADER_ROLE(), signer);
        bool hasAdminRole = biz.hasRole(biz.DEFAULT_ADMIN_ROLE(), signer);
        require(hasUpgraderRole || hasAdminRole, "Upgrade: signer is neither UPGRADER_ROLE nor DEFAULT_ADMIN_ROLE");

        console2.log("--- BizSwap Upgrade ---");
        console2.log("Chain ID:           ", block.chainid);
        console2.log("Proxy:              ", proxyAddr);
        console2.log("Signer:             ", signer);
        console2.log("Has Upgrader:       ", hasUpgraderRole);
        console2.log("Has Admin:          ", hasAdminRole);

        vm.startBroadcast(signerKey);

        BizSwap newImpl = new BizSwap();
        biz.upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        console2.log("New Implementation: ", address(newImpl));

        // Post-upgrade sanity checks
        require(keccak256(bytes(biz.name())) == keccak256(bytes("BizSwap")), "Upgrade check failed: wrong name");
        require(biz.MAX_YIELD_ROUNDS() == 24, "Upgrade check failed: MAX_YIELD_ROUNDS != 24");
        require(biz.usdc() == CANONICAL_USDC, "Upgrade check failed: unexpected USDC");

        if (bytes(jsonPath).length > 0 && block.timestamp > 1_000_000_000) {
            vm.writeJson(vm.toString(address(newImpl)), jsonPath, ".implementation");
            vm.writeJson(vm.toString(block.timestamp), jsonPath, ".upgradedAt");
            console2.log("Updated metadata:   ", jsonPath);
        }
    }
}
