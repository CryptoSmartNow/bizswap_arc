// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BizSwap} from "../src/BizSwap.sol";
import {IBizSwap} from "../src/interfaces/IBizSwap.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";
import {AmountCodec} from "../src/libraries/AmountCodec.sol";

contract BizSwapV2 is BizSwap {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

contract BizSwapTest is Test {
    BizSwap internal biz;
    MockUSDT internal usdtToken;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal revenue = makeAddr("revenue");
    address internal user = makeAddr("user");
    address internal other = makeAddr("other");

    uint8 internal constant YIELD = 0;
    uint8 internal constant CREDIT = 1;
    uint8 internal constant BOND = 2;

    uint64 internal constant VEST_END = 2_000_000_000;
    uint64 internal constant YIELD_START = 1_900_000_000;

    function setUp() public {
        usdtToken = new MockUSDT();
        biz = _deploy(admin, minter, revenue, address(usdtToken));

        vm.startPrank(admin);
        biz.configureInstrument(YIELD, 1000, 1_000);
        biz.configureInstrument(CREDIT, 1000, 10_000);
        biz.configureInstrument(BOND, 1000, 100_000);
        // Use controllable schedule times for tests
        biz.configureSchedules({
            creditFirstPayment_: 1_000_000,
            creditWeekSeconds_: 7 days,
            creditWeekCount_: 12,
            creditTotalReturnBps_: 10_404,
            bondQuarterSeconds_: 90 days,
            bondMaxQuarters_: 8,
            bondQuarterBps_: 250
        });
        vm.stopPrank();
    }

    function _deploy(address admin_, address minter_, address revenue_, address usdt_)
        internal
        returns (BizSwap proxyAs)
    {
        BizSwap impl = new BizSwap();
        bytes memory initData =
            abi.encodeCall(BizSwap.initialize, (admin_, minter_, revenue_, usdt_, "BizSwap", "BIZ"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        proxyAs = BizSwap(address(proxy));
    }

    function _mint(address to, uint8 instrumentId, uint256 netCents, uint256 entitlementBps, uint64 vestEnd, uint64 yieldStart)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(minter);
        tokenId = biz.mintCertificate(
            to, instrumentId, netCents, entitlementBps, vestEnd, yieldStart, bytes32("2026-MAY"), "ipfs://bizswap/1"
        );
    }

    function _fundPool(uint256 usdtRaw) internal {
        usdtToken.mint(admin, usdtRaw);
        vm.startPrank(admin);
        usdtToken.approve(address(biz), usdtRaw);
        biz.depositDistributionUsdt(usdtRaw);
        vm.stopPrank();
    }

    function _fundYieldRound(uint256 usdtRaw) internal returns (uint256 roundId) {
        usdtToken.mint(admin, usdtRaw);
        vm.startPrank(admin);
        usdtToken.approve(address(biz), usdtRaw);
        roundId = biz.openYieldRound(usdtRaw);
        vm.stopPrank();
    }

    // ─── Phase 1 ─────────────────────────────────────────────────────────────

    function test_Initialize() public view {
        assertTrue(biz.hasRole(biz.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(biz.hasRole(biz.MINTER_ROLE(), minter));
        assertTrue(biz.hasRole(biz.DISTRIBUTOR_ROLE(), admin));
        assertEq(biz.usdt(), address(usdtToken));
        assertEq(biz.name(), "BizSwap");
        assertEq(biz.symbol(), "BIZ");
        assertEq(biz.PLATFORM_FEE_BPS(), 50);
    }

    function test_Fee_YieldAndBondOnly() public view {
        assertEq(biz.quoteFee(YIELD, 40_000), 200);
        assertEq(biz.quoteGross(YIELD, 40_000), 40_200);
        assertEq(biz.quoteFee(BOND, 100_000), 500);
        assertEq(biz.quoteFee(CREDIT, 10_000), 0);
        assertEq(biz.quoteGross(CREDIT, 10_000), 10_000);
    }

    function test_MintRecordsFee() public {
        uint256 y = _mint(user, YIELD, 40_000, 500, VEST_END, YIELD_START);
        assertEq(biz.certificates(y).feeCents, 200);
        assertEq(biz.certificates(y).amountCents, 40_000);
        assertEq(biz.instruments(YIELD).totalFeesCents, 200);

        uint256 c = _mint(user, CREDIT, 10_000, 0, 0, 0);
        assertEq(biz.certificates(c).feeCents, 0);
        assertEq(biz.instruments(CREDIT).totalFeesCents, 0);
    }

    function test_YieldVesting_TransferLocked() public {
        uint256 tokenId = _mint(user, YIELD, 1_000, 10, VEST_END, YIELD_START);
        vm.prank(user);
        vm.expectRevert(IBizSwap.TransferWhileVesting.selector);
        biz.transferFrom(user, other, tokenId);
    }

    function test_Credit_TransferOk() public {
        uint256 tokenId = _mint(user, CREDIT, 10_000, 0, 0, 0);
        vm.prank(user);
        biz.transferFrom(user, other, tokenId);
        assertEq(biz.ownerOf(tokenId), other);
    }

    function test_UnlockThenTransfer() public {
        uint256 tokenId = _mint(user, YIELD, 1_000, 10, VEST_END, YIELD_START);
        vm.warp(VEST_END);
        biz.unlock(tokenId);
        vm.prank(user);
        biz.transferFrom(user, other, tokenId);
        assertEq(biz.ownerOf(tokenId), other);
    }

    function test_CapAndMinBuyIn() public {
        vm.prank(admin);
        biz.configureInstrument(YIELD, 1, 1_000);

        _mint(user, YIELD, 1_000, 10, VEST_END, YIELD_START);

        vm.prank(minter);
        vm.expectRevert(IBizSwap.CapExceeded.selector);
        biz.mintCertificate(user, YIELD, 1_000, 10, VEST_END, YIELD_START, bytes32(0), "ipfs://x");

        vm.prank(minter);
        vm.expectRevert(IBizSwap.BelowMinBuyIn.selector);
        biz.mintCertificate(user, CREDIT, 9_999, 0, 0, 0, bytes32(0), "ipfs://x");
    }

    // ─── Phase 2 Yield ───────────────────────────────────────────────────────

    function test_YieldClaim_ShareOfRound() public {
        // 5% entitlement (500 bps), round $1000 USDT = 1000e6 raw
        uint256 tokenId = _mint(user, YIELD, 50_000, 500, VEST_END, YIELD_START);
        vm.warp(VEST_END);
        biz.unlock(tokenId);
        vm.warp(YIELD_START);

        uint256 roundRaw = 1_000 * 1e6;
        _fundYieldRound(roundRaw);

        uint256 expected = (roundRaw * 500) / 10_000; // 50 USDT
        assertEq(biz.claimable(tokenId), expected);

        uint256 balBefore = usdtToken.balanceOf(user);
        vm.prank(user);
        uint256 paid = biz.claim(tokenId);
        assertEq(paid, expected);
        assertEq(usdtToken.balanceOf(user) - balBefore, expected);

        // second claim empty
        vm.prank(user);
        vm.expectRevert(IBizSwap.NothingToClaim.selector);
        biz.claim(tokenId);
    }

    function test_YieldClaim_WhileVestingReverts() public {
        uint256 tokenId = _mint(user, YIELD, 1_000, 100, VEST_END, YIELD_START);
        _fundYieldRound(100e6);
        vm.prank(user);
        vm.expectRevert(IBizSwap.StillVesting.selector);
        biz.claim(tokenId);
    }

    function test_YieldClaim_BeforeYieldStartReverts() public {
        uint256 tokenId = _mint(user, YIELD, 1_000, 100, 1_000, YIELD_START);
        vm.warp(1_000);
        biz.unlock(tokenId);
        _fundYieldRound(100e6);
        // now < yieldStart
        vm.warp(YIELD_START - 1);
        vm.prank(user);
        vm.expectRevert(IBizSwap.YieldNotStarted.selector);
        biz.claim(tokenId);
    }

    // ─── Phase 2 Credit ──────────────────────────────────────────────────────

    function test_CreditClaim_TwelveWeeks() public {
        uint256 tokenId = _mint(user, CREDIT, 10_000, 0, 0, 0); // $100

        uint256 totalPayoutCents = (10_000 * 10_404) / 10_000; // 10404
        uint256 weeklyCents = totalPayoutCents / 12; // 867
        uint256 weeklyRaw = AmountCodec.centsToRaw(weeklyCents, 6);
        uint256 totalRaw = weeklyRaw * 12;

        _fundPool(totalRaw + 1e6);

        // before first payment
        vm.warp(999_999);
        assertEq(biz.claimable(tokenId), 0);

        // week 0
        vm.warp(1_000_000);
        assertEq(biz.claimable(tokenId), weeklyRaw);
        vm.prank(user);
        assertEq(biz.claim(tokenId), weeklyRaw);

        // jump to end of all weeks
        vm.warp(1_000_000 + 11 * 7 days);
        uint256 remaining = weeklyRaw * 11;
        assertEq(biz.claimable(tokenId), remaining);
        vm.prank(user);
        assertEq(biz.claim(tokenId), remaining);

        assertEq(uint8(biz.certificates(tokenId).status), uint8(IBizSwap.Status.Redeemed));
        assertEq(usdtToken.balanceOf(user), totalRaw);
    }

    function test_Credit_InsufficientPool() public {
        uint256 tokenId = _mint(user, CREDIT, 10_000, 0, 0, 0);
        vm.warp(1_000_000 + 12 * 7 days);
        // no funding
        vm.prank(user);
        vm.expectRevert(IBizSwap.InsufficientPool.selector);
        biz.claim(tokenId);
    }

    // ─── Phase 2 Bond ────────────────────────────────────────────────────────

    function test_BondClaim_Quarterly() public {
        uint256 tokenId = _mint(user, BOND, 100_000, 0, VEST_END, YIELD_START); // $1000
        vm.warp(VEST_END);
        biz.unlock(tokenId);

        uint256 quarterCents = (100_000 * 250) / 10_000; // 2500 cents = $25
        uint256 quarterRaw = AmountCodec.centsToRaw(quarterCents, 6);
        _fundPool(quarterRaw * 8);

        // first quarter at yieldStart
        vm.warp(YIELD_START);
        assertEq(biz.claimable(tokenId), quarterRaw);
        vm.prank(user);
        assertEq(biz.claim(tokenId), quarterRaw);

        // second quarter
        vm.warp(YIELD_START + 90 days);
        vm.prank(user);
        assertEq(biz.claim(tokenId), quarterRaw);

        // remaining 6 quarters
        vm.warp(YIELD_START + 7 * 90 days);
        vm.prank(user);
        assertEq(biz.claim(tokenId), quarterRaw * 6);

        assertEq(uint8(biz.certificates(tokenId).status), uint8(IBizSwap.Status.Redeemed));
    }

    // ─── Auth / pause ────────────────────────────────────────────────────────

    function test_NonOwnerCannotClaim() public {
        uint256 tokenId = _mint(user, CREDIT, 10_000, 0, 0, 0);
        _fundPool(1e12);
        vm.warp(1_000_000);
        vm.prank(other);
        vm.expectRevert(IBizSwap.NotCertificateOwner.selector);
        biz.claim(tokenId);
    }

    function test_ClaimsPaused() public {
        uint256 tokenId = _mint(user, CREDIT, 10_000, 0, 0, 0);
        _fundPool(1e12);
        vm.warp(1_000_000);
        vm.prank(admin);
        biz.setClaimsPaused(true);
        vm.prank(user);
        vm.expectRevert(IBizSwap.ClaimsPaused.selector);
        biz.claim(tokenId);
    }

    function test_NonDistributorCannotDeposit() public {
        usdtToken.mint(user, 1e6);
        vm.startPrank(user);
        usdtToken.approve(address(biz), 1e6);
        vm.expectRevert();
        biz.depositDistributionUsdt(1e6);
        vm.stopPrank();
    }

    // ─── Upgrade ─────────────────────────────────────────────────────────────

    function test_UpgradePreservesState() public {
        uint256 tokenId = _mint(user, CREDIT, 10_000, 0, 0, 0);
        BizSwapV2 v2 = new BizSwapV2();
        vm.prank(admin);
        biz.upgradeToAndCall(address(v2), "");
        assertEq(biz.ownerOf(tokenId), user);
        assertEq(biz.certificates(tokenId).amountCents, 10_000);
        assertEq(BizSwapV2(address(biz)).version(), "v2");
    }
}
