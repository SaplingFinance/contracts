// SPDX-License-Identifier: MIT

pragma solidity ^0.8.15;

import "./context/SaplingPoolContext.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/ILoanDesk.sol";

/**
 * @title Sapling Lending Pool
 * @dev Extends SaplingPoolContext with lending strategy.
 */
contract SaplingLendingPool is ILendingPool, SaplingPoolContext {

    /// Address of the loan desk contract
    address public loanDesk;

    /// Mark loan funds released flags to guards against double withdrawals due to future bugs or compromised LoanDesk
    mapping(address => mapping(uint256 => bool)) private loanFundsReleased;

    /// Mark the loans closed to guards against double actions due to future bugs or compromised LoanDesk
    mapping(address => mapping(uint256 => bool)) private loanClosed;

    /// A modifier to limit access only to the loan desk contract
    modifier onlyLoanDesk() {
        require(msg.sender == loanDesk, "SaplingLendingPool: caller is not the LoanDesk");
        _;
    }

    /**
     * @dev Disable initializers
     */
    function disableIntitializers() external onlyRole(SaplingRoles.GOVERNANCE_ROLE) {
        _disableInitializers();
    }

    /**
     * @notice Creates a Sapling pool.
     * @dev Addresses must not be 0.
     * @param _poolToken ERC20 token contract address to be used as the pool issued token.
     * @param _liquidityToken ERC20 token contract address to be used as pool liquidity currency.
     * @param _accessControl Access control contract
     * @param _managerRole Manager role
     */
    function initialize(
        address _poolToken,
        address _liquidityToken,
        address _accessControl,
        bytes32 _managerRole
    )
        public
        initializer
    {
        __SaplingPoolContext_init(_poolToken, _liquidityToken, _accessControl, _managerRole);
    }

    /**
     * @notice Links a new loan desk for the pool to use. Intended for use upon initial pool deployment.
     * @dev Caller must be the governance.
     * @param _loanDesk New LoanDesk address
     */
    function setLoanDesk(address _loanDesk) external onlyRole(SaplingRoles.GOVERNANCE_ROLE) {
        address prevLoanDesk = loanDesk;
        loanDesk = _loanDesk;
        emit LoanDeskSet(prevLoanDesk, loanDesk);
    }

    /**
     * @dev Hook for a new loan offer. Caller must be the LoanDesk.
     * @param amount Loan offer amount.
     */
    function onOffer(uint256 amount) external onlyLoanDesk whenNotPaused whenNotClosed {
        require(strategyLiquidity() >= amount, "SaplingLendingPool: insufficient liquidity");

        balance.rawLiquidity -= amount;
        balance.allocatedFunds += amount;

        emit OfferLiquidityAllocated(amount);
    }

    /**
     * @dev Hook for a loan offer amount update. Amount update can be due to offer update or
     *      cancellation. Caller must be the LoanDesk.
     * @param prevAmount The original, now previous, offer amount.
     * @param amount New offer amount. Cancelled offer must register an amount of 0 (zero).
     */
    function onOfferUpdate(uint256 prevAmount, uint256 amount) external onlyLoanDesk whenNotPaused whenNotClosed {
        require(strategyLiquidity() + prevAmount >= amount, "SaplingLendingPool: insufficient liquidity");

        balance.rawLiquidity = balance.rawLiquidity + prevAmount - amount;
        balance.allocatedFunds = balance.allocatedFunds - prevAmount + amount;

        emit OfferLiquidityUpdated(prevAmount, amount);
    }

    /**
     * @dev Hook for borrow. Releases the loan funds to the borrower. Caller must be the LoanDesk. 
     * Loan metadata is passed along as call arguments to avoid reentry callbacks to the LoanDesk.
     * @param loanId ID of the loan which has just been borrowed
     * @param borrower Address of the borrower
     * @param amount Loan principal amount
     * @param apr Loan apr
     */
    function onBorrow(
        uint256 loanId, 
        address borrower, 
        uint256 amount, 
        uint16 apr
    ) 
        external 
        onlyLoanDesk
        nonReentrant
        whenNotPaused
        whenNotClosed
    {
        // check
        require(loanFundsReleased[loanDesk][loanId] == false, "SaplingLendingPool: loan funds already released");

        // @dev trust the loan validity via LoanDesk checks as the only authorized caller is LoanDesk

        //// effect

        loanFundsReleased[loanDesk][loanId] = true;
        
        uint256 prevStrategizedFunds = balance.strategizedFunds;
        
        balance.tokenBalance -= amount;
        balance.allocatedFunds -= amount;
        balance.strategizedFunds += amount;

        weightedAvgStrategyAPR = (prevStrategizedFunds * weightedAvgStrategyAPR + amount * apr)
            / balance.strategizedFunds;

        //// interactions

        SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(tokenConfig.liquidityToken), borrower, amount);

        emit LoanFundsReleased(loanId, borrower, amount);
    }

     /**
     * @dev Hook for repayments. Caller must be the LoanDesk. 
     * Loan metadata is passed along as call arguments to avoid reentry callbacks to the LoanDesk. 
     * Transfer amount can be less than the payment amount due to payment carry feature.
     * @param loanId ID of the loan which has just been borrowed
     * @param borrower Borrower address
     * @param payer Actual payer address
     * @param apr Loan apr
     * @param transferAmount Amount chargeable
     * @param paymentAmount Payment amount for updating state
     * @param interestPayable Interest amount for updating state
     */
    function onRepay(
        uint256 loanId, 
        address borrower,
        address payer,
        uint16 apr,
        uint256 transferAmount, 
        uint256 paymentAmount, 
        uint256 interestPayable
    ) 
        external 
        onlyLoanDesk
        nonReentrant
        whenNotPaused
        whenNotClosed
    {
        //// check
        require(loanFundsReleased[loanDesk][loanId] == true, "SaplingLendingPool: loan is not borrowed");
        require(loanClosed[loanDesk][loanId] == false, "SaplingLendingPool: loan is closed");

        // @dev trust the loan validity via LoanDesk checks as the only caller authorized is LoanDesk

        //// effect

        balance.tokenBalance += transferAmount;

        uint256 principalPaid;
        if (interestPayable == 0) {
            principalPaid = paymentAmount;
            balance.rawLiquidity += paymentAmount;
        } else {
            principalPaid = paymentAmount - interestPayable;

            //share revenue to treasury
            uint256 protocolEarnedInterest = MathUpgradeable.mulDiv(
                interestPayable,
                config.protocolFeePercent,
                SaplingMath.HUNDRED_PERCENT
            );

            balance.protocolRevenue += protocolEarnedInterest;

            //share revenue to manager
            uint256 currentStakePercent = MathUpgradeable.mulDiv(
                balance.stakedShares,
                SaplingMath.HUNDRED_PERCENT,
                totalPoolTokenSupply()
            );

            uint256 managerEarningsPercent = MathUpgradeable.mulDiv(
                currentStakePercent,
                config.managerEarnFactor - SaplingMath.HUNDRED_PERCENT,
                SaplingMath.HUNDRED_PERCENT
            );

            uint256 managerEarnedInterest = MathUpgradeable.mulDiv(
                interestPayable - protocolEarnedInterest,
                managerEarningsPercent,
                managerEarningsPercent + SaplingMath.HUNDRED_PERCENT
            );

            balance.managerRevenue += managerEarnedInterest;

            balance.rawLiquidity += paymentAmount - (protocolEarnedInterest + managerEarnedInterest);
            balance.poolFunds += interestPayable - (protocolEarnedInterest + managerEarnedInterest);

            updatePoolLimit();
        }

        balance.strategizedFunds -= principalPaid;

        updateAvgStrategyApr(principalPaid, apr);

        //// interactions

        // charge 'amount' tokens from msg.sender
        SafeERC20Upgradeable.safeTransferFrom(
            IERC20Upgradeable(tokenConfig.liquidityToken),
            payer,
            address(this),
            transferAmount
        );

        emit LoanRepaymentFinalized(loanId, borrower, payer, transferAmount, interestPayable);
    }

    /**
     * @dev Hook for closing a loan. Caller must be the LoanDesk. Closing a loan will repay the outstanding principal 
     * using the pool manager's revenue and/or staked funds. If these funds are not sufficient, the lenders will 
     * share the loss.
     * @param loanId ID of the loan to close
     * @param apr Loan apr
     * @param amountRepaid Amount repaid based on outstanding payment carry
     * @param remainingDifference Principal amount remaining to be resolved to close the loan
     * @return Amount reimbursed by the pool manager funds
     */
    function onCloseLoan(
        uint256 loanId,
        uint16 apr,
        uint256 amountRepaid,
        uint256 remainingDifference
    )
        external
        onlyLoanDesk
        nonReentrant
        whenNotPaused
        whenNotClosed
        returns (uint256)
    {
        //// check
        require(loanClosed[loanDesk][loanId] == false, "SaplingLendingPool: loan is closed");

        // @dev trust the loan validity via LoanDesk checks as the only caller authorized is LoanDesk

        //// effect

        loanClosed[loanDesk][loanId] == true;

        // charge manager's revenue
        if (remainingDifference > 0 && balance.managerRevenue > 0) {
            uint256 amountChargeable = MathUpgradeable.min(remainingDifference, balance.managerRevenue);

            balance.managerRevenue -= amountChargeable;

            remainingDifference -= amountChargeable;
            amountRepaid += amountChargeable;
        }

        // charge manager's stake
        uint256 stakeChargeable = 0;
        if (remainingDifference > 0 && balance.stakedShares > 0) {
            uint256 stakedBalance = tokensToFunds(balance.stakedShares);
            uint256 amountChargeable = MathUpgradeable.min(remainingDifference, stakedBalance);
            stakeChargeable = fundsToTokens(amountChargeable);

            balance.stakedShares = balance.stakedShares - stakeChargeable;
            updatePoolLimit();

            if (balance.stakedShares == 0) {
                emit StakedAssetsDepleted();
            }

            remainingDifference -= amountChargeable;
            amountRepaid += amountChargeable;
        }

        if (amountRepaid > 0) {
            balance.strategizedFunds -= amountRepaid;
            balance.rawLiquidity += amountRepaid;
        }

        // charge pool (close loan and reduce borrowed funds/poolfunds)
        if (remainingDifference > 0) {
            balance.strategizedFunds -= remainingDifference;
            balance.poolFunds -= remainingDifference;

            emit UnstakedLoss(remainingDifference);
        }

        updateAvgStrategyApr(amountRepaid + remainingDifference, apr);

        //// interactions
        if (stakeChargeable > 0) {
            IPoolToken(tokenConfig.poolToken).burn(address(this), stakeChargeable);
        }

        return amountRepaid;
    }

    /**
     * @notice Closes a loan. 
     * @dev Hook for closing a loan. Caller must be the LoanDesk. Closing a loan will repay the outstanding principal 
     * using the pool manager's revenue and/or staked funds. If these funds are not sufficient, the lenders will 
     * take the loss.
     * @param loanId ID of the loan to close
     * @param apr Loan apr
     * @param amountRepaid Amount repaid based on outstanding payment carry
     * @param remainingDifference Principal amount remaining to be resolved to close the loan
     * @return Amount reimbursed by the pool manager funds
     */

    /**
     * @dev Hook for defaulting a loan. Caller must be the LoanDesk. Defaulting a loan will cover the loss using 
     * the staked funds. If these funds are not sufficient, the lenders will share the loss.
     * @param loanId ID of the loan to default
     * @param apr Loan apr
     * @param carryAmountUsed Amount of payment carry repaid 
     * @param loss Loss amount to resolve
     */
    function onDefault(
        uint256 loanId,
        uint16 apr,
        uint256 carryAmountUsed,
        uint256 loss
    )
        external
        onlyLoanDesk
        nonReentrant
        whenNotPaused
        whenNotClosed
        returns (uint256, uint256)
    {
        //// check
        require(loanClosed[loanDesk][loanId] == false, "SaplingLendingPool: loan is closed");

        // @dev trust the loan validity via LoanDesk checks as the only caller authorized is LoanDesk

        //// effect
        loanClosed[loanDesk][loanId] == true;

        if (carryAmountUsed > 0) {
            balance.strategizedFunds -= carryAmountUsed;
            balance.rawLiquidity += carryAmountUsed;
        }

        uint256 managerLoss = loss;
        uint256 lenderLoss = 0;

        if (loss > 0) {
            uint256 remainingLostShares = fundsToTokens(loss);

            balance.poolFunds -= loss;
            balance.strategizedFunds -= loss;
            updateAvgStrategyApr(loss, apr);

            if (balance.stakedShares > 0) {
                uint256 stakedShareLoss = MathUpgradeable.min(remainingLostShares, balance.stakedShares);
                remainingLostShares -= stakedShareLoss;
                balance.stakedShares -= stakedShareLoss;
                updatePoolLimit();

                if (balance.stakedShares == 0) {
                    emit StakedAssetsDepleted();
                }

                //// interactions

                //burn manager's shares; this external interaction must happen before calculating lender loss
                IPoolToken(tokenConfig.poolToken).burn(address(this), stakedShareLoss);
            }

            if (remainingLostShares > 0) {
                lenderLoss = tokensToFunds(remainingLostShares);
                managerLoss -= lenderLoss;

                emit UnstakedLoss(lenderLoss);
            }
        }

        return (managerLoss, lenderLoss);
    }

    /**
     * @notice View indicating whether or not a given loan can be offered by the manager.
     * @dev Hook for checking if the lending pool can provide liquidity for the total offered loans amount.
     * @param totalOfferedAmount Total sum of offered loan amount including outstanding offers
     * @return True if the pool has sufficient lending liquidity, false otherwise
     */
    function canOffer(uint256 totalOfferedAmount) external view returns (bool) {
        return !paused() 
            && !closed() 
            && maintainsStakeRatio()
            && totalOfferedAmount <= strategyLiquidity() + balance.allocatedFunds;
    }
}
