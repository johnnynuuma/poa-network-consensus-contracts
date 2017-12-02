pragma solidity ^0.4.18;
import "zeppelin-solidity/contracts/math/SafeMath.sol";
import "./KeysManager.sol";
import "./BallotsStorage.sol";

contract VotingContract { 
    using SafeMath for uint256;
    enum BallotTypes {Invalid, Adding, Removal, Swap, ChangeMinThreshold}
    enum KeyTypes {Invalid, MiningKey, VotingKey, PayoutKey}
    enum QuorumStates {Invalid, InProgress, Accepted, Rejected}
    enum ActionChoice { Invalid, Accept, Reject }
    
    BallotsStorage public ballotsStorage;
    KeysManager public keysManager;
    uint8 public maxOldMiningKeysDeepCheck = 25;
    uint256 public nextBallotId;
    uint256[] public activeBallots;
    uint256 public activeBallotsLength;
    struct VotingData {
        uint256 startTime;
        uint256 endTime;
        address affectedKey;
        uint256 affectedKeyType;
        address miningKey;
        uint256 totalVoters;
        int progress;
        bool isFinalized;
        uint8 quorumState;
        uint256 ballotType;
        uint256 index;
        uint256 minThresholdOfVoters;
        mapping(address => bool) voters;
    }
    mapping(uint256 => VotingData) public votingState;

    event Vote(uint256 indexed decision, address indexed voter, uint256 time );
    event BallotFinalized(uint256 indexed id, address indexed voter);
    event BallotCreated(uint256 indexed id, uint256 indexed ballotType, address indexed creator);

    modifier onlyValidVotingKey(address _votingKey) {
        require(keysManager.isVotingActive(_votingKey));
        _;
    }

    function VotingContract(address _keysContract, address _ballotsStorage) public {
        keysManager = KeysManager(_keysContract);
        ballotsStorage = BallotsStorage(_ballotsStorage);
    }

    function createVotingForKeys(
        uint256 _startTime,
        uint256 _endTime,
        address _affectedKey, 
        uint256 _affectedKeyType, 
        address _miningKey,
        uint256 _ballotType
    ) public onlyValidVotingKey(msg.sender) {
        require(_startTime > 0 && _endTime > 0);
        require(_endTime > _startTime && _startTime > getTime());
        require(AreBallotParamsValid(_ballotType, _affectedKey, _affectedKeyType, _miningKey)); //only if ballotType is swap or remove
        VotingData memory data = VotingData({
            startTime: _startTime,
            endTime: _endTime,
            affectedKey: _affectedKey,
            affectedKeyType: _affectedKeyType,
            miningKey: _miningKey,
            totalVoters: 0,
            progress: 0,
            isFinalized: false,
            quorumState: uint8(QuorumStates.InProgress),
            ballotType: _ballotType,
            index: activeBallots.length,
            minThresholdOfVoters: getGlobalMinThresholdOfVoters()
        });
        votingState[nextBallotId] = data;
        activeBallots.push(nextBallotId);
        activeBallotsLength = activeBallots.length;
        BallotCreated(nextBallotId, _ballotType, msg.sender);
        nextBallotId++;
    }

    function vote(uint256 _id, uint8 _choice) public onlyValidVotingKey(msg.sender) {
        VotingData storage ballot = votingState[_id];
        // // check for validation;
        address miningKey = getMiningByVotingKey(msg.sender);
        require(isValidVote(_id, msg.sender));
        if(_choice == uint(ActionChoice.Accept)) {
            ballot.progress++;
        } else if(_choice == uint(ActionChoice.Reject)) {
            ballot.progress--;
        } else {
            revert();
        }
        ballot.totalVoters++;
        ballot.voters[miningKey] = true;
        Vote(_choice, msg.sender, getTime());
    }

    function finalize(uint256 _id) public onlyValidVotingKey(msg.sender) {
        require(!isActive(_id));
        VotingData storage ballot = votingState[_id];
        finalizeBallot(_id);
        ballot.isFinalized = true;
        BallotFinalized(_id, msg.sender);
    }

    function getGlobalMinThresholdOfVoters() public view returns(uint256) {
        return ballotsStorage.minThresholdOfVoters();
    }

    function getProgress(uint256 _id) public view returns(int) {
        return votingState[_id].progress;
    }

    function getTotalVoters(uint256 _id) public view returns(uint256) {
        return votingState[_id].totalVoters;
    }

    function getMinThresholdOfVoters(uint256 _id) public view returns(uint256) {
        return votingState[_id].minThresholdOfVoters;
    }

    function getAffectedKeyType(uint256 _id) public view returns(uint256) {
        return votingState[_id].affectedKeyType;
    }

    function getAffectedKey(uint256 _id) public view returns(address) {
        return votingState[_id].affectedKey;
    }

    function getMiningKey(uint256 _id) public view returns(address) {
        return votingState[_id].miningKey;
    }

    function getMiningByVotingKey(address _votingKey) public view returns(address) {
        return keysManager.getMiningKeyByVoting(_votingKey);
    }

    function getBallotType(uint256 _id) public view returns(uint256) {
        return votingState[_id].ballotType;
    }

    function getStartTime(uint256 _id) public view returns(uint256) {
        return votingState[_id].startTime;
    }

    function getEndTime(uint256 _id) public view returns(uint256) {
        return votingState[_id].endTime;
    }

    function getIsFinalized(uint256 _id) public view returns(bool) {
        return votingState[_id].isFinalized;
    }

    function getTime() public view returns(uint256) {
        return now;
    }

    function isActive(uint256 _id) public view returns(bool) {
        bool withinTime = getStartTime(_id) <= getTime() && getTime() <= getEndTime(_id);
        return withinTime && !getIsFinalized(_id);
    }

    function hasAlreadyVoted(uint256 _id, address _votingKey) public view returns(bool) {
        VotingData storage ballot = votingState[_id];
        address miningKey = getMiningByVotingKey(_votingKey);
        return ballot.voters[miningKey];
    }
    function isValidVote(uint256 _id, address _votingKey) public view returns(bool) {
        address miningKey = getMiningByVotingKey(_votingKey);
        bool notVoted = !hasAlreadyVoted(_id, _votingKey);
        bool oldKeysNotVoted = !areOldMiningKeysVoted(_id, miningKey);
        return notVoted && isActive(_id) && oldKeysNotVoted;
    }

    function areOldMiningKeysVoted(uint256 _id, address _miningKey) public view returns(bool) {
        VotingData storage ballot = votingState[_id];
        for (uint8 i = 0; i < maxOldMiningKeysDeepCheck; i++) {
            address oldMiningKey = keysManager.miningKeyHistory(_miningKey);
            if (oldMiningKey == address(0)) {
                return false;
            }
            if (ballot.voters[oldMiningKey]) {
                return true;
            } else {
                _miningKey = oldMiningKey;
            }
        }
        return false;
    }

    function AreBallotParamsValid(uint256 _ballotType, address _affectedKey, uint256 _affectedKeyType, address _miningKey) public view returns(bool) {
        require(_affectedKeyType > 0);
        require(_affectedKey != address(0));
        require(activeBallotsLength <= 100);
        bool isMiningActive = keysManager.isMiningActive(_miningKey);
        if (_affectedKeyType == uint256(KeyTypes.MiningKey)) {
            if (_ballotType == uint256(BallotTypes.Removal)) {
                return isMiningActive;
            }
            if (_ballotType == uint256(BallotTypes.Adding)) {
                return true;
            }
        }
        require(_affectedKey != _miningKey);
        if (_ballotType == uint256(BallotTypes.Removal) || _ballotType == uint256(BallotTypes.Swap)) {
            if (_affectedKeyType == uint256(KeyTypes.MiningKey)) {
                return isMiningActive;
            }
            if (_affectedKeyType == uint256(KeyTypes.VotingKey)) {
                address votingKey = keysManager.getVotingByMining(_miningKey);
                return keysManager.isVotingActive(votingKey) && _affectedKey == votingKey && isMiningActive;
            }
            if (_affectedKeyType == uint256(KeyTypes.PayoutKey)) {
                address payoutKey = keysManager.getPayoutByMining(_miningKey);
                return keysManager.isPayoutActive(_miningKey) && _affectedKey == payoutKey && isMiningActive;
            }       
        }
        return true;
    }

    function finalizeBallot(uint256 _id) private {
        if (getProgress(_id) > 0 && getTotalVoters(_id) >= getMinThresholdOfVoters(_id)) {
            updateBallot(_id, uint8(QuorumStates.Accepted));
            if (getBallotType(_id) == uint256(BallotTypes.Adding)) {
                finalizeAdding(_id);
            } else if (getBallotType(_id) == uint256(BallotTypes.Removal)) {
                finalizeRemoval(_id);
            } else if (getBallotType(_id) == uint256(BallotTypes.Swap)) {
                finalizeSwap(_id);
            }
        } else {
            updateBallot(_id, uint8(QuorumStates.Rejected));
        }
        deactiveBallot(_id);
    }

    function updateBallot(uint256 _id, uint8 _quorumState) private {
        VotingData storage ballot = votingState[_id];
        ballot.quorumState = _quorumState;
    }

    function deactiveBallot(uint256 _id) private {
        VotingData memory ballot = votingState[_id];
        delete activeBallots[ballot.index];
        if (activeBallots.length > 0) {
            activeBallots.length--;
        }
        activeBallotsLength = activeBallots.length;
    }


    function finalizeAdding(uint256 _id) private {
        require(getBallotType(_id) == uint256(BallotTypes.Adding));
        if (getAffectedKeyType(_id) == uint256(KeyTypes.MiningKey)) {
            keysManager.addMiningKey(getAffectedKey(_id));
        }
        if (getAffectedKeyType(_id) == uint256(KeyTypes.VotingKey)) {
            keysManager.addVotingKey(getAffectedKey(_id), getMiningKey(_id));
        }
        if (getAffectedKeyType(_id) == uint256(KeyTypes.PayoutKey)) {
            keysManager.addPayoutKey(getAffectedKey(_id), getMiningKey(_id));
        }
    }

    function finalizeRemoval(uint256 _id) private {
        require(getBallotType(_id) == uint256(BallotTypes.Removal));
        if (getAffectedKeyType(_id) == uint256(KeyTypes.MiningKey)) {
            keysManager.removeMiningKey(getAffectedKey(_id));
        }
        if (getAffectedKeyType(_id) == uint256(KeyTypes.VotingKey)) {
            keysManager.removeVotingKey(getMiningKey(_id));
        }
        if (getAffectedKeyType(_id) == uint256(KeyTypes.PayoutKey)) {
            keysManager.removePayoutKey(getMiningKey(_id));
        }
    }

    function finalizeSwap(uint256 _id) private {
        require(getBallotType(_id) == uint256(BallotTypes.Swap));
        if (getAffectedKeyType(_id) == uint256(KeyTypes.MiningKey)) {
            keysManager.swapMiningKey(getAffectedKey(_id), getMiningKey(_id));
        }
        if (getAffectedKeyType(_id) == uint256(KeyTypes.VotingKey)) {
            keysManager.swapVotingKey(getAffectedKey(_id), getMiningKey(_id));
        }
        if (getAffectedKeyType(_id) == uint256(KeyTypes.PayoutKey)) {
            keysManager.swapPayoutKey(getAffectedKey(_id), getMiningKey(_id));
        }
    }
}
