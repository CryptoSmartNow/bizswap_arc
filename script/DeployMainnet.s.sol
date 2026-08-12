// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BizSwap} from "../src/BizSwap.sol";

/// @notice Deploy BizSwap (UUPS) to BOT mainnet (chainId 677).
contract DeployMainnet is Script {
    uint256 internal constant CHAIN_ID = 677;
    address internal constant USDT = 0xaBabc7Ddc03e501d190C676BF3d92ef0e6e87a3C;

    function run() external {
        require(block.chainid == CHAIN_ID, "DeployMainnet: wrong chainId (expected 677)");

        string memory confirm = vm.envString("CONFIRM_MAINNET");
        require(
            keccak256(bytes(confirm)) == keccak256(bytes("true")), "DeployMainnet: set CONFIRM_MAINNET=true to proceed"
        );

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

        if (admin != deployer) {
            biz.grantRole(biz.DEFAULT_ADMIN_ROLE(), admin);
            biz.grantRole(biz.DISTRIBUTOR_ROLE(), admin);
            biz.renounceRole(biz.DEFAULT_ADMIN_ROLE(), deployer);
            biz.renounceRole(biz.DISTRIBUTOR_ROLE(), deployer);
        }

        vm.stopBroadcast();

        console2.log("Network:          BOT Mainnet");
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
