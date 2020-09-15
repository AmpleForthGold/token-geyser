pragma solidity 0.5.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";

import "./TokenPool.sol";
import "./IMidasAgent.sol";

/**
 * @title Midas Distributor
 * @dev A smart-contract based mechanism to distribute tokens over time, inspired loosely by
 *      Compound, Uniswap and Ampleforth.
 *
 *      The ampleforth geyser has the concept of a 'locked pool' in the geyser. MidasDistributor
 *      performs a similar action to the ampleforth geyser locked pool but allows for multiple
 *      geysers (which we call IMidasAgents).
 *
 *      Distribution tokens are added to a pool in the contract and, over time, are sent to
 *      multiple midas agents based on a distribution share. Each agent gets a set
 *      percentage of the pool each time a distribution occurs.
 *
 *      Distributions are limited to (at most) 1 per hour. Before unstaking the tokens in an
 *      agent it would be benifical to maximise the take: to perform a distribution. That
 *      distribution event would be at the stakholders expense, and we allow anyone to
 *      perform a distribution.
 *
 *      Multiple midas agents can be registered, deregistered and have their distribution
 *      percentage adjusted. The distributor must be locked for adjustments to be made.
 *
 *      More background and motivation available at the AmpleForthGold github & website.
 */
contract MidasDistributor is Ownable {
    using SafeMath for uint256;

    event TokensLocked(uint256 amount, uint256 total);
    event TokensDistributed(uint256 amount, uint256 total);

    /* the ERC20 token to distribute */
    IERC20 public token;

    /* timestamp of last distribution event. */
    uint256 public lastDistributionTimestamp;

    /* When *true* the distributor:
     *      1) shall distribute tokens to agents,
     *      2) shall not allow for the registration or
     *         modification of agent details.
     * When *false* the distributor:
     *      1) shall not distribute tokens to agents,
     *      2) shall allow for the registration and
     *         modification of agent details.
     */
    bool public distributing = false;

    /* How long to wait between distributions. */
    uint256 public constant DISTRIBUTION_WAIT_PERIOD = 1 days;

    /* Allows us to represent a percenatge by moving the
     * decimal point.
     */

    uint256 public constant SHARE_DECIMALS = 10;
    uint256 public constant SHARE_DECIMALS_EXP = 10**SHARE_DECIMALS;

    /* Represents the distribution rate per second.
     * Distribution rate is (0.5% per day) == (5.78703e-6 per second).
     */
    uint256 public constant PER_SECOND_INTEREST = (SHARE_DECIMALS_EXP * 5) /
        (100 * 1 days);

    /* The collection of Agents and their percentage share. */
    struct MidasAgent {
        /* reference to a Midas Agent (destination for distributions) */
        IMidasAgent agent;
        /* Share of the distribution as a percentage.
         * i.e. 14% == (0.14 * SHARE_DECIMALS_EXP)
         * The sum of all shares must be equal to SHARE_DECIMALS_EXP.
         */
        uint16 share;
    }
    MidasAgent[] public agents;

    /**
     * @param _distributionToken The token to be distributed.
     */
    constructor(IERC20 _distributionToken) public {
        token = _distributionToken;
        lastDistributionTimestamp = block.timestamp;
    }

    /**
     * @notice Sets the distributing state of the contract
     * @param _distributing the distributing state.
     */
    function setDistributionState(bool _distributing) external onlyOwner {
        /* we can only become enabled if the sum of shares == 100%. */

        if (_distributing == true) {
            require(checkAgentPercentage() == true);
        }

        distributing = _distributing;
    }

    /**
     * @notice Adds an Agent
     * @param _agent Address of the destination agent
     * @param _share Percentage share of distribution (can be 0)
     */
    function addAgent(IMidasAgent _agent, uint16 _share) external onlyOwner {
        require(distributing == false);
        require(_share <= SHARE_DECIMALS_EXP);

        agents.push(MidasAgent({agent: _agent, share: _share}));
    }

    /**
     * @notice Removes an Agent
     * @param _index Index of Agent to remove.
     *              Agent ordering may have changed since adding.
     */
    function removeAgent(uint256 _index) external onlyOwner {
        require(distributing == false);
        require(_index < agents.length, "index out of bounds");

        if (_index < agents.length - 1) {
            agents[_index] = agents[agents.length - 1];
        }

        agents.length--;
    }

    /**
     * @notice Sets an Agents share of the distribution.
     * @param _index Index of Agents. Ordering may have changed since adding.
     * @param _share Percentage share of the distribution (can be 0).
     */
    function setAgentShare(uint256 _index, uint16 _share) external onlyOwner {
        require(distributing == false);
        require(
            _index < agents.length,
            "index must be in range of stored tx list"
        );
        require(_share <= SHARE_DECIMALS_EXP);
        agents[_index].share = _share;
    }

    /**
     * @return Number of midas agents in agents list.
     */
    function agentsSize() public view returns (uint256) {
        return agents.length;
    }

    /**
     * @return boolean true if the percentage of all
     *         agents equals 100%. */
    function checkAgentPercentage() public view returns (bool) {
        uint256 sum = 0;
        for (uint256 i = 0; i < agents.length; i++) {
            sum += agents[i].share;
        }
        return (SHARE_DECIMALS_EXP == sum);
    }

    /**
     * @return gets the total balance of the distributor
     */
    function balance() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /* Gets the (total) amount that would be distributed 
     * if a distribution event happened now. */
    function getDistributionAmount() public view returns(uint256) {
        
        require(distributing == true);
        require(checkAgentPercentage() == true);

        /* Checking for a wormhole or time dialation event.
         * this error may also be caused by sunspots. */
        require(block.timestamp > lastDistributionTimestamp);

        /* Require at least DISTRIBUTION_WAIT_PERIOD to have passed 
         * since the last distribute event. */
        uint256 elapsedTime = block.timestamp - lastDistributionTimestamp;
        if (elapsedTime > DISTRIBUTION_WAIT_PERIOD) {
            return 0;
        }
        
        uint256 bal = balance();
        uint256 total_amount = bal
            .mul(elapsedTime)
            .mul(PER_SECOND_INTEREST)
            .div(SHARE_DECIMALS_EXP);
        return total_amount;
    }

    /* Gets the amount that would be distributed to a specific agent 
     * if a distribution event happened now. */
    function getAgentDistributionAmount(uint256 index) public view returns(uint256) {
        require(distributing == true);
        require(checkAgentPercentage() == true);

        uint256 total = getDistributionAmount();
        
        require(index < agents.length);
        return total.mul(agents[index].share).div(SHARE_DECIMALS_EXP);        
    }
    
    /**
     * Distributes the tokens based on the balance, time since last
     * distribution and the distribution rate.
     *
     * Anyone can call, and should call prior to an unstake event.
     */
    function distribute() external {
        require(distributing == true);
        require(checkAgentPercentage() == true);
        require(getDistributionAmount() > 0);

        for (uint256 i = 0; i < agents.length; i++) {
            uint256 amount = getAgentDistributionAmount(i);
            if (amount > 0) {
                require(agents[i].agent.addTokens(amount));
            }
        }
        lastDistributionTimestamp = block.timestamp;
    }

    /**
     * Returns the balance to the owner of the contract. This is needed
     * if there is a contract upgrade & for testing & validation purposes.
     */
    function returnBalance2Owner() external onlyOwner returns (bool) {
        uint256 value = balance();
        require(value > 0);
        return token.transfer(address(this), value);
    }
}
