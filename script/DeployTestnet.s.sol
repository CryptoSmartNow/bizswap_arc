// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BizSwap} from "../src/BizSwap.sol";

/// @notice Deploy BizSwap (UUPS) to BOT testnet (chainId 968).
contract DeployTestnet is Script {
    uint256 internal constant CHAIN_ID = 968;
    address internal constant USDT = 0x75edC9335175Fc0552D51D48439F229c10420fe3;

    function run() external {
        require(block.chainid == CHAIN_ID, "DeployTestnet: wrong chainId (expected 968)");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address admin = vm.envAddress("ADMIN");
        address minter = vm.envAddress("MINTER");
        address revenueWallet = vm.envAddress("REVENUE_WALLET");

        vm.startBroadcast(deployerKey);

        BizSwap impl = new BizSwap();
        bytes memory initData =
            abi.encodeCall(BizSwap.initialize, (deployer, minter, revenueWallet, USDT, "BizSwap", "BIZ"));
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

        console2.log("Network:          BOT Testnet");
        console2.log("Chain ID:         ", CHAIN_ID);
        console2.log("Implementation:   ", address(impl));
        console2.log("Proxy (BizSwap):  ", address(proxy));
        console2.log("USDT:             ", USDT);
        console2.log("Admin:            ", admin);
        console2.log("Minter:           ", minter);
        console2.log("Revenue:          ", revenueWallet);
        console2.log("Fee bps:          ", biz.PLATFORM_FEE_BPS());
    }
}
