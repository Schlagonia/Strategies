// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries

import {
    BaseStrategy,
    StrategyParams
} from "./BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import "./interfaces/curve/ICurveFi.sol";
import "./interfaces/Convex/IConvexDeposit.sol";
import "./interfaces/Convex/IConvexRewards.sol";
import "./interfaces/uni/IUniswapV2Router02.sol";
import "./interfaces/aave/V2/IAaveIncentivesController.sol";
import "./interfaces/aave/V2/IStakedAave.sol";
import "./interfaces/aave/V2/ILendingPool.sol";
import "./interfaces/aave/V2/IProtocolDataProvider.sol";
import "./interfaces/aave/V2/ILendingPoolAddressesProvider.sol";
import "./interfaces/chainlink/AggregatorV3Interface.sol";

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);
}

contract Caave is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address constant uniRouter = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address constant sushiswapRouter = address(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    //Will start to use sushi due to higher liquidity for cvx
    IUniswapV2Router02 public router;

    //aave Contracts
    ILendingPool public lendingPool; //0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9
    IProtocolDataProvider private constant protocolDataProvider =
        IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);
    IAaveIncentivesController private constant aaveIncentivesController = 
        IAaveIncentivesController(0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5);
    bool aaveIsIncentivized; //To check if we are earning rewards on Aave deposits/borrows

    //curve contracts
    ICurveFi public crvPool; // 0xD51a44d3FaE010294C616388b506AcdA1bfAAE46\
    address constant crvToken = address(0xc4AD29ba4B3c580e6D59105FFf484999997675Ff);

    //Convex contracts
    // this is the deposit contract that all pools use, aka booster
    IConvexDeposit public depositContract = IConvexDeposit(0xF403C135812408BFbE8713b5A23a04b3D48AAE31); 
     // This is unique to each curve pool, this one is for 3Crypto
    IConvexRewards public rewardsContract = IConvexRewards(0x9D5C5E364D81DaB193b72db9E9BE9D8ee669B652);
    uint256 public pid = 38; // this is unique to each pool
    bool harvestExtras = true; //If we chould claim extras on harvests

    //ChainLink Price Feeds
    AggregatorV3Interface internal btcPriceFeed = AggregatorV3Interface(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c);
    AggregatorV3Interface internal ethPriceFeed = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

    //borrow tokens
    address constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address constant wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    address constant usdt = address(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    //reward tokens
    address constant crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    address public constant cvx = address(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B); //need to add approvals
    address constant aave = address(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);
    IStakedAave public constant stkAave = IStakedAave(0x4da27a545c0c5B758a6BA100e3a049001de870f5);

    //aave tokens
    address aWant; 
    address varWbtc; 
    address varWeth;
    address varUsdt; 

    //used along the denominator or 10,000
    uint256 targetCollatRatio = 6000; // The LTV we are levering up to
    uint256 adjustedTargetCollat; //decimal adjusted
    uint256 lowerCollatBound = 5000; // the lower bound that will cause us to rebalance
    uint256 adjustedLowerBound; //decimal adjusted collateral
    uint256 upperCollatBound = 7000; //the upper bound that will cause us to rebalance
    uint256 adjustedUpperBound; //decimal adjusted lower bound
    uint256 maxCollatRatio = 8000; // Closest to liquidation we'll risk
    uint256 curveMultiplier = 6000; // amount to multiply deposits by to determin total curve deposits
    uint256 third = 3333; // get a third with den for deposit calcs

    uint256 maxSingleInvest;
    uint256 slippageProtectionIn = 50; //out of 10000. 50 = 0.5%
    uint256 slippageProtectionOut = 50; //out of 10000. 50 = 0.5%
    uint256 crvSlippage = 30; // amount for curve liq all functions
    uint256 constant DENOMINATOR = 10_000;
    uint256 constant denomPrecision = 4;

    //underlying token 
    //For the TriCrypto pool
    uint256 usdtIndex = 0;
    uint256 wbtcIndex = 1;
    uint256 wethIndex = 2;

    mapping(address => uint256) index;

    uint256 want_decimals;
    uint256 minWant;
    uint256 minCrv;
    uint256 minCvx;
    uint256 minAave;

    uint256 lastHarvest;
    uint256 minReport = 0; //1000

    constructor(
        address _vault,
        address _crvPool,
        bool _aaveIsIncentivized
    ) public BaseStrategy(_vault) {
        _initializeThis(_crvPool, _aaveIsIncentivized);
    }

    function _initializeThis(
        address _crvPool,
        bool _aaveIsIncentivized
    ) internal {
        // Set aave tokens
        address _lendingPool = ILendingPoolAddressesProvider(protocolDataProvider.ADDRESSES_PROVIDER()).getLendingPool();
     
        (aWant, , ) =
            protocolDataProvider.getReserveTokensAddresses(address(want));

        (, , varWeth) =
            protocolDataProvider.getReserveTokensAddresses(weth);
        

        (, , varWbtc) =
            protocolDataProvider.getReserveTokensAddresses(wbtc);

        (, , varUsdt) =
            protocolDataProvider.getReserveTokensAddresses(usdt);
        
        //Set addresses and approve tokens
        setCrvPool(_crvPool);
        setLendingPool(_lendingPool);
        approveDepositContract();
        approveRouter(sushiswapRouter);
        
        want_decimals = IERC20Extended(address(want)).decimals();

        //what we need to multiply collat amounts by difference in decimals to want to adjust for want decimals
        adjustedUpperBound = upperCollatBound.mul((10 **(want_decimals.sub(denomPrecision))));
        adjustedLowerBound = lowerCollatBound.mul((10 **(want_decimals.sub(denomPrecision))));
        adjustedTargetCollat = targetCollatRatio.mul((10 **(want_decimals.sub(denomPrecision))));

        minWant = 10 ** (want_decimals.sub(3));
        minCrv = 1e16; 
        minCvx = 1e15;
        minAave = 1e14; 
        maxSingleInvest = 10 ** (want_decimals.add(6));
        lastHarvest = block.timestamp;

        //Set index mapping for crv Pools
        index[usdt] = usdtIndex;
        index[wbtc] = wbtcIndex;
        index[weth] = wethIndex;
        
        aaveIsIncentivized = _aaveIsIncentivized;
    }

    function setCrvPool(address _crvPool) internal {
        IERC20(wbtc).safeApprove(_crvPool, type(uint256).max);
        IERC20(weth).safeApprove(_crvPool, type(uint256).max);
        IERC20(usdt).safeApprove(_crvPool, type(uint256).max);
        IERC20(crvToken).safeApprove(_crvPool, type(uint256).max);

        crvPool = ICurveFi(_crvPool);
    }

    function approveDepositContract() internal {
        IERC20(crvToken).safeApprove(address(depositContract), type(uint256).max);
    }

    function approveRouter(address _router) internal {
        want.safeApprove(_router, type(uint256).max);
        IERC20(aave).safeApprove(_router, type(uint256).max);
        IERC20(crv).safeApprove(_router, type(uint256).max);
        IERC20(cvx).safeApprove(_router, type(uint256).max);
        IERC20(usdt).safeApprove(_router, type(uint256).max);
        IERC20(wbtc).safeApprove(_router, type(uint256).max);
        IERC20(weth).safeApprove(_router, type(uint256).max);

        router = IUniswapV2Router02(_router);
    }

    function changeRouter() external {
        address _router = address(router) == sushiswapRouter ? uniRouter : sushiswapRouter;
        approveRouter(_router);
    }

    function setLendingPool(address _pool) internal {
        want.safeApprove(_pool, type(uint256).max);
        IERC20(wbtc).safeApprove(_pool, type(uint256).max);
        IERC20(weth).safeApprove(_pool, type(uint256).max);
        IERC20(usdt).safeApprove(_pool, type(uint256).max);

        lendingPool = ILendingPool(_pool);
    }

    function updateAaveIsIncentivized(bool _aaveIsIncentivized) external onlyAuthorized {
        aaveIsIncentivized = _aaveIsIncentivized;
    }

    function updateMaxSingleInvest(uint256 _maxSingleInvest) external onlyAuthorized {
        maxSingleInvest = _maxSingleInvest;
    }

    function updateSlippageProtectionIn(uint256 _slippageProtectionIn) external onlyAuthorized {
        slippageProtectionIn = _slippageProtectionIn;
    }

    function updateSlippageProtectionOut(uint256 _slippageProtectionOut) external onlyAuthorized {
        slippageProtectionOut = _slippageProtectionOut;
    }

    function updateMinCrv(uint256 _min) external onlyAuthorized {
        minCrv = _min;
    }

    function updateMinCvx(uint256 _min) external onlyAuthorized {
        minCvx = _min;
    }

    function updateMinAave(uint256 _min) external onlyAuthorized {
        minAave = _min;
    }

    function updateMinWant(uint256 _min) external onlyAuthorized {
        minWant = _min;
    }

    function updateMinReport(uint256 _min) external onlyAuthorized {
        minReport = _min;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return "Caave";
    }

    function balanceOfToken(address _token) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    function toWant(uint256 _lpBalance) public view returns (uint256) {
        if (_lpBalance == 0) {
            return 0;
        }

        return crvPool.calc_withdraw_one_coin(_lpBalance, usdtIndex);   
    }

    function toShares(uint256 _wantAmount) public view returns (uint256) {
        uint256[3] memory amounts;
        uint256 dollars = aThird(_wantAmount);
        amounts[usdtIndex] = dollars;
        amounts[wbtcIndex] = wantToBtc(dollars);
        amounts[wethIndex] = wantToEth(dollars);
        return crvPool.calc_token_amount(amounts, true);
    }

    function lpBalance() public view returns (uint256) {
        return rewardsContract.balanceOf(address(this)).add(balanceOfToken(crvToken));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 wantBalance = want.balanceOf(address(this));

        //need to get the net position of aave deposits - borrowed
        uint256 aaveBalance = getAaveBalance();

        uint256 poolBalance = toWant(lpBalance());

        return wantBalance.add(aaveBalance).add(poolBalance);
    }

    function getAaveBalance() public view returns (uint256) {
        (uint256 totalCollateralETH, uint256 totalDebtETH, , , , ) = lendingPool.getUserAccountData(address(this));

        return ethToWant(totalCollateralETH.sub(totalDebtETH));
    }

    function getAavePositions() public view returns (uint256 deposits, uint256 borrows) {
        (, uint256 totalDebtETH, , , , ) = lendingPool.getUserAccountData(address(this));
        deposits = balanceOfToken(aWant);
        borrows = ethToWant(totalDebtETH); 
    }

    //predicts our profit at next report
    function expectedReturn() public view returns (uint256) {
        uint256 estimateAssets = estimatedTotalAssets();

        uint256 debt = vault.strategies(address(this)).totalDebt;
        if (debt > estimateAssets) {
            return 0;
        } else {
            return estimateAssets.sub(debt);
        }
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        _profit = 0;
        _loss = 0; // for clarity. also reduces bytesize
        _debtPayment = 0;

        //claim rewards
        harvester();

        //get base want balance
        uint256 wantBalance = want.balanceOf(address(this));

        uint256 balance = wantBalance.add(toWant(lpBalance())).add(getAaveBalance());

        //get amount given to strat by vault
        uint256 debt = vault.strategies(address(this)).totalDebt;

        //Check to see if there is nothing invested
        if (balance == 0 && debt == 0) {
            return (_profit, _loss, _debtPayment);
        }

        //Balance - Total Debt is profit
        if (balance > debt) {
            _profit = balance.sub(debt);

            uint256 needed = _profit.add(_debtOutstanding);
            if (needed > wantBalance) {
                withdrawSome(needed.sub(wantBalance));

                wantBalance = want.balanceOf(address(this));

                if (wantBalance < needed) {
                    if (_profit >= wantBalance) {
                        _profit = wantBalance;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min(wantBalance.sub(_profit), _debtOutstanding);
                    }
                } else {
                    _debtPayment = _debtOutstanding;
                }
            } else {
                _debtPayment = _debtOutstanding;
            }
        } else {
            _loss = debt.sub(balance);
            if (_debtOutstanding > wantBalance) {
                withdrawSome(_debtOutstanding.sub(wantBalance));
                wantBalance = want.balanceOf(address(this));
            }

            _debtPayment = Math.min(wantBalance, _debtOutstanding);
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        //we are spending all our cash unless we have debt outstanding
        uint256 _wantBal = want.balanceOf(address(this));
        if (_wantBal < _debtOutstanding) {
            withdrawSome(_debtOutstanding.sub(_wantBal));

            return;
        }

        // send all of our want tokens to be deposited
        uint256 toInvest = _wantBal.sub(_debtOutstanding);

        uint256 _wantToInvest = Math.min(toInvest, maxSingleInvest);
        // deposit and stake
        depositSome(_wantToInvest);
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss) {
 
        uint256 wantBalance = want.balanceOf(address(this));
        if (wantBalance > _amountNeeded) {
            // if there is enough free want, let's use it
            return (_amountNeeded, 0);
        }

        // we need to free funds
        uint256 amountRequired = _amountNeeded.sub(wantBalance);
        withdrawSome(amountRequired);

        uint256 freeAssets = want.balanceOf(address(this));
        if (_amountNeeded > freeAssets) {
            _liquidatedAmount = freeAssets;
            uint256 diff = _amountNeeded.sub(_liquidatedAmount);
            if (diff > minWant) {
                _loss = diff;
            }
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function depositSome(uint256 _amount) internal {
        if (_amount < minWant) {
            return;
        }

        (uint256 deposits, uint256 borrows) = getAavePositions();

        //check current collat ratio
        uint256 collatRatio = getCollatRatio(deposits, borrows);

        //how much to leverage after deposit, may change through logic
        uint256 toLeverage = _amount;

        //If above upperbound we need to adjust collat
        if (collatRatio > adjustedUpperBound) {
            //check the collateral needed for current borrow
            uint256 collatNeeded = borrows.mul(DENOMINATOR).div(targetCollatRatio);
            uint256 diff = collatNeeded.sub(deposits);

            //check if _amount would bring the us back to under target
            if (diff > _amount) {
                //IF not withdraw enough to bring us back to target
                uint256 needed = collatNeeded.sub(deposits.add(_amount));
                deleverage(needed);
                _depositCollateral(_amount);
                return;
            } else {
                //we can deposit a portion of _amount to bring us back to target
                if (_amount.sub(diff) < minWant) {
                    //not worth leveraging just deposit all
                    _depositCollateral(_amount);
                    return;
                }

                //We will deposit all but only leverage the diff
                toLeverage = _amount.sub(diff);
            }
        } 

        //check if under lower collatRatio
        if(collatRatio < adjustedLowerBound) {
            
            //calc desired deposits based on borrows
            uint256 desiredDeposits = getDepositFromBorrow(borrows);

            //sub from total expected new deposits
            //leverage the diff
            toLeverage = deposits.add(_amount).sub(desiredDeposits);
        }

        //levereage as normal
        leverage(_amount, toLeverage);
    }

    function leverage(uint256 _amount, uint256 toLeverage) internal {
        _depositCollateral(_amount);

        uint256 borrowable = toLeverage.mul(targetCollatRatio).div(DENOMINATOR);

        uint256 kept = aThird(borrowable);

        uint256 usdtDeposit = _borrow(usdt, kept);
        uint256 wbtcDeposit = _borrow(wbtc, wantToBtc(kept));
        uint256 wethDeposit = _borrow(weth, wantToEth(kept));

        uint256[3] memory amounts;
        amounts[usdtIndex] = usdtDeposit;
        amounts[wbtcIndex] = wbtcDeposit;
        amounts[wethIndex] = wethDeposit;

        uint256 expectedOut = crvPool.calc_token_amount(amounts, true);
        
        uint256 maxSlip = expectedOut.mul(DENOMINATOR.sub(slippageProtectionIn)).div(DENOMINATOR);

        crvPool.add_liquidity(amounts, maxSlip);

        depositContract.deposit(pid, balanceOfToken(crvToken), true);
    }

    function withdrawSome(uint256 _amount) internal returns (uint256) {
        if (_amount < minWant) {
            return 0;
        }

        uint256 needed = _amount;
        //check the currect collat ratio
        (uint256 deposits, uint256 borrows) = getAavePositions();

        //If we have not borrowed anything we can just remove the amount
        if(borrows == 0) {
            return _withdrawCollateral(_amount);
        }

        //check current collat ratio
        uint256 collatRatio = getCollatRatio(deposits, borrows);

        //check if we can just remove excess collateral
        if (collatRatio < adjustedTargetCollat) {
            uint256 wantedDeposit = getDepositFromBorrow(borrows);
            if (deposits.sub(wantedDeposit) >= _amount) {
                return _withdrawCollateral(_amount);
            } else {
                needed = _amount.sub(deposits.sub(wantedDeposit));
            }
        }

        bool withdraw = deleverage(needed);

        if(withdraw) {
            return _withdrawCollateral(_amount);
        } else {
            return want.balanceOf(address(this));
        }
    }

    function deleverage(uint256 _needed) internal returns (bool){
          // dollars worth to pull from curve
        uint256 toWithdraw = _needed.mul(curveMultiplier).div(DENOMINATOR);
       
        //shares that need to be pulled out
        uint256 shares = toShares(toWithdraw);

        //check to see if we have enough
        if (shares > rewardsContract.balanceOf(address(this))) {
            liquidateAllPositions();
            //return false so that withdrawSome doesnt try to overWithdraw
            return false;
        }

        //withdraw from that staker. Dont claim rewards
        rewardsContract.withdrawAndUnwrap(shares, false);

        //1/3 of thecurve balance in dollars
        uint256 dollars = aThird(toWithdraw);

        //get min to be recieved
        uint256[3] memory amounts;
        amounts[usdtIndex] = dollars.mul(DENOMINATOR.sub(slippageProtectionOut)).div(DENOMINATOR);
        amounts[wbtcIndex] = wantToBtc(dollars).mul(DENOMINATOR.sub(slippageProtectionOut)).div(DENOMINATOR);
        amounts[wethIndex] = wantToEth(dollars).mul(DENOMINATOR.sub(slippageProtectionOut)).div(DENOMINATOR);

        crvPool.remove_liquidity(shares, amounts);

        _repay(usdt, Math.min(balanceOfToken(usdt), balanceOfToken(varUsdt)));
        _repay(wbtc, Math.min(balanceOfToken(wbtc), balanceOfToken(varWbtc)));
        _repay(weth, Math.min(balanceOfToken(weth), balanceOfToken(varWeth)));

        return true;
    }

    function aThird(uint256 _amount) internal view returns (uint256) {
        return _amount.mul(third).div(DENOMINATOR);
    }

    function _depositCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        lendingPool.deposit(address(want), amount, address(this), 0);
        return amount;
    }

    function _withdrawCollateral(uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        uint256 toWithdraw = Math.min(amount, balanceOfToken(aWant));
        return lendingPool.withdraw(address(want), toWithdraw, address(this));
    }

    function _repay(address _token, uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        return lendingPool.repay(_token, amount, 2, address(this));
    }

    function _borrow(address _token, uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        lendingPool.borrow(_token, amount, 2, 0, address(this));
        return amount;
    }

    function getCollatRatio(uint256 deposits, uint256 borrows) public view returns (uint256) {
        if (borrows == 0) {
            return adjustedTargetCollat;
        }

        return borrows.mul(10 **(want_decimals)).div(deposits);
    }

    function getBorrowFromDeposit(uint256 deposit) internal view returns (uint256) {
        return deposit.mul(targetCollatRatio).div(DENOMINATOR);
    }

    function getDepositFromBorrow(uint256 borrow) internal view returns (uint256) {
        return borrow.mul(DENOMINATOR).div(targetCollatRatio);
    }

    function harvester() internal {
        if (block.timestamp < lastHarvest.add(minReport)) {
            return;
        }

        rewardsContract.getReward(address(this), harvestExtras);
        disposeCvx();
        disposeCrv();

        if(aaveIsIncentivized) {
            claimAaveRewards();
        }

        lastHarvest = block.timestamp;
    }

    function claimAaveRewards() internal {
        if(!_checkCooldown()){
            return;
        }
        // redeem AAVE from stkAave
        uint256 stkAaveBalance = IERC20(address(stkAave)).balanceOf(address(this));
        if(stkAaveBalance > 0) {
            stkAave.redeem(address(this), stkAaveBalance);
        }

        // claim rewards
        uint256 pendingRewards = aaveIncentivesController.getRewardsBalance(getAaveAssets(), address(this));
        if(pendingRewards > 0) {
            aaveIncentivesController.claimRewards(getAaveAssets(), pendingRewards, address(this));
        }

        // request start of cooldown period
        if(IERC20(address(stkAave)).balanceOf(address(this)) > 0) {
            stkAave.cooldown();
        }

        // sell AAVE for want
        disposeAave();
    }

    function _checkCooldown() internal view returns (bool) {
        if(aaveIsIncentivized) {
            return false;
        }

        uint256 cooldownStartTimestamp = stkAave.stakersCooldowns(address(this));
        uint256 COOLDOWN_SECONDS = stkAave.COOLDOWN_SECONDS();
        uint256 UNSTAKE_WINDOW = stkAave.UNSTAKE_WINDOW();
        if(block.timestamp >= cooldownStartTimestamp.add(COOLDOWN_SECONDS)) {
            return block.timestamp.sub(cooldownStartTimestamp.add(COOLDOWN_SECONDS)) <= UNSTAKE_WINDOW || cooldownStartTimestamp == 0;
        } else {
            return false;
        }
    }

    function disposeCrv() internal {
        uint256 _crv = balanceOfToken(crv);
        if (_crv < minCrv) {
            return;
        }

        _swapFrom(crv, address(want), _crv);
    }

    function disposeCvx() internal {
        uint256 _cvx = balanceOfToken(cvx);
        if (_cvx < minCvx) {
            return;
        }

        _swapFrom(cvx, address(want), _cvx);
    }

    function disposeAave() internal {
        uint256 _aave = balanceOfToken(aave);
        if (_aave < minAave) {
            return;
        }

        _swapFrom(aave, address(want), _aave);
    }

    //Based on want having 6 decimals
    function wantToBtc(uint256 _want) internal view returns(uint256) {
        return _want.mul(1e10).div(getWbtcPrice());
    }

    //based on want having 6 decimals, oracle returns eth in 8 decimals
    function wantToEth(uint256 _want) internal view returns(uint256) {
        return _want.mul(1e20).div(getWethPrice());
    }

    //price of btc based on oracle call
    function getWbtcPrice() internal view returns(uint256) {
        (
            /*uint80 roundID*/,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = btcPriceFeed.latestRoundData();
        return uint256(price);
    }

    //return price of eth based on oracle call
    function getWethPrice() internal view returns(uint256) {
        (
            /*uint80 roundID*/,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = ethPriceFeed.latestRoundData();
        //does not adjust for decimals that are returned with 8
        return uint256(price);
    }

    //WARNING. manipulatable and simple routing. Only use for safe functions
    function _checkPrice(
        address start,
        address end,
        uint256 _amount
    ) internal view returns (uint256) {
        if (_amount == 0) {
            return 0;
        }

        uint256[] memory amounts = router.getAmountsOut(_amount, getTokenOutPath(start, end));

        return amounts[amounts.length - 1];
    }

    function _checkCrvPrice(
        address _from,
        address _to,
        uint256 _amount
    ) public view returns (uint256) {
        if (_amount == 0) {
            return 0;
        }
        return crvPool.get_dy_underlying(index[_from], index[_to], _amount);
    }

    function minCrvSwap(uint256 _amount) internal returns(uint256) {
        return _amount.mul(DENOMINATOR.sub(crvSlippage)).div(DENOMINATOR);
    }

    function _crvSwapWithAmount(
        uint256 _from,
        uint256 _to,
        uint256 _fromAmount,
        uint256 _toMin
    ) internal{
        crvPool.exchange_underlying(_from, _to, _fromAmount, _toMin);
    }

    function _crvSwapFrom(
        uint256 _from,
        uint256 _to,
        uint256 _amount
    ) public{
         if (_amount == 0) {
            return;
        }

        uint256 to = crvPool.get_dy_underlying(_from, _to, _amount);
        _crvSwapWithAmount(_from, to, _amount, to.mul(DENOMINATOR.sub(slippageProtectionIn)).div(DENOMINATOR));
    }
  
    function _swapFromWithAmount(
        address _from,
        address _to,
        uint256 _amountIn,
        uint256 _amountOut
    ) internal returns (uint256) {

        uint256[] memory amounts = router.swapExactTokensForTokens(
            _amountIn,
            _amountOut,
            getTokenOutPath(_from, _to),
            address(this),
            block.timestamp
        );

        return amounts[amounts.length - 1];
    }

    function _swapFrom(
        address _from,
        address _to,
        uint256 _amountIn
    ) internal returns (uint256) {
        uint256 amountOut = _checkPrice(_from, _to, _amountIn);

        return _swapFromWithAmount(_from, _to, _amountIn, amountOut);
    }

    function _swapTo(address _from, address _to, uint256 _amountTo) internal returns(uint256) {

        address[] memory path = getTokenOutPath(_from, _to);

        uint256[] memory amountIn = router.getAmountsIn(_amountTo, path);
        
        uint256[] memory amounts = router.swapTokensForExactTokens(
            _amountTo, amountIn[0], path, address(this), block.timestamp);

        return amounts[amounts.length - 1];
    }

    function getTokenOutPath(address _tokenIn, address _tokenOut) internal view returns (address[] memory _path) {
        bool isWeth = _tokenIn == weth || _tokenOut == weth;
        _path = new address[](isWeth ? 2 : 3);
        _path[0] = _tokenIn;

        if (isWeth) {
            _path[1] = _tokenOut;
        } else {
            _path[1] = weth;
            _path[2] = _tokenOut;
        }
    }

    function getAaveAssets() internal view returns (address[] memory assets) {
        assets = new address[](4);
        assets[0] = aWant;
        assets[1] = varWbtc;
        assets[2] = varWeth;
        assets[3] = varUsdt;
    }

    function repayAll() internal {
        uint256 shares = balanceOfToken(crvToken);
        if(shares == 0) {
            return;
        }

        uint256 usdtOwed = balanceOfToken(varUsdt);
        uint256 wbtcOwed = balanceOfToken(varWbtc);
        uint256 wethOwed = balanceOfToken(varWeth);
        
        uint256[3] memory amounts;
        
        //Allow to the pool to pull less than usdtOwed to assure the tx wont fail.
        // We will swap back to the needed usdt after
        amounts[usdtIndex] = usdtOwed.div(2); 
        amounts[wbtcIndex] = wbtcOwed;
        amounts[wethIndex] = wethOwed;

        crvPool.remove_liquidity(shares, amounts);

        _repay(wbtc, wbtcOwed);
        _repay(weth, wethOwed);

        uint256 usdtBal = balanceOfToken(usdt);
        if(usdtBal < usdtOwed) {
            uint256 diff = usdtOwed.sub(usdtBal);

            //check if we have enough available want from previous rewards claimed
            if(balanceOfToken(address(want)) < diff.add(1)) {
                _withdrawCollateral(diff.mul(2));
            }

            _swapTo(address(want), usdt, diff);

        }
        _repay(usdt, usdtOwed);
        
    }

    function liquidateAllPositions() internal override returns (uint256) {
        rewardsContract.withdrawAndUnwrap(rewardsContract.balanceOf(address(this)), true);

        if(aaveIsIncentivized){
            claimAaveRewards();
        }
        disposeCrv();
        disposeCvx();
        
        repayAll();

        _withdrawCollateral(balanceOfToken(aWant));

        //run check to swap back anyt extra that we received in wbtc/weth
        uint256 _wbtcB = balanceOfToken(wbtc);
        if (_wbtcB > 0) {
            _swapFrom(wbtc, address(want), _wbtcB);
        }
        uint256 _wethB = balanceOfToken(weth);
        if (_wethB > 0) {
            _swapFrom(weth, address(want), _wethB);
        } 
        uint256 _usdtB = balanceOfToken(usdt);
        if(_usdtB > 0) {
            _swapFrom(usdt, address(want), _usdtB);
        }

        return want.balanceOf(address(this));
    }


    function rebalance() external onlyKeepers {
        (uint256 deposits, uint256 borrows) = getAavePositions();

        //check current collat ratio
        uint256 collatRatio = getCollatRatio(deposits, borrows);

        if(collatRatio < adjustedUpperBound && collatRatio > adjustedLowerBound) {
            return;
        }
       
        else if(collatRatio < adjustedLowerBound){
            rebalanceUp(deposits, borrows);
        }

        else if(collatRatio > adjustedUpperBound){
            rebalanceDown(deposits, borrows);
        }

    }

    function rebalanceDown(uint256 deposits, uint256 borrows) internal {
        uint256 desiredBorrows = getBorrowFromDeposit(deposits);

        uint256 diff = borrows.sub(desiredBorrows);

        deleverage(diff.mul(DENOMINATOR).div(curveMultiplier));

    }

    function rebalanceUp(uint256 deposits, uint256 borrows) internal {
        uint256 desiredBorrows = getBorrowFromDeposit(deposits);

        //calc desired deposits based on borrows
        uint256 desiredDeposits = getDepositFromBorrow(borrows);

        //sub from total deposits
        //leverage the diff
        uint256 toLeverage = deposits.sub(desiredDeposits);
        
        //levereage as normal
        leverage(0, toLeverage);
    
    }

    function prepareMigration(address _newStrategy) internal override {
        rewardsContract.withdrawAndUnwrap(rewardsContract.balanceOf(address(this)), true);
        if(aaveIsIncentivized) {
            claimAaveRewards();
        }
        
        repayAll();
        
        //Transfer any tokens we have to the new strat
        uint256 _crvB = balanceOfToken(crv);
        if (_crvB > 0) {
            IERC20(crv).safeTransfer(_newStrategy, _crvB);
        }
        uint256 _cvxB = balanceOfToken(cvx);
        if (_cvxB > 0) {
            IERC20(cvx).safeTransfer(_newStrategy, _cvxB);
        }
        uint256 _aaveB = balanceOfToken(aave);
        if (_aaveB > 0) {
            IERC20(aave).safeTransfer(_newStrategy, _aaveB);
        }
        uint256 _stkaaveB = balanceOfToken(address(stkAave));
        if (_stkaaveB > 0) {
            IERC20(address(stkAave)).safeTransfer(_newStrategy, _stkaaveB);
        }
        //run check to swap back anyt extra  wbtc/weth
        uint256 _wbtcB = balanceOfToken(wbtc);
        if (_wbtcB > 0) {
            _swapFrom(wbtc, address(want), _wbtcB);
        }
        uint256 _wethB = balanceOfToken(weth);
        if (_wethB > 0) {
            _swapFrom(weth, address(want), _wethB);
        }
        uint256 _usdtB = balanceOfToken(usdt);
        if(_usdtB > 0) {
            _swapFrom(usdt, address(want), _usdtB);
        }

        IERC20(aWant).transfer(_newStrategy, balanceOfToken(aWant));
    }

    //This seems escessive....
    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](12);
        protected[0] = crvToken;
        protected[1] = crv;
        protected[2] = aave;
        protected[3] = wbtc;
        protected[4] = weth;
        protected[5] = aWant;
        protected[6] = varWbtc;
        protected[7] = varWeth;
        protected[8] = usdt;
        protected[9] = varUsdt;
        protected[10] = cvx;
        protected[11] = address(stkAave);

        return protected;
    }

    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256) {
        //adjust for decimals from oracle
        //need to div by 1e(18 + (18 - want_Decimals)) // Assumes want has 6 decimals
        //can also not correct oracle decimals and div(1e20) 
        return (getWethPrice().mul(1e10)).mul(_amtInWei).div(1e30);
    }

    //manual withdraw incase needed
    function manualUnstake(uint256 _amount) external onlyEmergencyAuthorized {
        rewardsContract.withdrawAndUnwrap(rewardsContract.balanceOf(address(this)), true);
    }

    //manual withdraw incase needed
    ///@param _amount in crvTokens
    function manualWithdraw(uint256 _amount) external onlyEmergencyAuthorized {
        crvPool.remove_liquidity_one_coin(_amount, usdtIndex, 1);
    } 
 
    function manualRepay(uint256 _amount, address _toRepay) external onlyEmergencyAuthorized {
        _repay(_toRepay, _amount);
    }

    function manualSwap(address _from, address _to, uint256 _amount) external onlyEmergencyAuthorized {
        _swapFrom(_from, _to, _amount);
    }

    function manualAaveWithdraw(uint256 _amount) external onlyEmergencyAuthorized {
        _withdrawCollateral(_amount);
    }

}
