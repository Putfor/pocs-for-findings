// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

// Reproduction:
//   git clone https://github.com/Cyfrin/2023-12-the-standard && cd 2023-12-the-standard
//   npm install
//   forge install foundry-rs/forge-std --no-commit
//   # foundry.toml: src="contracts", test="test", libs=["lib","node_modules"]
//   # remappings: forge-std/=lib/forge-std/src/, @openzeppelin/=node_modules/@openzeppelin/,
//   #             @chainlink/=node_modules/@chainlink/, contracts/=contracts/
//   forge test --match-contract PoC_M02 -vvvv

import "forge-std/Test.sol";
import {LiquidationPool} from "contracts/LiquidationPool.sol";
import {LiquidationPoolManager} from "contracts/LiquidationPoolManager.sol";
import {ILiquidationPoolManager} from "contracts/interfaces/ILiquidationPoolManager.sol";
import {ITokenManager} from "contracts/interfaces/ITokenManager.sol";
import {ERC20Mock} from "contracts/utils/ERC20Mock.sol";
import {EUROsMock} from "contracts/utils/EUROsMock.sol";
import {ChainlinkMock} from "contracts/utils/ChainlinkMock.sol";
import {TokenManagerMock} from "contracts/utils/TokenManagerMock.sol";

// Minimal SmartVaultManager stub required by LiquidationPoolManager constructor.
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

/// @title  PoC — M-02: Ghost holder excluded from liquidation rewards
///
/// @notice Root cause: `empty()` checks only `positions[]` and ignores `pendingStakes[]`.
///         When a staker adds a new pending stake and then fully withdraws their
///         consolidated position in the same block, `empty()` returns true and
///         `deleteHolder()` removes them from `holders[]` — even though a pending
///         stake still exists on their behalf.
///
///         On the next liquidation, `consolidatePendingStakes()` moves the pending
///         stake into `positions[]`, but `holders[]` is never updated.
///         The distribution loop iterates only `holders[]`, so the ghost holder
///         receives zero rewards despite having an active, consolidated position.
///
/// @dev    Run: forge test --match-contract PoC_M02 -vvvv
contract PoC_M02 is Test {
    LiquidationPool pool;
    LiquidationPoolManager poolManager;
    ERC20Mock TST;
    EUROsMock EUROs;
    ChainlinkMock clEthUsd;
    ChainlinkMock clEurUsd;
    TokenManagerMock tokenManager;

    address owner = makeAddr("owner");
    address protocol = makeAddr("protocol");
    address bob = makeAddr("bob"); // honest staker, always in holders[]
    address alice = makeAddr("alice"); // victim — becomes a ghost holder

    int256 constant ETH_PRICE = 2_000e8; // $2 000, Chainlink 8-dec format
    int256 constant EUR_PRICE = 110e6; // $1.10
    uint256 constant BOB_STAKE = 1_000e18;
    uint256 constant ALICE_STAKE = 1_000e18;
    uint256 constant ALICE_EXTRA = 100e18; // second deposit that creates the pending stake
    // ETH sent as liquidation reward; sized so Bob's costInEuros < his EUROs position.
    //   costInEuros(0.5 ETH) = 0.5e18 * 2000e8 / 110e6 * 100_000 / 120_000 ≈ 757 EUROs
    //   Bob has 1 000 EUROs → no cap triggered → clean calculation.
    uint256 constant LIQUIDATION_ETH = 0.5 ether;

    function setUp() public {
        vm.warp(1 days); // avoid ChainlinkMock underflow (setPrice uses timestamp - 4h)
        vm.deal(bob, 10 ether);
        vm.deal(alice, 10 ether);

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

        // Mint enough for both the initial stake and Alice's second deposit
        TST.mint(bob, BOB_STAKE);
        TST.mint(alice, ALICE_STAKE + ALICE_EXTRA);
        EUROs.mint(bob, BOB_STAKE);
        EUROs.mint(alice, ALICE_STAKE + ALICE_EXTRA);

        vm.stopPrank();

        // Bob and Alice make their initial stakes (both enter pendingStakes[])
        _stake(bob, BOB_STAKE);
        _stake(alice, ALICE_STAKE);

        // Advance past the 24-hour lock-up and consolidate both positions
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        pool.decreasePosition(0, 0); // triggers consolidatePendingStakes() for everyone
        // State: positions[bob]=(1000,1000), positions[alice]=(1000,1000), holders=[bob,alice]
    }

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        TST.approve(address(pool), amount);
        EUROs.approve(address(pool), amount);
        pool.increasePosition(amount, amount);
        vm.stopPrank();
    }

    /// @notice Ghost holder scenario:
    ///
    ///   1. Alice adds a new pending stake (100 TST + 100 EUROs).
    ///      addUniqueHolder() is a no-op — she is already in holders[].
    ///
    ///   2. Alice immediately withdraws her entire consolidated position (1000, 1000).
    ///      consolidatePendingStakes() inside decreasePosition() does NOT consolidate
    ///      Alice's step-1 stake yet (< 24 h old) → positions[Alice] drops to (0, 0).
    ///      empty() returns true → deleteHolder(Alice) → Alice REMOVED from holders[].
    ///
    ///   3. 24 h later a vault is liquidated. distributeAssets() calls
    ///      consolidatePendingStakes() → Alice's pending stake becomes positions[Alice]=(100,100).
    ///      However, addUniqueHolder() is never called during consolidation,
    ///      so Alice is NOT in holders[].
    ///
    ///   4. The distribution loop runs over holders[] = [bob] only.
    ///      Bob receives 100% of the liquidation ETH.
    ///      Alice receives 0, despite having a fully consolidated active position.
    function test_M02_ghost_holder() public {
        // ── Step 1-2: Alice creates a pending stake then empties her consolidated position ──

        vm.startPrank(alice);
        TST.approve(address(pool), ALICE_EXTRA);
        EUROs.approve(address(pool), ALICE_EXTRA);
        pool.increasePosition(ALICE_EXTRA, ALICE_EXTRA); // pending stake added, Alice still in holders[]
        pool.decreasePosition(ALICE_STAKE, ALICE_STAKE); // positions[alice]=(0,0) → empty() → deleteHolder(alice)
        vm.stopPrank();
        // State: holders=[bob], pendingStakes=[{alice, now, 100, 100}]

        // ── Step 3: Advance time — Alice's pending stake is now eligible for consolidation ──

        vm.warp(block.timestamp + 1 days + 1);

        // ── Step 4: Simulate a liquidation via poolManager ──

        ILiquidationPoolManager.Asset[] memory assets = new ILiquidationPoolManager.Asset[](1);
        assets[0] = ILiquidationPoolManager.Asset(
            ITokenManager.Token({
                symbol: bytes32("ETH"),
                addr: address(0), // native ETH
                dec: 18,
                clAddr: address(clEthUsd),
                clDec: 8
            }),
            LIQUIDATION_ETH
        );

        // Call as the legitimate manager (isolates M-02 from H-01 access-control issue).
        // Inside distributeAssets():
        //   consolidatePendingStakes() → positions[alice]=(100,100) but holders[] unchanged
        //   loop over holders=[bob] → bob gets everything, alice is never visited
        vm.deal(address(poolManager), LIQUIDATION_ETH);
        vm.prank(address(poolManager));
        pool.distributeAssets{value: LIQUIDATION_ETH}(assets, 120_000, 100_000);

        // ── Assertions ──

        // Alice's pending stake was consolidated — she has an active position
        (
            LiquidationPool.Position memory alicePos,
            LiquidationPool.Reward[] memory aliceRewards
        ) = pool.position(alice);

        (, LiquidationPool.Reward[] memory bobRewards) = pool.position(bob);

        console.log("Alice TST position (consolidated from pending):", alicePos.TST / 1e18);
        console.log("Alice ETH reward  :", aliceRewards[0].amount);
        console.log("Bob   ETH reward  :", bobRewards[0].amount);

        // Alice has an active, consolidated stake — she is NOT a zero-balance ghost
        assertEq(alicePos.TST, ALICE_EXTRA, "Alice has active TST position after consolidation");

        // Despite an active position, Alice receives zero liquidation rewards
        assertEq(aliceRewards[0].amount, 0, "Alice must receive zero rewards (ghost holder bug)");

        // Bob receives 100% of the distributed ETH; his fair share was ~90.9%
        // (1000 / (1000+100) ≈ 90.9%); the delta is Alice's stolen portion
        assertEq(
            bobRewards[0].amount,
            LIQUIDATION_ETH,
            "Bob receives 100% of rewards instead of his proportional share"
        );
    }

    // -----------------------------------------------------------------------
    // FINDING CARD
    // -----------------------------------------------------------------------
    //
    //  ID:        M-02
    //  Title:     Incorrect empty() predicate causes ghost holders in LiquidationPool
    //  Severity:  Medium
    //  Contract:  LiquidationPool.sol  L92-L94
    //  Function:  empty(Position memory _position) — called inside decreasePosition()
    //
    //  Root cause: Incorrect empty() predicate
    //    empty() returns true when positions[holder].TST == 0 && EUROs == 0,
    //    without checking whether a pending stake exists for the same address.
    //    A holder is therefore evicted from holders[] while still having funds
    //    queued in pendingStakes[], creating a "ghost holder" state.
    //
    //  Impact:
    //    The ghost holder's pending stake is later consolidated into positions[]
    //    by consolidatePendingStakes(), but since they are absent from holders[],
    //    the distribution loop in distributeAssets() never visits them.
    //    Their share of liquidation rewards is silently forfeited to other stakers.
    //
    //  Recommendation:
    //    Extend empty() to also check pendingStakes[] before declaring a position
    //    empty. Change the visibility from pure to view:
    //
    //  - function empty(Position memory _position) private pure returns (bool) {
    //  -     return _position.TST == 0 && _position.EUROs == 0;
    //  - }
    //
    //  + function empty(Position memory _position) private view returns (bool) {
    //  +     if (_position.TST != 0 || _position.EUROs != 0) return false;
    //  +     for (uint256 i = 0; i < pendingStakes.length; i++) {
    //  +         if (pendingStakes[i].holder == _position.holder) return false;
    //  +     }
    //  +     return true;
    //  + }
}
