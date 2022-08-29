// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.15;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/IPoolToken.sol";
import "../interfaces/ILender.sol";
import "./SaplingManagerContext.sol";
import "./SaplingMathContext.sol";

/**
 * @title Sapling Pool Context
 * @notice Provides common pool functionality with lender deposits, manager's first loss capital staking, and reward distribution. 
 */
abstract contract SaplingPoolContext is ILender, SaplingManagerContext, SaplingMathContext, ReentrancyGuard {

    using SafeMath for uint256;

    /// Address of an ERC20 token managed and issued by the pool
    address public immutable poolToken;

    /// Address of an ERC20 liquidity token accepted by the pool
    address public immutable liquidityToken;

    /// tokenDecimals value retrieved from the liquidity token contract upon contract construction
    uint8 public immutable tokenDecimals;

    /// A value representing 1.0 token amount, padded with zeros for decimals
    uint256 public immutable ONE_TOKEN;

    /// Total liquidity tokens currently held by this contract
    uint256 public tokenBalance;

    /// MAX amount of liquidity tokens allowed in the pool based on staked assets
    uint256 public poolFundsLimit;

    /// Current amount of liquidity tokens in the pool, including both liquid and allocated funds
    uint256 public poolFunds;

    /// Current amount of liquid tokens, available to for pool strategies or withdrawals
    uint256 public poolLiquidity;

    /// Current funds allocated for pool strategies
    uint256 public allocatedFunds;

    /// Current funds committed to strategies such as borrowing or investing
    uint256 public strategizedFunds;

    /// Current pool shares present, this also represents current total pool tokens in circulation
    uint256 public totalPoolShares;

    /// Manager's staked shares
    uint256 public stakedShares;

    /// Target percentage ratio of staked shares to total shares
    uint16 public targetStakePercent;

    /// Target percentage of pool funds to keep liquid. 
    uint16 public targetLiquidityPercent;

    /// exit fee percentage
    uint256 public immutable exitFeePercent;

    /// Manager's leveraged earn factor represented as a percentage
    uint16 public managerEarnFactor;
    
    /// Governance set upper bound for the manager's leveraged earn factor
    uint16 public managerEarnFactorMax;

    /// Part of the managers leverage factor, earnings of witch will be allocated for the manager as protocol earnings.
    /// This value is always equal to (managerEarnFactor - ONE_HUNDRED_PERCENT)
    uint256 internal managerExcessLeverageComponent;

    /// Percentage of paid interest to be allocated as protocol earnings
    uint16 public protocolEarningPercent;

    /// An upper bound for percentage of paid interest to be allocated as protocol earnings
    uint16 public immutable MAX_PROTOCOL_EARNING_PERCENT;

    /// Protocol earnings of wallets
    mapping(address => uint256) internal protocolEarnings; 

    /// Weighted average loan APR on the borrowed funds
    uint256 internal weightedAvgStrategyAPR;

    /// Strategy id generator counter
    uint256 private nextStrategyId;

    /// Event for when the lender capital is lost due to defaults
    event UnstakedLoss(uint256 amount);

    /// Event for when the Manager's staked assets are depleted due to defaults
    event StakedAssetsDepleted();

    /**
     * @notice Creates a SaplingPoolContext.
     * @dev Addresses must not be 0.
     * @param _poolToken ERC20 token contract address to be used as the pool issued token.
     * @param _liquidityToken ERC20 token contract address to be used as pool liquidity currency.
     * @param _governance Governance address
     * @param _protocol Protocol wallet address
     * @param _manager Manager address
     */
    constructor(address _poolToken, address _liquidityToken, address _governance, address _protocol, address _manager) 
        SaplingManagerContext(_governance, _protocol, _manager) {

        require(_poolToken != address(0), "SaplingPoolContext: pool token address is not set");
        require(_liquidityToken != address(0), "SaplingPoolContext: liquidity token address is not set");
        assert(IERC20(_poolToken).totalSupply() == 0);
        
        poolToken = _poolToken;
        liquidityToken = _liquidityToken;
        tokenBalance = 0;
        totalPoolShares = 0;
        stakedShares = 0;

        poolFundsLimit = 0;
        poolFunds = 0;

        targetStakePercent = uint16(10 * 10 ** PERCENT_DECIMALS); //10%
        targetLiquidityPercent = 0; //0%

        exitFeePercent = ONE_HUNDRED_PERCENT / 200; // 0.5%

        protocolEarningPercent = uint16(10 * 10 ** PERCENT_DECIMALS); // 10% by default; safe min 0%, max 10%
        MAX_PROTOCOL_EARNING_PERCENT = protocolEarningPercent;

        managerEarnFactorMax = uint16(500 * 10 ** PERCENT_DECIMALS); // 150% or 1.5x leverage by default (safe min 100% or 1x)
        managerEarnFactor = uint16(150 * 10 ** PERCENT_DECIMALS);
        managerExcessLeverageComponent = uint256(managerEarnFactor).sub(ONE_HUNDRED_PERCENT);

        uint8 decimals = IERC20Metadata(liquidityToken).decimals();
        tokenDecimals = decimals;
        ONE_TOKEN = 10 ** decimals;

        poolLiquidity = 0;
        allocatedFunds = 0;
        strategizedFunds = 0;

        weightedAvgStrategyAPR = 0;
        nextStrategyId = 1;
    }

    /**
     * @notice Set the target stake percent for the pool.
     * @dev _targetStakePercent must be inclusively between 0 and ONE_HUNDRED_PERCENT.
     *      Caller must be the governance.
     * @param _targetStakePercent New target stake percent.
     */
    function setTargetStakePercent(uint16 _targetStakePercent) external onlyGovernance {
        require(0 <= _targetStakePercent && _targetStakePercent <= ONE_HUNDRED_PERCENT, 
            "SaplingPoolContext: target stake percent is out of bounds");
        targetStakePercent = _targetStakePercent;
    }

    /**
     * @notice Set the target liquidity percent for the pool.
     * @dev _targetLiquidityPercent must be inclusively between 0 and ONE_HUNDRED_PERCENT.
     *      Caller must be the manager.
     * @param _targetLiquidityPercent new target liquidity percent.
     */
    function setTargetLiquidityPercent(uint16 _targetLiquidityPercent) external onlyManager {
        require(0 <= _targetLiquidityPercent && _targetLiquidityPercent <= ONE_HUNDRED_PERCENT, 
            "SaplingPoolContext: target liquidity percent is out of bounds");
        targetLiquidityPercent = _targetLiquidityPercent;
    }

    /**
     * @notice Set the protocol earning percent for the pool.
     * @dev _protocolEarningPercent must be inclusively between 0 and MAX_PROTOCOL_EARNING_PERCENT.
     *      Caller must be the governance.
     * @param _protocolEarningPercent new protocol earning percent.
     */
    function setProtocolEarningPercent(uint16 _protocolEarningPercent) external onlyGovernance {
        require(0 <= _protocolEarningPercent && _protocolEarningPercent <= MAX_PROTOCOL_EARNING_PERCENT, 
            "SaplingPoolContext: protocol earning percent is out of bounds");
        protocolEarningPercent = _protocolEarningPercent;
    }

    /**
     * @notice Set an upper bound for the manager's earn factor percent.
     * @dev _managerEarnFactorMax must be greater than or equal to ONE_HUNDRED_PERCENT.
     *      Caller must be the governance.
     *      If the current earn factor is greater than the new maximum, then the current earn factor is set to the new maximum. 
     * @param _managerEarnFactorMax new maximum for manager's earn factor.
     */
    function setManagerEarnFactorMax(uint16 _managerEarnFactorMax) external onlyGovernance {
        require(ONE_HUNDRED_PERCENT <= _managerEarnFactorMax , 
            "SaplingPoolContext: _managerEarnFactorMax is out of bounds");
        managerEarnFactorMax = _managerEarnFactorMax;

        if (managerEarnFactor > managerEarnFactorMax) {
            managerEarnFactor = managerEarnFactorMax;
            managerExcessLeverageComponent = uint256(managerEarnFactor).sub(ONE_HUNDRED_PERCENT);
        }
    }

    /**
     * @notice Set the manager's earn factor percent.
     * @dev _managerEarnFactorMax must be inclusively between ONE_HUNDRED_PERCENT and managerEarnFactorMax.
     *      Caller must be the manager.
     * @param _managerEarnFactor new manager's earn factor.
     */
    function setManagerEarnFactor(uint16 _managerEarnFactor) external onlyManager whenNotPaused {
        require(ONE_HUNDRED_PERCENT <= _managerEarnFactor && _managerEarnFactor <= managerEarnFactorMax, 
            "SaplingPoolContext: _managerEarnFactor is out of bounds");
        managerEarnFactor = _managerEarnFactor;
        managerExcessLeverageComponent = uint256(managerEarnFactor).sub(ONE_HUNDRED_PERCENT);
    }

    /**
     * @notice Deposit liquidity tokens to the pool. Depositing liquidity tokens will mint an equivalent amount of pool 
     *         tokens and transfer it to the caller. Exact exchange rate depends on the current pool state.
     * @dev Deposit amount must be non zero and not exceed amountDepositable().
     *      An appropriate spend limit must be present at the token contract.
     *      Caller must not be any of: manager, protocol, governance.
     * @param amount Liquidity token amount to deposit.
     */
    function deposit(uint256 amount) external override onlyUser whenNotPaused whenNotClosed {
        enterPool(amount);
    }

    /**
     * @notice Withdraw liquidity tokens from the pool. Withdrawals redeem equivalent amount of the caller's pool tokens
     *         by burning the tokens in question.
     *         Exact exchange rate depends on the current pool state.
     * @dev Withdrawal amount must be non zero and not exceed amountWithdrawable().
     * @param amount Liquidity token amount to withdraw.
     */
    function withdraw(uint256 amount) external override whenNotPaused {
        require(msg.sender != manager);
        exitPool(amount);
    }

    /**
     * @notice Stake liquidity tokens into the pool. Staking liquidity tokens will mint an equivalent amount of pool 
     *         tokens and lock them in the pool. Exact exchange rate depends on the current pool state.
     * @dev Caller must be the manager.
     *      Stake amount must be non zero.
     *      An appropriate spend limit must be present at the token contract.
     * @param amount Liquidity token amount to stake.
     */
    function stake(uint256 amount) external onlyManager whenNotPaused whenNotClosed {
        require(amount > 0, "SaplingPoolContext: stake amount is 0");

        uint256 shares = enterPool(amount);
        stakedShares = stakedShares.add(shares);
        updatePoolLimit();
    }

    /**
     * @notice Unstake liquidity tokens from the pool. Unstaking redeems equivalent amount of the caller's pool tokens 
     *         locked in the pool by burning the tokens in question.
     * @dev Caller must be the manager.
     *      Unstake amount must be non zero and not exceed amountUnstakable().
     * @param amount Liquidity token amount to unstake.
     */
    function unstake(uint256 amount) external onlyManager whenNotPaused {
        require(amount > 0, "SaplingPoolContext: unstake amount is 0");
        require(amount <= amountUnstakable(), "SaplingPoolContext: requested amount is not available for unstaking");

        uint256 shares = tokensToShares(amount);
        stakedShares = stakedShares.sub(shares);
        updatePoolLimit();
        exitPool(amount);
    }

    /**
     * @notice Withdraws protocol earnings belonging to the caller.
     * @dev protocolEarningsOf(msg.sender) must be greater than 0.
     *      Caller's all accumulated earnings will be withdrawn.
     *      Protocol earnings are represented in liquidity tokens.
     */
    function withdrawProtocolEarnings() external whenNotPaused {
        require(protocolEarnings[msg.sender] > 0, "SaplingPoolContext: zero protocol earnings");
        uint256 amount = protocolEarnings[msg.sender];
        protocolEarnings[msg.sender] = 0; 

        // give tokens
        tokenBalance = tokenBalance.sub(amount);
        bool success = IERC20(liquidityToken).transfer(msg.sender, amount);
        require(success);
    }

    /**
     * @notice Check liquidity token amount depositable by lenders at this time.
     * @dev Return value depends on the pool state rather than caller's balance.
     * @return Max amount of tokens depositable to the pool.
     */
    function amountDepositable() external view override returns (uint256) {
        if (poolFundsLimit <= poolFunds || closed() || paused()) {
            return 0;
        }

        return poolFundsLimit.sub(poolFunds);
    }

    /**
     * @notice Check liquidity token amount withdrawable by the caller at this time.
     * @dev Return value depends on the callers balance, and is limited by pool liquidity.
     * @param wallet Address of the wallet to check the withdrawable balance of.
     * @return Max amount of tokens withdrawable by the caller.
     */
    function amountWithdrawable(address wallet) external view override returns (uint256) {
        return paused() ? 0 : Math.min(poolLiquidity, balanceOf(wallet));
    }

    /**
     * @notice Check the manager's staked liquidity token balance in the pool.
     * @return Liquidity token balance of the manager's stake.
     */
    function balanceStaked() external view returns (uint256) {
        return sharesToTokens(stakedShares);
    }

    /**
     * @notice Check the special addresses' earnings from the protocol. 
     * @dev This method is useful for manager and protocol addresses. 
     *      Calling this method for a non-protocol associated addresses will return 0.
     * @param wallet Address of the wallet to check the earnings balance of.
     * @return Accumulated liquidity token earnings of the wallet from the protocol.
     */
    function protocolEarningsOf(address wallet) external view returns (uint256) {
        return protocolEarnings[wallet];
    }

    /**
     * @notice Estimated lender APY given the current pool state.
     * @return Estimated current lender APY
     */
    function currentLenderAPY() external view returns (uint16) {
        return lenderAPY(strategizedFunds, weightedAvgStrategyAPR);
    }

    /**
     * @notice Projected lender APY given the current pool state and a specific strategy rate and an average apr.
     * @dev Represent percentage parameter values in contract specific format.
     * @param strategyRate Percentage of pool funds projected to be used in strategies.
     * @return Projected lender APY
     */
    function projectedLenderAPY(uint16 strategyRate, uint256 _avgStrategyAPR) external view override returns (uint16) {
        require(strategyRate <= ONE_HUNDRED_PERCENT, 
            "SaplingPoolContext: invalid borrow rate; borrow rate is not less than or equal to 100%");
        return lenderAPY(Math.mulDiv(poolFunds, strategyRate, ONE_HUNDRED_PERCENT), _avgStrategyAPR);
    }

    /**
     * @notice Check wallet's liquidity token balance in the pool. This balance includes deposited balance and acquired yield.
     *         This balance does not included staked balance, leveraged earnings or protocol earnings.
     * @param wallet Address of the wallet to check the balance of.
     * @return Liquidity token balance of the wallet in this pool.
     */
    function balanceOf(address wallet) public view override returns (uint256) {
        return sharesToTokens(IPoolToken(poolToken).balanceOf(wallet));
    }

    /**
     * @notice Check liquidity token amount unstakable by the manager at this time.
     * @dev Return value depends on the manager's stake balance and targetStakePercent, and is limited by pool liquidity.
     * @return Max amount of tokens unstakable by the manager.
     */
    function amountUnstakable() public view returns (uint256) {
        if (paused() || targetStakePercent >= ONE_HUNDRED_PERCENT && totalPoolShares > stakedShares) {
            return 0;
        } else if (closed() || totalPoolShares == stakedShares) {
            return Math.min(poolLiquidity, sharesToTokens(stakedShares));
        }

        uint256 lenderShares = totalPoolShares.sub(stakedShares);
        uint256 lockedStakeShares = Math.mulDiv(lenderShares, targetStakePercent, ONE_HUNDRED_PERCENT - targetStakePercent);

        return Math.min(poolLiquidity, sharesToTokens(stakedShares.sub(lockedStakeShares)));
    }

    /**
     * @notice Current liquidity available for pool strategies such as lending or investing. 
     * @return Strategy liquidity amount.
     */
    function strategyLiquidity() public view returns (uint256) {
        uint256 lenderAllocatedLiquidity = Math.mulDiv(poolFunds, targetLiquidityPercent, ONE_HUNDRED_PERCENT);
        
        if (poolLiquidity <= lenderAllocatedLiquidity) {
            return 0;
        }

        return poolLiquidity.sub(lenderAllocatedLiquidity);
    }

    /**
     * @dev Generator for next strategy id. i.e. loan, investment.
     * @return Next available id.
     */
    function getNextStrategyId() internal nonReentrant returns (uint256) {
        uint256 id = nextStrategyId;
        nextStrategyId++;
        return id;
    }

    /**
     * @dev Internal method to enter the pool with a liquidity token amount.
     *      With the exception of the manager's call, amount must not exceed amountDepositable().
     *      If the caller is the pool manager, entered funds are considered staked.
     *      New pool tokens are minted in a way that will not influence the current share price.
     * @dev Shares are equivalent to pool tokens and are represented by them. 
     * @param amount Liquidity token amount to add to the pool on behalf of the caller.
     * @return Amount of pool tokens minted and allocated to the caller.
     */
    function enterPool(uint256 amount) internal nonReentrant returns (uint256) {
        require(amount > 0, "SaplingPoolContext: pool deposit amount is 0");

        // allow the manager to add funds beyond the current pool limit as all funds of the manager in the pool are staked,
        // and staking additional funds will in turn increase pool limit
        require(msg.sender == manager || (poolFundsLimit > poolFunds && amount <= poolFundsLimit.sub(poolFunds)),
            "SaplingPoolContext: deposit amount is over the remaining pool limit");

        uint256 shares = tokensToShares(amount);

        // charge 'amount' tokens from msg.sender
        bool success = IERC20(liquidityToken).transferFrom(msg.sender, address(this), amount);
        require(success);
        tokenBalance = tokenBalance.add(amount);

        poolLiquidity = poolLiquidity.add(amount);
        poolFunds = poolFunds.add(amount);

        // mint shares
        if (msg.sender != manager) {
            IPoolToken(poolToken).mint(msg.sender, shares);
        } else {
            IPoolToken(poolToken).mint(address(this), shares);
        }
        
        totalPoolShares = totalPoolShares.add(shares);

        return shares;
    }

    /**
     * @dev Internal method to exit the pool with a liquidity token amount.
     *      Amount must not exceed amountWithdrawable() for non managers, and amountUnstakable() for the manager.
     *      If the caller is the pool manager, exited funds are considered unstaked.
     *      Pool tokens are burned in a way that will not influence the current share price.
     * @dev Shares are equivalent to pool tokens and are represented by them. 
     * @param amount Liquidity token amount to withdraw from the pool on behalf of the caller.
     * @return Amount of pool tokens burned and taken from the caller.
     */
    function exitPool(uint256 amount) internal returns (uint256) {
        require(amount > 0, "SaplingPoolContext: pool withdrawal amount is 0");
        require(poolLiquidity >= amount, "SaplingPoolContext: insufficient liquidity");

        uint256 shares = tokensToShares(amount);

        require(msg.sender != manager && shares <= IERC20(poolToken).balanceOf(msg.sender) || shares <= stakedShares,
            "SaplingPoolContext: insufficient balance");

        // burn shares
        if (msg.sender != manager) {
            IPoolToken(poolToken).burn(msg.sender, shares);
        } else {
            IPoolToken(poolToken).burn(address(this), shares);
        }

        totalPoolShares = totalPoolShares.sub(shares);

        uint256 transferAmount = amount.sub(Math.mulDiv(amount, exitFeePercent, ONE_HUNDRED_PERCENT));

        poolFunds = poolFunds.sub(transferAmount);
        poolLiquidity = poolLiquidity.sub(transferAmount);

        tokenBalance = tokenBalance.sub(transferAmount);
        bool success = IERC20(liquidityToken).transfer(msg.sender, transferAmount);
        require(success);

        return shares;
    }

    /**
     * @dev Internal method to update the pool funds limit based on the staked funds. 
     */
    function updatePoolLimit() internal nonReentrant {
        poolFundsLimit = sharesToTokens(Math.mulDiv(stakedShares, ONE_HUNDRED_PERCENT, targetStakePercent));
    }

    /**
     * @notice Get liquidity token value of shares. 
     * @dev Shares are equivalent to pool tokens and are represented by them. 
     * @param shares Amount of shares
     */
    function sharesToTokens(uint256 shares) internal view returns (uint256) {
        if (shares == 0 || poolFunds == 0) {
             return 0;
        }

        return Math.mulDiv(shares, poolFunds, totalPoolShares);
    }

    /**
     * @notice Get a share value of liquidity tokens.
     * @dev Shares are equivalent to pool tokens and are represented by them. 
     * @param tokens Amount of liquidity tokens.
     */
    function tokensToShares(uint256 tokens) internal view returns (uint256) {
        if (totalPoolShares == 0) {
            // a pool with no positions
            return tokens;
        } else if (poolFunds == 0) {
            /* 
                Handle failed pool case, where: poolFunds == 0, but totalPoolShares > 0
                To minimize loss for the new depositor, assume the total value of existing shares is the minimum possible nonzero integer, which is 1
                simplify (tokens * totalPoolShares) / 1 as tokens * totalPoolShares
            */
            return tokens.mul(totalPoolShares);
        }

        return Math.mulDiv(tokens, totalPoolShares, poolFunds);
    }

    /**
     * @dev All time count of created strategies. i.e. Loans and investments
     */
    function strategyCount() internal view returns(uint256) {
        return nextStrategyId - 1;
    }

    /**
     * @notice Lender APY given the current pool state, a specific strategized funds, and an average apr.
     * @dev Represent percentage parameter values in contract specific format.
     * @param _strategizedFunds Pool funds to be borrowed annually.
     * @return Lender APY
     */
    function lenderAPY(uint256 _strategizedFunds, uint256 _avgStrategyAPR) internal view returns (uint16) {
        if (poolFunds == 0 || _strategizedFunds == 0 || _avgStrategyAPR == 0) {
            return 0;
        }
        
        // pool APY
        uint256 poolAPY = Math.mulDiv(_avgStrategyAPR, _strategizedFunds, poolFunds);
        
        // protocol APY
        uint256 protocolAPY = Math.mulDiv(poolAPY, protocolEarningPercent, ONE_HUNDRED_PERCENT);
        
        uint256 remainingAPY = poolAPY.sub(protocolAPY);

        // manager withdrawableAPY
        uint256 currentStakePercent = Math.mulDiv(stakedShares, ONE_HUNDRED_PERCENT, totalPoolShares);
        uint256 managerEarningsPercent = Math.mulDiv(currentStakePercent, managerExcessLeverageComponent, ONE_HUNDRED_PERCENT);
        uint256 managerWithdrawableAPY = Math.mulDiv(remainingAPY, managerEarningsPercent, managerEarningsPercent + ONE_HUNDRED_PERCENT);

        return uint16(remainingAPY.sub(managerWithdrawableAPY));
    }

    /**
     * @notice Check if the pool is functional based on the current stake levels.
     * @return True if the staked funds provide at least a minimum ratio to the pool funds, False otherwise.
     */
    function isPoolFunctional() internal view returns (bool) {
        return !(paused() || closed()) && stakedShares >= Math.mulDiv(totalPoolShares, targetStakePercent, ONE_HUNDRED_PERCENT);
    }


    /**
     * @dev Implementation of the abstract hook in SaplingManagedContext.
     *      Governance, protocol wallet addresses and lenders with at least 1.00 liquidity tokens are authorised to take
     *      certain actions when the manager is inactive.
     */
    function authorizedOnInactiveManager(address caller) internal view override returns (bool) {
        return caller == governance || caller == protocol || sharesToTokens(IERC20(poolToken).balanceOf(caller)) >= ONE_TOKEN;
    }

    /**
     * @dev Implementation of the abstract hook in SaplingManagedContext.
     *      Pool can be close when no funds remain committed to strategies.
     */
    function canClose() internal view override returns (bool) {
        return strategizedFunds == 0;
    }
}