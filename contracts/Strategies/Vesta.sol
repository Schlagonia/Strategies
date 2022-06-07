// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategyInitializable,
    StrategyParams
} from "../BaseStrategy.sol";

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import {IERC20Extended} from '../interfaces/IERC20Extended.sol';

import {IStabilityPool} from '../interfaces/Vesta/IStabilityPool.sol';
import {IUniswapV2Router02} from '../interfaces/Uni/IUniswapV2Router02.sol';

contract Vesta is BaseStrategyInitializable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IStabilityPool public stabilityPool;

    //Payed out as a continous reward token
    address constant vsta = address(0xa684cd057951541187f288294a1e1C2646aA2d24);
    //Token for the specific stability pool that will be liquidated and payed out in replace of VST
    address public seizeToken;

    IUniswapV2Router02 router;

    uint256 want_decimals;
    uint256 minWant;
    uint256 maxSingleInvest;

    address constant weth = address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);

    constructor(
        address _vault,
        address _seizeToken,
        address _stabilityPool
    ) public BaseStrategy(_vault) {
        _initializThis(_seizeToken, _stabilityPool);
    }

    function initializeThis(address _seizeToken, address _stabilityPool) external {
        _initializeThis(_seizeToken, _stabilityPool);
    }

    function _initializeThis(
        address _seizeToken,
        address _stabilityPool
    ) internal {
        require(seizeToken == address(0), "Strat already initiliazed");
        
        setStabilityPool(_stabilityPool);
        seizeToken = _seizeToken;

        want_decimals = IERC20Extended(address(want)).decimals();

        minWant = 10 ** (want_decimals.sub(3));
        maxSingleInvest = 10 ** (want_decimals.add(6));
    }

    function setStabilityPool(address _stabilityPool) internal {
        maxApprove(address(want), _stabilityPool);
        stabilityPool = IStabilityPool(_stabilityPool);
    }

    function maxApprove(address token, address spender) internal{
        IERC20(token).safeApprove(spender, type(uint256).max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return "Vesta";
    }

    function balanceOfToken(address _token) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    function vstStaked() public view returns(uint256) {
        return stabilityPool.getCompoundedVSTDeposit(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 stakedBalance = vstStaked();
        
        //Wont account for pendng rewards but Rewards ore payed out before every withdraw so we may have some sitting in the account inbetween harvests
        uint256 estimatedSeized = _checkPrice(seizeToken, address(Want), balanceOfToken(seizeToken));
        uint256 estimatedVsta = _checkPrice(vsta, address(want), balanceOfToken(vsta));

        return want.balanceOf(address(this)).add(stakedBalance).add(estimatedSeized).add(estimatedVsta);
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
        //Will cause redundant logic if funds are deposited or withdrawn after but need to harvest rewards before determining profit
        stabilityPool.withdrawAssetGainToTrove(address(this), address(this));
        sellRewards();

        //get base want balance
        uint256 wantBalance = want.balanceOf(address(this));

        uint256 balance = wantBalance.add(vstStaked());

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

        stabilityPool.provideToSP(_amount);
    }

    function withdrawSome(uint256 _amount) internal {
        if(_amount == 0) {
            return;
        }

        stabilityPool.withdrawFromSP(_amount);
    }

    function sellRewards() internal {
        uint256 _vstaB = balanceOfToken(vsta);
        if(_vstaB > 0) {
            _swapFrom(vsta, address(want), _vstaB);
        }

        uint256 _seizedB = balanceOfToken(seizeToken);
        if(_seizeB > 0) {
            _swapFrom(seizeToken, address(want), _seizeB);
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        withdrawSome(type(uint256).max);
        sellRewards();
        return want.balanceOf(address(this));
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


    function prepareMigration(address _newStrategy) internal override {
        liquidateAllPositions();
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory protected)
    {
        prtoected = new address[](2);
        protected[0] = seizeToken;
        protected[1] = vsta;
    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _checkPrice(weth, address(want), _amtInWei);
    }
}