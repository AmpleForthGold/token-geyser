pragma solidity 0.5.0;

/**
 * @title IMidasAgent 
 * @dev The IStaking interface + some extras to allow for 
 *      receiving tokens to be distributed.  
 */
contract IMidasAgent {

    /*
     * Allows adding of tokens directly to the 'unlocked' staking 
     * pool. It is the interface between the MidasDistributor and 
     * the MidasAgent contracts. 
     */
    function addTokens(uint256 amount) external returns (bool);
}