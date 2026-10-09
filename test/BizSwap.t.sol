// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BizSwap} from "../src/BizSwap.sol";
import {IBizSwap} from "../src/interfaces/IBizSwap.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {AmountCodec} from "../src/libraries/AmountCodec.sol";

contract BizSwapV2 is BizSwap {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

contract BizSwapTest is Test {
    BizSwap internal biz;
    MockUSDC internal usdcToken;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal revenue = makeAddr("revenue");
    address internal deployer = makeAddr("deployer");
    address internal user = makeAddr("user");
    address internal other = makeAddr("other");

    uint8 internal constant YIELD = 0;
    uint8 internal constant CREDIT = 1;
    uint8 internal constant BOND = 2;

    uint64 internal constant VEST_END = 2_000_000_000;
    uint64 internal constant YIELD_START = 1_900_000_000;

    function setUp() public {
        usdcToken = new MockUSDC();
        biz = _deploy(admin, minter, revenue, deployer, address(usdcToken));

        vm.startPrank(admin);
        biz.configureInstrument(YIELD, 1000, 1_000);
        biz.configureInstrument(CREDIT, 1000, 10_000);
        biz.configureInstrument(BOND, 1000, 100_000);
        // Use controllable schedule times for tests
        biz.configureSchedules({
            creditWeekSeconds_: 7 days,
            creditWeekCount_: 12,
            creditTotalReturnBps_: 10_404,
            bondQuarterSeconds_: 90 days,
            bondMaxQuarters_: 4,
            bondQuarterBps_: 250
        });
        vm.stopPrank();
    }

    function _deploy(address admin_, address minter_, address revenue_, address upgrader_, address usdc_)
        internal
        returns (BizSwap proxyAs)
    {
        BizSwap impl = new BizSwap();
        bytes memory initData =
            abi.encodeCall(BizSwap.initialize, (admin_, minter_, revenue_, upgrader_, usdc_, "BizSwap", "BIZ"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        proxyAs = BizSwap(address(proxy));
    }

    function _mint(
        address to,
        uint8 instrumentId,
        uint256 netCents,
        uint256 entitlementBps,
        uint64 vestEnd,
        uint64 yieldStart
    ) internal returns (uint256 tokenId) {
        vm.prank(minter);
        tokenId = biz.mintCertificate(
            to, instrumentId, netCents, entitlementBps, vestEnd, yieldStart, bytes32("2026-MAY"), "ipfs://bizswap/1"
        );
    }

    function _fundPool(uint256 usdcRaw) internal {
        usdcToken.mint(admin, usdcRaw * 2);
        vm.startPrank(admin);
        usdcToken.approve(address(biz), usdcRaw * 2);
        biz.depositDistributionUsdc(CREDIT, usdcRaw);
        biz.depositDistributionUsdc(BOND, usdcRaw);
        vm.stopPrank();
    }

    function _fundYieldRound(uint256 usdcRaw) internal returns (uint256 roundId) {
        usdcToken.mint(admin, usdcRaw);
        vm.startPrank(admin);
        usdcToken.approve(address(biz), usdcRaw);
        roundId = biz.openYieldRound(usdcRaw);
        vm.stopPrank();
    }

    // ─── Phase 1 ─────────────────────────────────────────────────────────────

    function test_Initialize() public view {
        assertTrue(biz.hasRole(biz.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(biz.hasRole(biz.MINTER_ROLE(), minter));
        assertTrue(biz.hasRole(biz.DISTRIBUTOR_ROLE(), admin));
        assertTrue(biz.hasRole(biz.UPGRADER_ROLE(), admin));
        assertTrue(biz.hasRole(biz.UPGRADER_ROLE(), deployer));
        assertFalse(biz.hasRole(biz.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(biz.hasRole(biz.MINTER_ROLE(), deployer));
        assertFalse(biz.hasRole(biz.DISTRIBUTOR_ROLE(), deployer));
        assertEq(biz.revenueWallet(), revenue);
        assertEq(biz.usdc(), address(usdcToken));
        assertEq(biz.name(), "BizSwap");
        assertEq(biz.symbol(), "BIZ");
        assertEq(biz.PLATFORM_FEE_BPS(), 50);

        assertTrue(biz.instruments(YIELD).configured);
        assertEq(biz.instruments(YIELD).supplyCap, 1000);
        assertEq(biz.instruments(YIELD).minBuyInCents, 1_000);

        assertTrue(biz.instruments(CREDIT).configured);
        assertEq(biz.instruments(CREDIT).supplyCap, 1000);
        assertEq(biz.instruments(CREDIT).minBuyInCents, 10_000);

        assertTrue(biz.instruments(BOND).configured);
        assertEq(biz.instruments(BOND).supplyCap, 1000);
        assertEq(biz.instruments(BOND).minBuyInCents, 100_000);
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
        // 5% entitlement (500 bps), round $1000 USDC = 1000e6 raw
        uint256 tokenId = _mint(user, YIELD, 50_000, 500, VEST_END, YIELD_START);
        vm.warp(VEST_END);
        biz.unlock(tokenId);
        vm.warp(YIELD_START);

        uint256 roundRaw = 1_000 * 1e6;
        _fundYieldRound(roundRaw);

        uint256 expected = (roundRaw * 500) / 10_000; // 50 USDC
        assertEq(biz.claimable(tokenId), expected);

        uint256 balBefore = usdcToken.balanceOf(user);
        vm.prank(user);
        uint256 paid = biz.claim(tokenId);
        assertEq(paid, expected);
        assertEq(usdcToken.balanceOf(user) - balBefore, expected);

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
        uint64 t0 = 1_000_000;
        vm.warp(t0);
        uint256 tokenId = _mint(user, CREDIT, 10_000, 0, 0, 0); // $100

        uint256 totalPayoutCents = (10_000 * 10_404) / 10_000; // 10404
        uint256 weeklyCents = totalPayoutCents / 12; // 867
        uint256 weeklyRaw = AmountCodec.centsToRaw(weeklyCents, 6);
        uint256 totalRaw = weeklyRaw * 12;

        _fundPool(totalRaw + 1e6);

        // immediately at purchase: nothing claimable
        assertEq(biz.claimable(tokenId), 0);

        // before end of week 1
        vm.warp(t0 + 7 days - 1);
        assertEq(biz.claimable(tokenId), 0);

        // week 1 (end of first week)
        vm.warp(t0 + 7 days);
        assertEq(biz.claimable(tokenId), weeklyRaw);
        vm.prank(user);
        assertEq(biz.claim(tokenId), weeklyRaw);

        // jump to end of all 12 weeks
        vm.warp(t0 + 12 * 7 days);
        uint256 remaining = weeklyRaw * 11;
        assertEq(biz.claimable(tokenId), remaining);
        vm.prank(user);
        assertEq(biz.claim(tokenId), remaining);

        assertEq(uint8(biz.certificates(tokenId).status), uint8(IBizSwap.Status.Redeemed));
        assertEq(usdcToken.balanceOf(user), totalRaw);
    }

    function test_Credit_InsufficientPool() public {
        uint64 t0 = 1_000_000;
        vm.warp(t0);
        uint256 tokenId = _mint(user, CREDIT, 10_000, 0, 0, 0);
        vm.warp(t0 + 12 * 7 days);
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
        uint256 principalRaw = AmountCodec.centsToRaw(100_000, 6); // $1000 = 1000e6
        uint256 totalBondPayout = quarterRaw * 4 + principalRaw; // $1,100 total
        _fundPool(totalBondPayout);

        // quarter 0 at yieldStart
        vm.warp(YIELD_START);
        assertEq(biz.claimable(tokenId), quarterRaw);
        vm.prank(user);
        assertEq(biz.claim(tokenId), quarterRaw);

        // quarter 1 at yieldStart + 90 days
        vm.warp(YIELD_START + 90 days);
        assertEq(biz.claimable(tokenId), quarterRaw);
        vm.prank(user);
        assertEq(biz.claim(tokenId), quarterRaw);

        // quarter 2 at yieldStart + 180 days
        vm.warp(YIELD_START + 2 * 90 days);
        assertEq(biz.claimable(tokenId), quarterRaw);
        vm.prank(user);
        assertEq(biz.claim(tokenId), quarterRaw);

        // quarter 3 (final quarter 4) at yieldStart + 270 days: pays coupon + principal ($1,025)
        vm.warp(YIELD_START + 3 * 90 days);
        uint256 finalDue = quarterRaw + principalRaw;
        assertEq(biz.claimable(tokenId), finalDue);
        vm.prank(user);
        assertEq(biz.claim(tokenId), finalDue);

        assertEq(uint8(biz.certificates(tokenId).status), uint8(IBizSwap.Status.Redeemed));
        assertEq(biz.claimable(tokenId), 0);
        assertEq(usdcToken.balanceOf(user), totalBondPayout);
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
        usdcToken.mint(user, 1e6);
        vm.startPrank(user);
        usdcToken.approve(address(biz), 1e6);
        vm.expectRevert();
        biz.depositDistributionUsdc(CREDIT, 1e6);
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

    function test_Upgrade_DeployerCanUpgrade() public {
        BizSwapV2 v2 = new BizSwapV2();
        vm.prank(deployer);
        biz.upgradeToAndCall(address(v2), "");
        assertEq(BizSwapV2(address(biz)).version(), "v2");
    }

    function test_Upgrade_AdminCanUpgrade() public {
        BizSwapV2 v2 = new BizSwapV2();
        vm.prank(admin);
        biz.upgradeToAndCall(address(v2), "");
        assertEq(BizSwapV2(address(biz)).version(), "v2");
    }

    function test_Upgrade_UnauthorizedReverts() public {
        BizSwapV2 v2 = new BizSwapV2();
        vm.prank(user);
        vm.expectRevert();
        biz.upgradeToAndCall(address(v2), "");
    }

    function test_DeployerCannotExecuteAdminFunctions() public {
        vm.startPrank(deployer);

        vm.expectRevert();
        biz.configureInstrument(YIELD, 500, 500);

        vm.expectRevert();
        biz.configureSchedules(7 days, 12, 10_404, 90 days, 4, 250);

        vm.expectRevert();
        biz.lockSchedules();

        vm.expectRevert();
        biz.setClaimsPaused(true);

        vm.expectRevert();
        biz.setRevenueWallet(other);

        vm.expectRevert();
        biz.mintCertificate(other, YIELD, 1_000, 500, VEST_END, YIELD_START, bytes32("2026-MAY"), "ipfs://x");

        vm.expectRevert();
        biz.openYieldRound(10e6);

        vm.stopPrank();
    }

    function test_DeployerCannotGrantRoles() public {
        bytes32 minterRole = biz.MINTER_ROLE();
        vm.prank(deployer);
        vm.expectRevert();
        biz.grantRole(minterRole, other);
    }

    // ─── Security Bounds & Invariants ────────────────────────────────────────

    function test_Mint_EntitlementTooHigh_Reverts() public {
        vm.prank(minter);
        vm.expectRevert(IBizSwap.EntitlementTooHigh.selector);
        biz.mintCertificate(user, YIELD, 1_000, 10_001, VEST_END, YIELD_START, bytes32("2026-MAY"), "ipfs://x");

        vm.prank(minter);
        biz.mintCertificate(user, YIELD, 1_000, 10_000, VEST_END, YIELD_START, bytes32("2026-MAY"), "ipfs://x");
    }

    function test_YieldMint_RevertIf_AggregateEntitlementExceeds100Percent() public {
        _mint(user, YIELD, 1_000, 6_000, VEST_END, YIELD_START);
        assertEq(biz.totalYieldEntitlementBps(), 6_000);

        vm.prank(minter);
        vm.expectRevert(IBizSwap.EntitlementTooHigh.selector);
        biz.mintCertificate(other, YIELD, 1_000, 4_001, VEST_END, YIELD_START, bytes32("2026-MAY"), "ipfs://x");

        _mint(other, YIELD, 1_000, 4_000, VEST_END, YIELD_START);
        assertEq(biz.totalYieldEntitlementBps(), 10_000);

        vm.prank(minter);
        vm.expectRevert(IBizSwap.EntitlementTooHigh.selector);
        biz.mintCertificate(other, YIELD, 1_000, 1, VEST_END, YIELD_START, bytes32("2026-MAY"), "ipfs://x");
    }

    function test_Gap3_YieldRoundCap24() public {
        assertEq(biz.MAX_YIELD_ROUNDS(), 24);

        for (uint256 i = 0; i < 24; i++) {
            _fundYieldRound(10e6);
        }
        assertEq(biz.nextYieldRoundId(), 25);

        usdcToken.mint(admin, 10e6);
        vm.startPrank(admin);
        usdcToken.approve(address(biz), 10e6);
        vm.expectRevert(IBizSwap.MaxYieldRoundsReached.selector);
        biz.openYieldRound(10e6);
        vm.stopPrank();
    }

    function test_Gap3_YieldBatchClaim_Pagination() public {
        uint256 tokenId = _mint(user, YIELD, 1_000, 1_000, VEST_END, YIELD_START);
        vm.warp(VEST_END);
        biz.unlock(tokenId);
        vm.warp(YIELD_START);

        for (uint256 i = 0; i < 10; i++) {
            _fundYieldRound(100e6);
        }

        vm.prank(user);
        uint256 paid1 = biz.claim(tokenId, 4);
        assertEq(paid1, 40e6);

        uint256 claimableNext4 = biz.claimable(tokenId, 4);
        assertEq(claimableNext4, 40e6);

        uint256 claimableRemaining = biz.claimable(tokenId, 0);
        assertEq(claimableRemaining, 60e6);

        vm.prank(user);
        uint256 paid2 = biz.claim(tokenId, 10);
        assertEq(paid2, 60e6);

        vm.prank(user);
        vm.expectRevert(IBizSwap.NothingToClaim.selector);
        biz.claim(tokenId);
    }

    function test_Gap4_IsolatedCreditAndBondPools() public {
        usdcToken.mint(admin, 2_000e6);
        vm.startPrank(admin);
        usdcToken.approve(address(biz), 2_000e6);

        biz.depositDistributionUsdc(CREDIT, 1_200e6);
        biz.depositDistributionUsdc(BOND, 800e6);

        assertEq(biz.creditPoolUsdcRaw(), 1_200e6);
        assertEq(biz.bondPoolUsdcRaw(), 800e6);
        assertEq(biz.distributionPoolUsdcRaw(), 2_000e6);

        vm.expectRevert(IBizSwap.InvalidInstrument.selector);
        biz.depositDistributionUsdc(YIELD, 100e6);
        vm.stopPrank();

        uint256 creditId = _mint(user, CREDIT, 10_000, 0, 0, 0);
        uint256 bondId = _mint(other, BOND, 100_000, 0, 1_000_000, 1_000_000);

        vm.warp(1_000_000);
        biz.unlock(bondId);
        uint256 creditClaimable = biz.claimable(creditId);
        assertTrue(creditClaimable > 0);

        vm.prank(user);
        uint256 paidCredit = biz.claim(creditId);
        assertEq(paidCredit, creditClaimable);
        assertEq(biz.creditPoolUsdcRaw(), 1_200e6 - paidCredit);
        assertEq(biz.bondPoolUsdcRaw(), 800e6);

        vm.warp(1_000_000 + 90 days);
        uint256 bondClaimable = biz.claimable(bondId);
        assertTrue(bondClaimable > 0);

        vm.prank(other);
        uint256 paidBond = biz.claim(bondId);
        assertEq(paidBond, bondClaimable);
        assertEq(biz.bondPoolUsdcRaw(), 800e6 - paidBond);
    }

    function test_Gap5_AutoUnlockOnTransfer() public {
        uint64 vestEnd = uint64(block.timestamp + 30 days);
        uint256 tokenId = _mint(user, YIELD, 1_000, 500, vestEnd, vestEnd);

        IBizSwap.Certificate memory cert = biz.certificates(tokenId);
        assertEq(uint8(cert.status), uint8(IBizSwap.Status.Vesting));

        vm.prank(user);
        vm.expectRevert(IBizSwap.TransferWhileVesting.selector);
        biz.transferFrom(user, other, tokenId);

        vm.warp(vestEnd + 1);

        vm.prank(user);
        biz.transferFrom(user, other, tokenId);

        assertEq(biz.ownerOf(tokenId), other);
        cert = biz.certificates(tokenId);
        assertEq(uint8(cert.status), uint8(IBizSwap.Status.Active));
    }

    function test_Gap6_CreditRemainderCentsDelivered() public {
        // Principal = 10,001 cents ($100.01)
        // Total return bps = 10,404 -> total return = (10,001 * 10,404) / 10,000 = 10,405 cents
        // 10,405 / 12 = 867 cents per week
        // 10,405 % 12 = 1 cent remainder
        // Weekly raw: 867 cents = 8.67 USDC = 8_670_000 raw units
        // Week 12: 867 + 1 = 868 cents = 8.68 USDC = 8_680_000 raw units
        // Total expected = 10,405 cents = 104.05 USDC = 104_050_000 raw units
        uint64 t0 = 1_000_000;
        vm.warp(t0);
        uint256 principalCents = 10_001;
        uint256 tokenId = _mint(user, CREDIT, principalCents, 0, 0, 0);

        _fundPool(200e6);

        uint256 totalPaid = 0;
        for (uint256 week = 1; week <= 12; week++) {
            vm.warp(t0 + week * 7 days);
            vm.prank(user);
            uint256 paid = biz.claim(tokenId);
            totalPaid += paid;
            if (week < 12) {
                assertEq(paid, 8_670_000);
            } else {
                // Final week (week 12) receives weekly payout plus the 1 cent remainder
                assertEq(paid, 8_680_000);
            }
        }

        uint256 expectedTotalCents = (principalCents * 10_404) / 10_000;
        uint256 expectedTotalRaw = AmountCodec.centsToRaw(expectedTotalCents, 6);
        assertEq(totalPaid, expectedTotalRaw);
        assertEq(totalPaid, 104_050_000);
    }

    function test_Gap7_AggregateYieldEntitlementCap() public {
        assertEq(biz.totalYieldEntitlementBps(), 0);

        _mint(user, YIELD, 1_000, 4_000, VEST_END, YIELD_START);
        assertEq(biz.totalYieldEntitlementBps(), 4_000);

        _mint(other, YIELD, 1_000, 5_000, VEST_END, YIELD_START);
        assertEq(biz.totalYieldEntitlementBps(), 9_000);

        vm.prank(minter);
        vm.expectRevert(IBizSwap.EntitlementTooHigh.selector);
        biz.mintCertificate(user, YIELD, 1_000, 1_001, VEST_END, YIELD_START, bytes32("2026-MAY"), "ipfs://x");

        _mint(user, YIELD, 1_000, 1_000, VEST_END, YIELD_START);
        assertEq(biz.totalYieldEntitlementBps(), 10_000);

        vm.prank(minter);
        vm.expectRevert(IBizSwap.EntitlementTooHigh.selector);
        biz.mintCertificate(user, YIELD, 1_000, 1, VEST_END, YIELD_START, bytes32("2026-MAY"), "ipfs://x");

        _mint(user, CREDIT, 10_000, 0, 0, 0);
        assertEq(biz.totalYieldEntitlementBps(), 10_000);
    }

    function test_CloseYieldRound_BookkeepingOnly() public {
        uint256 tokenId = _mint(user, YIELD, 50_000, 500, VEST_END, YIELD_START);
        vm.warp(VEST_END);
        biz.unlock(tokenId);
        vm.warp(YIELD_START);

        uint256 roundRaw = 1_000e6;
        uint256 roundId = _fundYieldRound(roundRaw);

        vm.prank(admin);
        biz.closeYieldRound(roundId);

        IBizSwap.YieldRound memory round = biz.yieldRounds(roundId);
        assertTrue(round.closed);

        uint256 expected = (roundRaw * 500) / 10_000;
        assertEq(biz.claimable(tokenId), expected);
        vm.prank(user);
        uint256 paid = biz.claim(tokenId);
        assertEq(paid, expected);
    }

    function test_CloseYieldRound_AlreadyClosed_Reverts() public {
        uint256 roundId = _fundYieldRound(100e6);

        vm.prank(admin);
        biz.closeYieldRound(roundId);

        vm.prank(admin);
        vm.expectRevert(IBizSwap.RoundAlreadyClosed.selector);
        biz.closeYieldRound(roundId);
    }

    function test_LockSchedules_PreventsChange() public {
        vm.prank(admin);
        biz.lockSchedules();
        assertTrue(biz.schedulesLocked());

        vm.prank(admin);
        vm.expectRevert(IBizSwap.SchedulesAreLocked.selector);
        biz.configureSchedules({
            creditWeekSeconds_: 7 days,
            creditWeekCount_: 12,
            creditTotalReturnBps_: 10_404,
            bondQuarterSeconds_: 90 days,
            bondMaxQuarters_: 4,
            bondQuarterBps_: 250
        });
    }

    function test_ClaimsPaused_EmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true, address(biz));
        emit IBizSwap.ClaimsPausedChanged(true);
        biz.setClaimsPaused(true);

        vm.prank(admin);
        vm.expectEmit(false, false, false, true, address(biz));
        emit IBizSwap.ClaimsPausedChanged(false);
        biz.setClaimsPaused(false);
    }

    function test_YieldClaim_MultipleRounds_Optimized() public {
        uint256 tokenId = _mint(user, YIELD, 1_000, 1_000, VEST_END, YIELD_START);
        vm.warp(VEST_END);
        biz.unlock(tokenId);
        vm.warp(YIELD_START);

        uint256 roundRaw = 100e6; // $100 each
        _fundYieldRound(roundRaw);
        _fundYieldRound(roundRaw);
        _fundYieldRound(roundRaw);

        uint256 perRound = (roundRaw * 1_000) / 10_000; // $10 per round

        vm.prank(user);
        uint256 paid = biz.claim(tokenId);
        assertEq(paid, perRound * 3);

        _fundYieldRound(roundRaw);

        vm.prank(user);
        uint256 paid2 = biz.claim(tokenId);
        assertEq(paid2, perRound);

        vm.prank(user);
        vm.expectRevert(IBizSwap.NothingToClaim.selector);
        biz.claim(tokenId);
    }

    // ─── Arc-Specific EVM Checks ─────────────────────────────────────────────

    function test_Arc_RevertIf_NativeValueSent() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(biz).call{value: 1}("");
        assertFalse(ok, "Direct native value transfer must revert on Arc");
    }

    function test_Arc_CanonicalPredeployAddressConfig() public {
        address canonicalUSDC = 0x3600000000000000000000000000000000000000;
        BizSwap arcBiz = _deploy(admin, minter, revenue, deployer, canonicalUSDC);
        assertEq(arcBiz.usdc(), canonicalUSDC);
        assertEq(arcBiz.usdcDecimals(), 6);
    }

    // ─── Gap 1 & Gap 2 Remediations ──────────────────────────────────────────

    function test_Gap1_Bond_AnnualMaturityAndPrincipalReturn() public {
        assertEq(biz.bondMaxQuarters(), 4);

        uint256 bondId = _mint(user, BOND, 100_000, 0, VEST_END, YIELD_START); // $1,000 unit
        vm.warp(VEST_END);
        biz.unlock(bondId);

        uint256 quarterRaw = AmountCodec.centsToRaw(2_500, 6); // $25 USDC
        uint256 principalRaw = AmountCodec.centsToRaw(100_000, 6); // $1,000 USDC
        _fundPool(quarterRaw * 4 + principalRaw);

        // Q0, Q1, Q2 pay only quarterly coupons ($25 each)
        for (uint8 q = 0; q < 3; q++) {
            vm.warp(YIELD_START + uint256(q) * 90 days);
            assertEq(biz.claimable(bondId), quarterRaw);
            vm.prank(user);
            uint256 paid = biz.claim(bondId);
            assertEq(paid, quarterRaw);
            assertEq(uint8(biz.certificates(bondId).status), uint8(IBizSwap.Status.Active));
        }

        // Q3 (the 4th and final quarter) pays $25 coupon + $1,000 principal = $1,025
        vm.warp(YIELD_START + 3 * 90 days);
        uint256 expectedFinal = quarterRaw + principalRaw; // 1,025 USDC
        assertEq(biz.claimable(bondId), expectedFinal);

        vm.prank(user);
        uint256 paidFinal = biz.claim(bondId);
        assertEq(paidFinal, expectedFinal);
        assertEq(paidFinal, 1_025e6);

        // Certificate is now redeemed
        assertEq(uint8(biz.certificates(bondId).status), uint8(IBizSwap.Status.Redeemed));
        assertEq(biz.claimable(bondId), 0);

        // Total received across all 4 quarters: $1,100 USDC
        assertEq(usdcToken.balanceOf(user), 1_100e6);
    }

    function test_Gap2_Credit_NoRetroactiveDrain_StaggeredPurchases() public {
        uint64 t0 = 1_000_000;
        vm.warp(t0);

        // Early buyer purchases at t0
        uint256 certEarly = _mint(user, CREDIT, 10_000, 0, 0, 0); // $100

        // Fund credit distribution pool
        _fundPool(1_000e6);

        // At purchase time: early buyer cannot claim anything
        assertEq(biz.claimable(certEarly), 0);

        // Advance 30 days (approx 4.2 weeks)
        uint64 tLate = t0 + 30 days;
        vm.warp(tLate);

        // Late buyer purchases at t0 + 30 days
        uint256 certLate = _mint(other, CREDIT, 10_000, 0, 0, 0); // $100

        // Early buyer has 4 weeks matured (30 days >= 4 * 7 days = 28 days)
        uint256 weeklyRaw = AmountCodec.centsToRaw(867, 6); // 8.67 USDC
        assertEq(biz.claimable(certEarly), weeklyRaw * 4);

        // CRITICAL CHECK: Late buyer has ZERO claimable immediately at purchase time!
        // No retroactive drain of elapsed calendar weeks!
        assertEq(biz.claimable(certLate), 0);
        vm.prank(other);
        vm.expectRevert(IBizSwap.NothingToClaim.selector);
        biz.claim(certLate);

        // Advance 7 days from late buyer's purchase (tLate + 7 days)
        vm.warp(tLate + 7 days);

        // Now late buyer has exactly 1 week ($8.67) claimable
        assertEq(biz.claimable(certLate), weeklyRaw);
        vm.prank(other);
        uint256 paidLate = biz.claim(certLate);
        assertEq(paidLate, weeklyRaw);
        assertEq(paidLate, 8_670_000);
    }
}
