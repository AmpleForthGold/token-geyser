pragma solidity 0.5.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";

import "./IStaking.sol";
import "./TokenPool.sol";

/**
 * @title MidasAgent
 * @dev A smart-contract based mechanism to distribute tokens over time, inspired loosely by
 *      Compound and Uniswap. Code (mostly) comes from Ampleforth TokenGeyser-sol.
 *
 *      Distribution tokens are added to the contract (pool) and become available to be 
 *      claimed by users.
 *
 *      A user may deposit tokens to accrue ownership share over the distribution pool. This owner share
 *      is a function of the number of tokens deposited as well as the length of time deposited.
 *      Specifically, a user's share of the distribution pool equals their "deposit-seconds"
 *      divided by the global "deposit-seconds". This aligns the new token distribution with long
 *      term supporters of the project, addressing one of the major drawbacks of simple airdrops.
 */
contract MidasAgent is IStaking, Ownable {
    using SafeMath for uint256;

    event Staked(
        address indexed user,
        uint256 amount,
        uint256 total,
        bytes data
    );
    event Unstaked(
        address indexed user,
        uint256 amount,
        uint256 total,
        bytes data
    );
    event TokensClaimed(address indexed user, uint256 amount);
    event TokensUnlocked(uint256 amount, uint256 total);

    TokenPool private _stakingPool;
    IERC20 private _distributionToken;

    //
    // Time-bonus params
    //
    uint256 public constant BONUS_DECIMALS = 2;
    uint256 public startBonus = 0;
    uint256 public bonusPeriodSec = 0;

    //
    // Global accounting state
    //
    uint256 public totalStakingShares = 0;
    uint256 private _totalStakingShareSeconds = 0;
    uint256 private _lastAccountingTimestampSec = now;
    uint256 private _initialSharesPerToken = 0;

    //
    // User accounting state
    //
    // Represents a single stake for a user. A user may have multiple.
    struct Stake {
        uint256 stakingShares;
        uint256 timestampSec;
    }

    // Caches aggregated values from the User->Stake[] map to save computation.
    // If lastAccountingTimestampSec is 0, there's no entry for that user.
    struct UserTotals {
        uint256 stakingShares;
        uint256 stakingShareSeconds;
        uint256 lastAccountingTimestampSec;
    }

    // Aggregated staking values per user
    mapping(address => UserTotals) private _userTotals;

    // The collection of stakes for each user. Ordered by timestamp, earliest to latest.
    mapping(address => Stake[]) private _userStakes;

    // managment locking interface. can lock both/either staking and/or unstaking functions. 
    uint8 private constant LOCK_STAKING = uint8(0x01);
    uint8 private constant LOCK_UNSTAKING = uint8(0x02);
    uint8 public locks = uint8(0x00); // unlocked

    /**
     * @param stakingToken The token users deposit as stake.
     *                    [ Varies depending on Agent. ]
     * @param distributionToken The token users receive as they unstake.
     *                    [Always 0x8E54954B3Bbc07DbE3349AEBb6EAFf8D91Db5734]
     * @param startBonus_ Starting time bonus, BONUS_DECIMALS fixed point.
     *                    e.g. 25% means user gets 25% of max distribution tokens.
     *                    [AmpleForthGold default = 100  (100%)]
     * @param bonusPeriodSec_ Length of time for bonus to increase linearly to max.
     *                    [AmpleForthGold default = 100 days = 8640000 seconds]
     * @param initialSharesPerToken Number of shares to mint per staking token on first stake.
     *                    [AmpleForthGold default = 1000000 (same as Ampleforth)]
     */
    constructor(
        IERC20 stakingToken,
        IERC20 distributionToken,
        uint256 startBonus_,
        uint256 bonusPeriodSec_,
        uint256 initialSharesPerToken
    ) public {
        // The start bonus must be some fraction of the max. (i.e. <= 100%)
        require(
            startBonus_ <= 10**BONUS_DECIMALS,
            "TokenGeyser: start bonus too high"
        );
        // If no period is desired, instead set startBonus = 100%
        // and bonusPeriod to a small value like 1sec.
        require(bonusPeriodSec_ != 0, "TokenGeyser: bonus period is zero");
        require(
            initialSharesPerToken > 0,
            "TokenGeyser: initialSharesPerToken is zero"
        );

        _stakingPool = new TokenPool(stakingToken);
        _distributionToken = distributionToken;
        startBonus = startBonus_;
        bonusPeriodSec = bonusPeriodSec_;
        _initialSharesPerToken = initialSharesPerToken;
    }

    /**
     * @return The token users deposit as stake.
     */
    function getStakingToken() public view returns (IERC20) {
        return _stakingPool.token();
    }

    /**
     * @return The token users receive as they unstake.
     */
    function getDistributionToken() public view returns (IERC20) {
        return _distributionToken;
    }

    /**
     * @dev Transfers amount of deposit tokens from the user.
     * @param amount Number of deposit tokens to stake.
     * @param data Not used.
     */
    function stake(uint256 amount, bytes calldata data) external {
        _stakeFor(msg.sender, msg.sender, amount);
    }

    /**
     * ==> Low gas equal of stake() above.
     *     Original function remains as it implements IStaking interface.
     *
     * @dev Transfers amount of deposit tokens from the user.
     * @param amount Number of deposit tokens to stake.
     */
    function lgstake(uint256 amount) external {
        _stakeFor(msg.sender, msg.sender, amount);
    }

    /**
     * @dev Transfers amount of deposit tokens from the caller on behalf of user.
     * @param user User address who gains credit for this stake operation.
     * @param amount Number of deposit tokens to stake.
     * @param data Not used.
     */
    function stakeFor(
        address user,
        uint256 amount,
        bytes calldata data
    ) external {
        _stakeFor(msg.sender, user, amount);
    }

    /**
     * ==> Low gas equal of stakeFor() above.
     *     Original function remains as it implements IStaking interface.
     *
     * @dev Transfers amount of deposit tokens from the caller on behalf of user.
     * @param user User address who gains credit for this stake operation.
     * @param amount Number of deposit tokens to stake.
     */
    function lgstakeFor(
        address user,
        uint256 amount) external {
        _stakeFor(msg.sender, user, amount);
    }

    /**
     * @dev Private implementation of staking methods.
     * @param staker User address who deposits tokens to stake.
     * @param beneficiary User address who gains credit for this stake operation.
     * @param amount Number of deposit tokens to stake.
     */
    function _stakeFor(
        address staker,
        address beneficiary,
        uint256 amount
    ) private {
        require (locks & LOCK_STAKING == uint8(0x0));
        require(amount > 0, "TokenGeyser: stake amount is zero");
        require(
            beneficiary != address(0),
            "TokenGeyser: beneficiary is zero address"
        );
        require(
            totalStakingShares == 0 || totalStaked() > 0,
            "TokenGeyser: Invalid state. Staking shares exist, but no staking tokens do"
        );

        uint256 mintedStakingShares = (totalStakingShares > 0)
            ? totalStakingShares.mul(amount).div(totalStaked())
            : amount.mul(_initialSharesPerToken);
        require(
            mintedStakingShares > 0,
            "TokenGeyser: Stake amount is too small"
        );

        updateAccounting();

        // 1. User Accounting
        UserTotals storage totals = _userTotals[beneficiary];
        totals.stakingShares = totals.stakingShares.add(mintedStakingShares);
        totals.lastAccountingTimestampSec = now;

        Stake memory newStake = Stake(mintedStakingShares, now);
        _userStakes[beneficiary].push(newStake);

        // 2. Global Accounting
        totalStakingShares = totalStakingShares.add(mintedStakingShares);
        // Already set in updateAccounting()
        // _lastAccountingTimestampSec = now;

        // interactions
        require(
            _stakingPool.token().transferFrom(
                staker,
                address(_stakingPool),
                amount
            ),
            "TokenGeyser: transfer into staking pool failed"
        );

        emit Staked(beneficiary, amount, totalStakedFor(beneficiary), "");
    }

    /**
     * @dev Unstakes a certain amount of previously deposited tokens. User also receives their
     * alotted number of distribution tokens.
     * @param amount Number of deposit tokens to unstake / withdraw.
     * @param data Not used.
     */
    function unstake(uint256 amount, bytes calldata data) external {
        _unstake(amount);
    }

    /**
     * ==> Low gas equal of unstake() above.
     *     Original function remains as it implements IStaking interface.
     *
     * @dev Unstakes a certain amount of previously deposited tokens. User also receives their
     * alotted number of distribution tokens.
     * @param amount Number of deposit tokens to unstake / withdraw.
     */
    function lgunstake(uint256 amount) external {
        _unstake(amount);
    }

    /**
     * @param amount Number of deposit tokens to unstake / withdraw.
     * @return The total number of distribution tokens that would be rewarded.
     */
    function unstakeQuery(uint256 amount) public returns (uint256) {
        return _unstake(amount);
    }

    /**
     * @dev Unstakes a certain amount of previously deposited tokens. 
     *      User also receives their alotted number of distribution 
     *      tokens.
     * @param amount Number of deposit tokens to unstake / withdraw.
     * @return The total number of distribution tokens rewarded.
     */
    function _unstake(uint256 amount) private returns (uint256) {
        require (locks & LOCK_UNSTAKING == uint8(0x0));

        updateAccounting();

        // checks
        require(amount > 0, "TokenGeyser: unstake amount is zero");
        require(
            totalStakedFor(msg.sender) >= amount,
            "TokenGeyser: unstake amount is greater than total user stakes"
        );
        uint256 stakingSharesToBurn = totalStakingShares.mul(amount).div(
            totalStaked()
        );
        require(
            stakingSharesToBurn > 0,
            "TokenGeyser: Unable to unstake amount this small"
        );

        // 1. User Accounting
        UserTotals storage totals = _userTotals[msg.sender];
        Stake[] storage accountStakes = _userStakes[msg.sender];

        // Redeem from most recent stake and go backwards in time.
        uint256 stakingShareSecondsToBurn = 0;
        uint256 sharesLeftToBurn = stakingSharesToBurn;
        uint256 rewardAmount = 0;
        while (sharesLeftToBurn > 0) {
            Stake storage lastStake = accountStakes[accountStakes.length - 1];
            uint256 stakeTimeSec = now.sub(lastStake.timestampSec);
            uint256 newStakingShareSecondsToBurn = 0;
            if (lastStake.stakingShares <= sharesLeftToBurn) {
                // fully redeem a past stake
                newStakingShareSecondsToBurn = lastStake.stakingShares.mul(
                    stakeTimeSec
                );
                rewardAmount = computeNewReward(
                    rewardAmount,
                    newStakingShareSecondsToBurn,
                    stakeTimeSec
                );
                stakingShareSecondsToBurn = stakingShareSecondsToBurn.add(
                    newStakingShareSecondsToBurn
                );
                sharesLeftToBurn = sharesLeftToBurn.sub(
                    lastStake.stakingShares
                );
                accountStakes.length--;
            } else {
                // partially redeem a past stake
                newStakingShareSecondsToBurn = sharesLeftToBurn.mul(
                    stakeTimeSec
                );
                rewardAmount = computeNewReward(
                    rewardAmount,
                    newStakingShareSecondsToBurn,
                    stakeTimeSec
                );
                stakingShareSecondsToBurn = stakingShareSecondsToBurn.add(
                    newStakingShareSecondsToBurn
                );
                lastStake.stakingShares = lastStake.stakingShares.sub(
                    sharesLeftToBurn
                );
                sharesLeftToBurn = 0;
            }
        }
        totals.stakingShareSeconds = totals.stakingShareSeconds.sub(
            stakingShareSecondsToBurn
        );
        totals.stakingShares = totals.stakingShares.sub(stakingSharesToBurn);
        // Already set in updateAccounting
        // totals.lastAccountingTimestampSec = now;

        // 2. Global Accounting
        _totalStakingShareSeconds = _totalStakingShareSeconds.sub(
            stakingShareSecondsToBurn
        );
        totalStakingShares = totalStakingShares.sub(stakingSharesToBurn);
        // Already set in updateAccounting
        // _lastAccountingTimestampSec = now;

        // interactions
        require(
            _stakingPool.transfer(msg.sender, amount),
            "TokenGeyser: transfer out of staking pool failed"
        );
        require(
            _distributionToken.transfer(msg.sender, rewardAmount),
            "TokenGeyser: transfer out of unlocked pool failed"
        );

        emit Unstaked(msg.sender, amount, totalStakedFor(msg.sender), "");
        emit TokensClaimed(msg.sender, rewardAmount);

        require(
            totalStakingShares == 0 || totalStaked() > 0,
            "TokenGeyser: Error unstaking. Staking shares exist, but no staking tokens do"
        );
        return rewardAmount;
    }

    /**
     * @dev Applies an additional time-bonus to a distribution amount. This is necessary to
     *      encourage long-term deposits instead of constant unstake/restakes.
     *      The bonus-multiplier is the result of a linear function that starts at startBonus and
     *      ends at 100% over bonusPeriodSec, then stays at 100% thereafter.
     * @param currentRewardTokens The current number of distribution tokens already alotted for this
     *                            unstake op. Any bonuses are already applied.
     * @param stakingShareSeconds The stakingShare-seconds that are being burned for new
     *                            distribution tokens.
     * @param stakeTimeSec Length of time for which the tokens were staked. Needed to calculate
     *                     the time-bonus.
     * @return Updated amount of distribution tokens to award, with any bonus included on the
     *         newly added tokens.
     */
    function computeNewReward(
        uint256 currentRewardTokens,
        uint256 stakingShareSeconds,
        uint256 stakeTimeSec
    ) private view returns (uint256) {
        uint256 newRewardTokens = totalUnlocked().mul(stakingShareSeconds).div(
            _totalStakingShareSeconds
        );

        if (stakeTimeSec >= bonusPeriodSec) {
            return currentRewardTokens.add(newRewardTokens);
        }

        uint256 oneHundredPct = 10**BONUS_DECIMALS;
        uint256 bonusedReward = startBonus
            .add(
            oneHundredPct.sub(startBonus).mul(stakeTimeSec).div(bonusPeriodSec)
        )
            .mul(newRewardTokens)
            .div(oneHundredPct);
        return currentRewardTokens.add(bonusedReward);
    }

    /**
     * @param addr The user to look up staking information for.
     * @return The number of staking tokens deposited for addr.
     */
    function totalStakedFor(address addr) public view returns (uint256) {
        return
            totalStakingShares > 0
                ? totalStaked().mul(_userTotals[addr].stakingShares).div(
                    totalStakingShares
                )
                : 0;
    }

    /**
     * @return The total number of deposit tokens staked globally, by all users.
     */
    function totalStaked() public view returns (uint256) {
        return _stakingPool.balance();
    }

    /**
     * @dev Note that this application has a staking token as well as a distribution token, which
     * may be different. This function is required by EIP-900.
     * @return The deposit token used for staking.
     */
    function token() external view returns (address) {
        return address(getStakingToken());
    }

    /**
     * @dev A globally callable function to update the accounting state of the system.
     *      Global state and state for the caller are updated.
     * @return [0] balance of the unlocked pool
     * @return [1] caller's staking share seconds
     * @return [2] global staking share seconds
     * @return [3] Rewards caller has accumulated, optimistically assumes max time-bonus.
     * @return [4] block timestamp
     */
    function updateAccounting()
        public
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        // Global accounting
        uint256 newStakingShareSeconds = now
            .sub(_lastAccountingTimestampSec)
            .mul(totalStakingShares);
        _totalStakingShareSeconds = _totalStakingShareSeconds.add(
            newStakingShareSeconds
        );
        _lastAccountingTimestampSec = now;

        // User Accounting
        UserTotals storage totals = _userTotals[msg.sender];
        uint256 newUserStakingShareSeconds = now
            .sub(totals.lastAccountingTimestampSec)
            .mul(totals.stakingShares);
        totals.stakingShareSeconds = totals.stakingShareSeconds.add(
            newUserStakingShareSeconds
        );
        totals.lastAccountingTimestampSec = now;

        uint256 totalUserRewards = (_totalStakingShareSeconds > 0)
            ? totalUnlocked().mul(totals.stakingShareSeconds).div(
                _totalStakingShareSeconds
            )
            : 0;

        return (
            totalUnlocked(),
            totals.stakingShareSeconds,
            _totalStakingShareSeconds,
            totalUserRewards,
            now
        );
    }

    /**
     * @return Total number of unlocked distribution tokens.
     */
    function totalUnlocked() public view returns (uint256) {
        return _distributionToken.balanceOf(address(this));
    }

    /**
     * Returns the balance to the owner of the contract. This is needed
     * if there is a contract upgrade & for testing & validation purposes.
     */
    function returnBalance2Owner() external onlyOwner returns (bool) {
        uint256 value = totalUnlocked();
        require(value > 0);
        return _distributionToken.transfer(owner(), value);
    }

    /* Managment (owner) function to disable/enable stakeing and
     * unstaking functions. Used to disable agent before rollout. */
    function setLocks(uint8 _locks) external onlyOwner {
        locks = _locks;
    }
}
