pragma solidity 0.5.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";

import "./TokenPool.sol";
import "./IStaking.sol";

/**
 * @title Midas Distributor
 * @dev A smart-contract based mechanism to distribute tokens over time, inspired loosely by
 *      Compound, Uniswap and Ampleforth.
 *
 *      Distribution tokens are added to a pool in the contract and, over time, are sent to 
 *      multipe midas geysers based on a distribution schedule. Each geyser gets a set 
 *      percentage of the pool each time a distribution occurs.
 *
 *      Multiple midas Geysers can be registered, deregistered and have their distribution
 *      percentage adjusted. 
 *
 *      The ampleforth geyser has the concept of a 'locked pool' in the geyser. This contract
 *      performs a similar action to the ampleforth geyser locked pool but allows for multiple
 *      geysers. 
 *
 *      More background and motivation available at the AmpleForthGold github & website.
 */
contract MidasDistributor is Ownable {
    using SafeMath for uint256;

    event TokensLocked(uint256 amount, uint256 total);
    event TokensDistributed(uint256 amount, uint256 total);

    // the ERC20 token to distribute
    IERC20 public token;
    
    // timestamp of last distribution event. 
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
    bool public enabled = false;
        
    // The collection of Agents and there percentage cut. 
    uint256 public constant SHARE_DECIMALS = 10; 
    uint256 public constant SHARE_DECIMALS_EXP = 10**SHARE_DECIMALS;
    uint256 public constant PER_SECOND_INTEREST = SHARE_DECIMALS_EXP * 5 / (100 *1 days); 
    
    struct MidasAgent {
        
        // reference to a Geyser that implements the IStaking interface
        // (as our Geysers all do).
        IStaking agent;

        // Share of the distribution as a percentage. 
        // i.e. 24% == (0.14*(1eSHARE_DECIMALS))
        // The sum of all shares mus equal  
        uint16 share;
    }
    MidasAgent[] public agents;

    /**
     * @param _distributionToken The token to be distributed.
     */
    constructor(IERC20 _distributionToken) 
        public 
    {
        token = _distributionToken;
        lastDistributionTimestamp = block.timestamp;
    }

    /**
     * @notice Sets the enable stae of the contract 
     * @param _enable the enable state.
    */
    function setState(bool _enable)
        external
        onlyOwner
    {
        if (_enable == true) {
            // we can only become enabled if the sum
            // of shares == 100%.
            require(checkAgentPercentage() == true);
        }
        enabled = _enable;
    }

    /**
     * @notice Adds an Agent 
     * @param _agent Address of the destination agent
     * @param _share Percentage share of distribution
     */
    function addAgent(IStaking _agent, uint16 _share)
        external
        onlyOwner
    {
        require(enabled == false);
        require(_share <= SHARE_DECIMALS_EXP); 
        
        agents.push(MidasAgent({
            agent: _agent,
            share: _share
        }));
    }

    /**
     * @param _index Index of Agent to remove.
     *              Agent ordering may have changed since adding.
     */
    function removeAgent(uint _index)
        external
        onlyOwner
    {
        require(enabled == false);
        require(_index < agents.length, "index out of bounds");

        if (_index < agents.length - 1) {
            agents[_index] = agents[agents.length - 1];
        }

        agents.length--;
    }

    /**
     * @param _index Index of Agents. Ordering may have changed since adding.
     * @param _share Percentage share of the distribution.
     */
    function setAgentShare(uint _index, uint16 _share)
        external
        onlyOwner
    {
        require(enabled == false);
        require(_index < agents.length, "index must be in range of stored tx list");
        require(_share <= SHARE_DECIMALS_EXP); 
        agents[_index].share = _share;
    }

    /**
     * @return Number of agents, in agents list.
     */
    function agentsSize()
        external
        view
        returns (uint256)
    {
        return agents.length;
    }

    /**
    * @return boolean true if the percentage of all 
    *         agents equals 100%. */
    function checkAgentPercentage()
    view 
    public
    returns (bool)
    {       
        uint256 sum = 0; 
        for (uint256 i = 0; i < agents.length; i++) {
            sum += agents[i].share; 
        }
        return (SHARE_DECIMALS_EXP == sum); 
    } 

    /**
     * @return gets the balance of the distributor
     */
    function balance() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * Distrubutes the tokens based on the balance, time since last 
     * distribution and the interst rate.
     */
    function distribute()
    external 
    {
        require(enabled == true);
        require(checkAgentPercentage() == true);

        // checking for a wormhole or time dialation event.
        // this error may also be caused by sunspots. 
        require(block.timestamp > lastDistributionTimestamp);

        uint256 elapsedTime = block.timestamp - lastDistributionTimestamp;
        
        // require at least 1 hour to have passed since the last 
        // distribute event. 
        require(elapsedTime > 1 hours);

        uint256 bal = balance();
        uint256 total_amount = bal.mul(elapsedTime).mul(PER_SECOND_INTEREST).div(SHARE_DECIMALS_EXP);
        require(total_amount > 0);
        for (uint256 i = 0; i < agents.length; i++) {
            uint256 amount = total_amount.mul(agents[i].share).div(SHARE_DECIMALS_EXP);
            if (amount > 0){
                require(agents[i].agent.addTokens(amount));
            }
        }
        lastDistributionTimestamp = block.timestamp;
    }    
}
