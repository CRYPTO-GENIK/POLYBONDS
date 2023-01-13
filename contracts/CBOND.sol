pragma solidity ^0.6.0;

import "./openzeppelin/token/ERC20/IERC20.sol";
import "./openzeppelin/token/ERC721/ERC721.sol";
import "./openzeppelin/math/SafeMath.sol";
import "./openzeppelin/math/Math.sol";
import "./openzeppelin/access/Ownable.sol";
import "./openzeppelin/utils/Strings.sol";
import "./Sync.sol";
import "./AddressStrings.sol";

contract POLYBOND is ERC721, Ownable {
  using SafeMath for uint256;
  using Strings for uint256;
  using AddressStrings for address;

  event Created(uint256 syncAmount,uint256 tokenId);
  event Matured(uint256 syncReturned,uint256 tokenId);
  event Penalized(uint256 syncOrginalAmount,uint256 reducedAmount,uint256 tokenId);

  //read only counter values
  uint256 public totalPOLYBONDS=0;                                               //Total number of Cbonds created.
  uint256 public totalPOLYBONDSCashedout=0;                                      //Total number of Cbonds that have been matured.
  uint256 public totalSYNCLocked=0;                                           //Total amount of Sync locked in Cbonds.

  //values contained in individual CBONDs, by token id
  mapping(uint256 => uint256) public syncAmountById;                          //The amount of Sync initially deposited into the given Cbond.
  mapping(uint256 => uint256) public syncInterestById;                        //The amount of Sync interest on the initially deposited Sync awarded by the given Cbond.
  mapping(uint256 => uint256) public syncRewardedOnMaturity;                  //The amount of Sync returned to the user on maturation of the given Cbond.
  mapping(uint256 => uint256) public timestampById;                           //The time the given PolyBond was created.
  mapping(uint256 => uint256) public termLengthById;                          //Length of term in seconds for the given Cbond.

  //constant and pseudo-constant (never changed after constructor) values
  uint256 constant public PERCENTAGE_PRECISION=10000;                         //Divide percentages by this to get the real multiplier.
  uint256 public STARTING_TIME=block.timestamp;                               //The time the contract was deployed.
  uint256 constant public BASE_INTEREST_RATE_START=400;                       //4%, starting value for base interest rate.
  uint256 constant public MINIMUM_BASE_INTEREST_RATE=10;                      //0.1%, the minimum value base interest rate can be.
  uint256 constant public MAXIMUM_BASE_INTEREST_RATE=2000;                    //20%, the maximum value base interest rate can be.
  uint256[] public LUCKY_EXTRAS=[100,500,1000];                               //Bonus interest awarded to user on creating lucky and extra lucky Cbonds.
  uint256 public YEAR_LENGTH=360 days;                                        //Time length of approximately 1 year
  uint256[] public TERM_DURATIONS=[90 days,180 days,360 days,720 days,1080 days];//Possible term durations for Cbonds, index values corresponding to the following variables:
  uint256 public RISK_FACTOR = 5;                                             //Constant used in duration rate calculation

  //Index variables for tracking
  uint256 public lastDaySyncSupplyUpdated=0;                                  //The previously recorded day on which the supply of Sync was last recorded into syncSupplyByDay.
  uint256 public currentDaySyncSupplyUpdated=0;                               //The day on which the supply of Sync was last recorded into syncSupplyByDay.
  mapping(address => mapping(uint256 => uint256)) public cbondsHeldByUser;    //Mapping of cbond ids held by user. The second mapping is a list, length given by cbondsHeldByUserCursor.
  mapping(address => uint256) public cbondsHeldByUserCursor;                  //The number of Cbonds held by the given user.
  mapping(uint256 => uint256) public syncSupplyByDay;                         //The recorded total supply of the Sync token for the given day. This value is written once and thereafter cannot be changed for a given day.
  mapping(uint256 => uint256) public interestRateByDay;                       //The recorded base interest rate for the given day. This value is written once and thereafter cannot be changed for a given day, and is recorded simultaneously with syncSupplyByDay.
  uint256 public _currentTokenId = 0;                                         //Variable for tracking next NFT identifier.

  //Read only tracking variables (not used within the smart contract)
  mapping(uint256 => uint256) public cbondsMaturingByDay;                     //Mapping of days to number of cbonds maturing that day.

  //admin adjustable values
  uint256 public syncMinimum = 25 * (10 ** 18);                               //Cbonds cannot be created unless at least this amount of Sync is being included in them.
  uint256 public syncMaximum = 100000 * (10 ** 18);                           //Maximum Sync in a Cbond. Cbonds with higher amounts of Sync cannot be created.
  bool public luckyEnabled = true;                                            //Whether it is possible to create Lucky Cbonds
  address syncTreasury = 0x1264EB4ad33ceF667C0fe2A84150b6a98fF4caf7;          //Set to Treasury Address

  //external contracts
  Sync syncToken;//The Sync token contract. Sync is contained in every Cbond and is minted to provide interest on Cbonds.

  constructor(Oracle o,Sync s) public Ownable() ERC721("z","CBOND"){
    syncToken=s;
    syncSupplyByDay[0]=syncToken.totalSupply();
    interestRateByDay[0]=BASE_INTEREST_RATE_START;
    _setBaseURI("api.cbondnft.com");
  }

  /*
    Admin functionsonlyOwner
  */

  /*
    Admin function to set liquidity tokens which may be used to create Cbonds.
  */
  function setTreasuryAddress(address treasury) external onlyOwner{
    syncTreasury=treasury;
  }


  /*
    Admin function to set the base URI for metadata access.
  */
  function setBaseURI(string calldata baseURI_) external onlyOwner{
    _setBaseURI(baseURI_);
  }


  /*
    Admin function to SET the minimum amount of Sync that can be used to create a Cbond.
  */
  function setSyncMinimum(uint256 newMinimum) public onlyOwner{
    syncMinimum=newMinimum;
  }

   /*
    Admin function to SET the Maximum amount of Sync that can be used to create a Cbond.
  */
  function setSyncMaximum(uint256 newMaximum) public onlyOwner{
    syncMaximum=newMaximum;
  }


  /*
    Admin function to toggle on/off the lucky bonus.
  */
  function toggleLuckyBonus(bool enabled) external onlyOwner{
    luckyEnabled=enabled;
  }

  /*
    Admin function for updating the daily Sync total supply for use in case of low activity.
  */
  function recordSync() external onlyOwner{
    recordSyncSupply();
  }

  /*
    Admin function for recovery functionality 
  */
  function withdraw() public payable onlyOwner {
    (bool os, ) = payable(syncTreasury).call{value: address(this).balance}("");
    require(os);
  }


  /*
    Return principle and mints Sync to pay back initial amount plus rewards.
  */
  function matureCBOND(uint256 tokenId) public{
    require(msg.sender==ownerOf(tokenId),"only token owner can call this");
    require(block.timestamp>termLengthById[tokenId].add(timestampById[tokenId]),"Stake term not yet complete");

    //record current SYNC supply
      recordSyncSupply();

    // Amount of SYNC provided to user is initially deposited amount plus interest
      uint256 syncRetrieved=syncRewardedOnMaturity[tokenId];

    // Amount of SYNC user initially deposited without interest
      uint256 syncOrginalAmount=syncAmountById[tokenId];

    // Return Sync tokens and Mint the interest directly to their account
      require(syncToken.transferFrom(sender,msg.sender,syncOrginalAmount),"transfer must succeed"); 
      syncToken._mint(msg.sender,syncRetrieved - syncOrginalAmount);

    // Update read only counters
      totalSYNCLocked=totalSYNCLocked.sub(syncOrginalAmount); // Reduce the amount of SYNC locked (Only the orginal amount was locked)
      totalPOLYBONDSCashedout=totalPOLYBONDSCashedout.add(1);
      emit Matured(syncRetrieved,tokenId);

    //burn the nft
      _burn(tokenId);
  }

/*
    Return principle minus a penalty.
  */
  function penaltyWithdrawal(uint256 tokenId) public{
    require(msg.sender==ownerOf(tokenId),"only token owner can call this");
    
    // Only Executable if the maturity is not met.
    if (block.timestamp>termLengthById[tokenId].add(timestampById[tokenId])) {

      //record current Sync supply
      recordSyncSupply();

      //amount of sync user initially deposited without interest
      uint256 syncOrginalAmount=syncAmountById[tokenId];

      // Multiply the amount by 0.8 to subtract 20%
      uint reducedAmount = syncOrginalAmount * 0.8;
      unit remainder = syncOrginalAmount - reducedAmount;

      // Return Tokens to user and send the Fee to Treasury
      require(syncToken.transferFrom(sender,msg.sender,reducedAmount),"transfer must succeed"); 
      require(syncToken.transferFrom(sender,syncTreasury,remainder),"transfer must succeed"); 

      //update read only counter
      totalSYNCLocked=totalSYNCLocked.sub(syncOrginalAmount); // Reduce the amount of SYNC locked
      totalPOLYBONDSCashedout=totalPOLYBONDSCashedout.add(1);
      emit Penalized(syncOrginalAmount,reducedAmount,tokenId);  

      //burn the nft
      _burn(tokenId);
    }
  }


  /*
    Public function for creating a new Cbond.
  */
  function createCBOND(uint256 amount,uint256 secondsInTerm) external returns(uint256){
    return _createCBOND(amount,secondsInTerm,msg.sender);
  }

  /*
    Function for creating a new Cbond. User specifies an amount of SYNC, this is transferred from their account to this contract (transaction reverts if this is greater than the user provided maximum at the time of execution). 
    A permitted term length is also provided.
  */
  function _createCBOND(uint256 syncAmount,uint256 secondsInTerm,address sender) private returns(uint256){

    //record current Sync supply 
    recordSyncSupply();

    // Ensure it Passes Creation Requirements
    require(syncAmount>=syncMinimum,"Stake size too small");
    require(syncAmount<=syncMaximum,"Stake size too large");

    // Recieve Tokens for Stake
    require(syncToken.transferFrom(sender,address(this),syncAmount),"transfer must succeed");

    // Get the token id for the new NFT
    uint256 tokenId=_getNextTokenId();

    // Set all NFT variables
    syncAmountById[tokenId]=syncAmount;
    timestampById[tokenId]=block.timestamp;
    termLengthById[tokenId]=secondsInTerm;

    // Set the interest rate and final maturity withdraw amount
    setInterestRate(tokenId,syncAmount,secondsInTerm);

    //update global counters
    cbondsMaturingByDay[getDay(block.timestamp.add(secondsInTerm))]=cbondsMaturingByDay[getDay(block.timestamp.add(secondsInTerm))].add(1);
    cbondsHeldByUser[sender][cbondsHeldByUserCursor[sender]]=tokenId;
    cbondsHeldByUserCursor[sender]=cbondsHeldByUserCursor[sender].add(1);
    totalPOLYBONDS=totalPOLYBONDS.add(1);
    totalSYNCLocked=totalSYNCLocked.add(syncAmount); // **NOTICE** Not sure if we need this since we should be able to see how much the Contract holds

    //Create NFT
    _safeMint(sender,tokenId);
    _incrementTokenId();

    //Fire Event
     emit Created(syncAmount,secondsInTerm,tokenId);
     return tokenId;
  }

  /*
    Creates a metadata string from a token id. Should not be used onchain.
  */
  function putTogetherMetadataString(uint256 tokenId) public view returns(string memory){
    //TODO: add the rest of the variables, separate with appropriate url variable separators for ease of use
    return string(abi.encodePacked("/?tokenId=",tokenId.toString(),"&syncAmount=",syncAmountById[tokenId].toString(),"&mPayout=",syncRewardedOnMaturity[tokenId].toString(),"&startTime=",timestampById[tokenId].toString(),"&termLength=",termLengthById[tokenId].toString()));
  }

  /**
   * @dev See {IERC721Metadata-tokenURI}.
   */
  function tokenURI(uint256 tokenId) public view override returns (string memory) {
      require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");

      //this line altered from
      //string memory _tokenURI = _tokenURIs[tokenId];
      //use of gas to manipulate strings can be avoided by putting them together at time of retrieval rather than in the token creation transaction.
      string memory _tokenURI = putTogetherMetadataString(tokenId);

      // If there is no base URI, return the token URI.
      if (bytes(baseURI()).length == 0) {
          return _tokenURI;
      }
      // If both are set, concatenate the baseURI and tokenURI (via abi.encodePacked).
      if (bytes(_tokenURI).length > 0) {
          return string(abi.encodePacked(baseURI(), _tokenURI));
      }
      // If there is a baseURI but no tokenURI, concatenate the tokenID to the baseURI.
      return string(abi.encodePacked(baseURI(), tokenId.toString()));
  }

  /*
    Increments a counter used to produce the identifier for the next token to be created.
  */
  function _incrementTokenId() private  {
    _currentTokenId=_currentTokenId.add(1);
  }

  /*
    view functions
  */

  /*
    Returns the next unused token identifier.
  */
  function _getNextTokenId() private view returns (uint256) {
    return _currentTokenId.add(1);
  }

  /*
    Convenience function to get the current block time directly from the contract.
  */
  function getTime() public view returns(uint256){
    return block.timestamp;
  }

  

  /*
    Set the sync rewarded on maturity and interest rate for the given CBOND
  */
  function setInterestRate(uint256 tokenId,uint256 syncAmount,uint256 secondsInTerm) private{
    (uint256 lastSupply,uint256 currentSupply,uint256 lastInterestRate)=getSuppliesNow();
    (uint256 interestRate,uint256 totalReturn)=getCbondTotalReturn(tokenId,syncAmount,secondsInTerm);
    syncRewardedOnMaturity[tokenId]=totalReturn;
    syncInterestById[tokenId]=interestRate;
  }

  /*
    Following two functions work immediately after all the Cbond variables except the interest rate have been set, will be inaccurate other times. To be used as part of Cbond creation.
  */

  /*
    Gets the amount of Sync for the given Cbond to return on maturity.
  */
  function getCbondTotalReturn(uint256 tokenId,uint256 syncAmount,uint256 duration) public view returns(uint256 interestRate,uint256 totalReturn){
    // This is an integer math translation of P*(1+I) where P is principle I is interest rate. The new, equivalent formula is P*(c+I*c)/c where c is a constant of amount PERCENTAGE_PRECISION.

    interestRate=getCbondInterestRateNow(duration,getLuckyExtra(tokenId));
    totalReturn = syncAmount.mul(PERCENTAGE_PRECISION.add(interestRate)).div(PERCENTAGE_PRECISION);
  }

  /*
    Gets the interest rate for a Cbond given its relevant properties.
  */
  function getCbondInterestRateNow(
    uint256 duration,
    uint256 luckyExtra) public view returns(uint256){
      return getCbondInterestRate(
        duration,
        syncSupplyByDay[lastDaySyncSupplyUpdated],
        syncSupplyByDay[getDay(block.timestamp)],
        interestRateByDay[lastDaySyncSupplyUpdated],
        luckyExtra);
  }

  /*
    This returns the Cbond interest rate. Divide by PERCENTAGE_PRECISION to get the real rate.
  */
  function getCbondInterestRate(
    uint256 duration,
    uint256 syncTotalLast,
    uint256 syncTotalCurrent,
    uint256 lastBaseInterestRate,
    uint256 luckyExtra) public view returns(uint256){

    uint256 baseInterestRate=getBaseInterestRate(lastBaseInterestRate,syncTotalCurrent,syncTotalLast);
    return getDurationRate(duration,baseInterestRate.add(luckyExtra));
    
  }

  /*
    This returns the Lucky Extra bonus of the given Cbond. This is based on whether the id of the Cbond ends in two or three 7's, and whether admins have disabled this feature.
  */
  function getLuckyExtra(uint256 tokenId) public view returns(uint256){
    if(luckyEnabled){
     if(tokenId.mod(1000)==777){
        return LUCKY_EXTRAS[2];
      }
      if(tokenId.mod(100)==77){
        return LUCKY_EXTRAS[1];
      }
      if(tokenId.mod(10)==7){
        return LUCKY_EXTRAS[0];
      }
    }
    return 0;
  }

  /*
    New V2 implementation of duration modifier. Approximation of intended formula.
  */
  function getDurationRate(uint duration, uint baseInterestRate) public view returns(uint){
        // require(duration==TERM_DURATIONS[0] || duration==TERM_DURATIONS[1] || duration==TERM_DURATIONS[2] || duration==TERM_DURATIONS[3] || duration==TERM_DURATIONS[4],"Invalid term length provided");
        require(duration > 90 days && duration < 1080 days,"Invalid term length provided");
    
    // 90 Day to 180 days
        if(duration < 180 days){ 
          return baseInterestRate;
        }
    

    // incremental instead of "Buckets"
        if(duration > 179 days){
            uint factor = ((duration - 90 days).mul(11 - 3).div(1080 days - 90 days).add(3)); // Untested but I think this will get a value for Risk Factor on a scale from 3 to 11 - calculated in seconds - maybe needs rounded to int?
            uint preExponential = PERCENTAGE_PRECISION.add(baseInterestRate).add(RISK_FACTOR.mul(factor));
            uint exponential = preExponential.mul(preExponential).div(PERCENTAGE_PRECISION);
            for (uint8 i=0;i < factor - 1;i++) {
                exponential = exponential.mul(preExponential).div(PERCENTAGE_PRECISION);
            }
            return exponential.sub(PERCENTAGE_PRECISION);
        }



    // // 6 Month (180 days)
    //     if(duration==TERM_DURATIONS[1]){
    //         uint preExponential = PERCENTAGE_PRECISION.add(baseInterestRate).add(RISK_FACTOR);
    //         uint exponential = preExponential.mul(preExponential).div(PERCENTAGE_PRECISION);
    //         return exponential.sub(PERCENTAGE_PRECISION);
    //     }
    
    // // 1 year
    //     if(duration==TERM_DURATIONS[2]){
    //         uint preExponential = PERCENTAGE_PRECISION.add(baseInterestRate).add(RISK_FACTOR.mul(3));
    //         uint exponential = preExponential.mul(preExponential).div(PERCENTAGE_PRECISION);
    //         for (uint8 i=0;i<2;i++) {
    //             exponential = exponential.mul(preExponential).div(PERCENTAGE_PRECISION);
    //         }
    //         return exponential.sub(PERCENTAGE_PRECISION);
    //     }
    
    // // 2 year
    //     if(duration==TERM_DURATIONS[3]){
    //         uint preExponential = PERCENTAGE_PRECISION.add(baseInterestRate).add(RISK_FACTOR.mul(7));
    //         uint exponential = preExponential.mul(preExponential).div(PERCENTAGE_PRECISION);
    //         for (uint8 i=0;i<6;i++) {
    //             exponential = exponential.mul(preExponential).div(PERCENTAGE_PRECISION);
    //         }
    //         return exponential.sub(PERCENTAGE_PRECISION);
    //     }
    
    // // 3 year
    //     if(duration==TERM_DURATIONS[4]){
    //         uint preExponential = PERCENTAGE_PRECISION.add(baseInterestRate).add(RISK_FACTOR.mul(11));
    //         uint exponential = preExponential.mul(preExponential).div(PERCENTAGE_PRECISION);
    //         for (uint8 i=0;i<10;i++) {
    //             exponential = exponential.mul(preExponential).div(PERCENTAGE_PRECISION);
    //         }
    //         return exponential.sub(PERCENTAGE_PRECISION);
    //     }
    }

  

  /*
    Returns the base interest rate, derived from the previous day interest rate, the current Sync total supply, and the previous day Sync total supply.
  */
  function getBaseInterestRate(uint256 lastdayInterestRate,uint256 syncSupplyToday,uint256 syncSupplyLast) public pure returns(uint256){
    return Math.min(MAXIMUM_BASE_INTEREST_RATE,Math.max(MINIMUM_BASE_INTEREST_RATE,lastdayInterestRate.mul(syncSupplyToday).div(syncSupplyLast)));
    syncToken.totalSupply().sub(totalSYNCLocked);
  }

  /*
    Returns the interest rate a Cbond with the given parameters would end up with if it were created.
  */
  function getCbondInterestRateIfUpdated(uint256 duration,uint256 luckyExtra) public view returns(uint256){
    (uint256 lastSupply,uint256 currentSupply,uint256 lastInterestRate)=getSuppliesIfUpdated();
    return getCbondInterestRate(duration,lastSupply,currentSupply,lastInterestRate,luckyExtra);
  }

  /*
    Convenience function for frontend use which returns current and previous recorded Sync total supply, and tokens held for the provided token.
  */
  function getSuppliesNow() public view returns(uint256 lastSupply,uint256 currentSupply,uint256 lastInterestRate){
    currentSupply=syncSupplyByDay[currentDaySyncSupplyUpdated];
    lastSupply=syncSupplyByDay[lastDaySyncSupplyUpdated];
    lastInterestRate=interestRateByDay[lastDaySyncSupplyUpdated];
  }

  /*
    Gets what the Sync token current and last supplies would become, if updated now. Intended for frontend use.
  */
  function getSuppliesIfUpdated() public view returns(uint256 lastSupply,uint256 currentSupply,uint256 lastInterestRate){
    uint256 day=getDay(block.timestamp);
    if(syncSupplyByDay[day]==0){
      currentSupply=syncToken.totalSupply().sub(totalSYNCLocked); //Now Subtracts Locked SYNC from the Total Supply since we no longer burn SYNC
      lastSupply=syncSupplyByDay[currentDaySyncSupplyUpdated];
      //TODO: interest rate
      lastInterestRate=interestRateByDay[currentDaySyncSupplyUpdated];
    }
    else{
      currentSupply=syncSupplyByDay[currentDaySyncSupplyUpdated];
      lastSupply=syncSupplyByDay[lastDaySyncSupplyUpdated];
      lastInterestRate=interestRateByDay[lastDaySyncSupplyUpdated];
    }
  }

  /*
    Function for recording the Sync total supply and base interest rate by day. Records only at the first time it is called in a given day (see getDay).
  */
  function recordSyncSupply() public{
    if(syncSupplyByDay[getDay(block.timestamp)]==0){
      uint256 day=getDay(block.timestamp);
      syncSupplyByDay[day]=syncToken.totalSupply().sub(totalSYNCLocked);  //Now Subtracts Locked SYNC from the Total Supply since we no longer burn SYNC
      lastDaySyncSupplyUpdated=currentDaySyncSupplyUpdated;
      currentDaySyncSupplyUpdated=day;

      //interest rate
      interestRateByDay[day]=getBaseInterestRate(interestRateByDay[lastDaySyncSupplyUpdated],syncSupplyByDay[day],syncSupplyByDay[lastDaySyncSupplyUpdated]);
    }
  }



  /*
    Gets the current day since the contract began. Starts at 1.
  */
  function getDay(uint256 timestamp) public view returns(uint256){
    return timestamp.sub(STARTING_TIME).div(24 hours).add(1);
  }

  /*
    Gets the current day since the contract began, at the current block time.
  */
  function getDayNow() public view returns(uint256){
    return getDay(block.timestamp);
  }
}
