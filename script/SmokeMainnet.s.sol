// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {BizSwap} from "../src/BizSwap.sol";
import {IBizSwap} from "../src/interfaces/IBizSwap.sol";

/// @notice Read-only smoke checks against a deployed BizSwap mainnet proxy.
contract SmokeMainnet is Script {
    uint256 internal constant CHAIN_ID = 677;
    address internal constant EXPECTED_USDT = 0xaBabc7Ddc03e501d190C676BF3d92ef0e6e87a3C;

    function run() external view {
        require(block.chainid == CHAIN_ID, "SmokeMainnet: wrong chainId");

        address proxyAddr = vm.envAddress("PROXY_ADDRESS");
        BizSwap biz = BizSwap(proxyAddr);

        console2.log("Proxy:        ", proxyAddr);
        console2.log("Name:         ", biz.name());
        console2.log("USDT:         ", biz.usdt());
        console2.log("Revenue:      ", biz.revenueWallet());
        console2.log("Fee bps:      ", biz.PLATFORM_FEE_BPS());
        console2.log("Next tokenId: ", biz.nextTokenId());
        console2.log("Pool USDT:    ", biz.distributionPoolUsdtRaw());

        require(biz.usdt() == EXPECTED_USDT, "unexpected USDT");
        require(biz.PLATFORM_FEE_BPS() == 50, "unexpected fee bps");

        for (uint8 i = 0; i < 3; i++) {
            IBizSwap.Instrument memory inst = biz.instruments(i);
            console2.log("--- instrument", i);
            console2.log("  configured", inst.configured);
            console2.log("  supplyCap", inst.supplyCap);
            console2.log("  minBuyIn", inst.minBuyInCents);
            require(inst.configured, "instrument not configured");
        }
    }
}
