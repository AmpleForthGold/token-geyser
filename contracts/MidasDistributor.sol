pragma solidity 0.5.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";

import "./TokenPool.sol";

/**
 * @title Midas Distributor
 * @dev A smart-contract based mechanism to distribute tokens over time, inspired loosely by
 *      Compound, Uniswap and Ampleforth.
 *
 *      The ampleforth geyser has the concept of a 'locked pool' in the geyser. MidasDistributor
 *      performs a similar action to the ampleforth geyser locked pool but allows for multiple
 *      geysers (which we call MidasAgents).
 *
 *      Distribution tokens are added to a pool in the contract and, over time, are sent to
 *      multiple midas agents based on a distribution share. Each agent gets a set
 *      percentage of the pool each time a distribution occurs.
 *
 *      Before unstaking the tokens in an agent it would be benifical to maximise the 
 *      take: to perform a distribution. That distribution event would be at the stakholders
 *      expense, and we allow anyone to perform a distribution.
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

    /* Allows us to represent a number by moving the decimal point. */
    uint256 public constant DECIMALS_EXP = 10**12;

    /* Represents the distribution rate per second.
     * Distribution rate is (0.5% per day) == (5.78703e-8 per second).
     */
    uint256 public constant PER_SECOND_INTEREST 
        = (DECIMALS_EXP * 5) / (1000 * 1 days);

    /* The collection of Agents and their percentage share. */
    struct MidasAgent {
        
        /* reference to a Midas Agent (destination for distributions) */
        address agent;

        /* Share of the distribution as a percentage.
         * i.e. 14% == 14
         * The sum of all shares must be equal to 100.
         */
        uint8 share;
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
    function addAgent(address _agent, uint8 _share) external onlyOwner {
        require(_share <= uint8(100));
        distributing = false;
        agents.push(MidasAgent({agent: _agent, share: _share}));
    }

    /**
     * @notice Removes an Agent
     * @param _index Index of Agent to remove.
     *              Agent ordering may have changed since adding.
     */
    function removeAgent(uint256 _index) external onlyOwner {
        require(_index < agents.length, "index out of bounds");
        distributing = false;
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
    function setAgentShare(uint256 _index, uint8 _share) external onlyOwner {
        require(
            _index < agents.length,
            "index must be in range of stored tx list"
        );
        require(_share <= uint8(100));
        distributing = false;
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
        return (uint256(100) == sum);
    }

    /**
     * @return gets the total balance of the distributor
     */
    function balance() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function getElapsedTime() public view returns(uint256) {
        /* Checking for a wormhole or time dialation event.
         * this error may also be caused by sunspots. */
        require(block.timestamp >= lastDistributionTimestamp);
        return (block.timestamp - lastDistributionTimestamp);
    }

    /* Gets the (total) amount that would be distributed
     * if a distribution event happened now. */
    function getDistributionAmount() public view returns (uint256) {
        return
            balance()
            .mul(getElapsedTime())
            .mul(PER_SECOND_INTEREST)
            .div(DECIMALS_EXP);
    }

    /* Gets the amount that would be distributed to a specific agent
     * if a distribution event happened now. */
    function getAgentDistributionAmount(uint256 index)
        public
        view
        returns (uint256)
    {
        require(checkAgentPercentage() == true);
        require(index < agents.length);

        return
            getDistributionAmount()
            .mul(agents[index].share)
            .div(100);
    }

    /**
     * Distributes the tokens based on the balance and the distribution rate.
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
                require(token.transfer(agents[i].agent, amount));
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
        if (value == 0) {
            return true;
        }
        return token.transfer(owner(), value);
    }
}
