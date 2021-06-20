# @version 0.2.12


from vyper.interfaces import ERC20

interface Voting:
    def getVote(vote_id: uint256) -> VoteData: view
    def getVoterState(vote_id: uint256, voter: address) -> uint256: view

interface VeCRV:
    def balanceOfAt(owner: address, block_number: uint256) -> uint256: view


struct VoteData:
    is_open: bool
    is_executed: bool
    start_date: uint256
    snapshot_block: uint256
    support_required: uint256
    min_accept_quorum: uint256
    yea: uint256
    nay: uint256
    voting_power: uint256


VOTING: constant(address) = 0xE478de485ad2fe566d49342Cbd03E49ed7DB3356
VECRV: constant(address) = 0x5f3b5DfEb7B28CDbD7FAba78963EE202a494e2A2

reward_token: public(address)
reward_amount: public(uint256)

vote_id: public(uint256)
desired_vote: public(uint256)  # 1 = yes, 2 = no
snapshot_block: public(uint256)
vote_state: public(uint256)  # 0 = open, 1 = successful, 2 = failed
eligible_vecrv: public(uint256)

has_claimed: public(HashMap[address, bool])
given_rewards: public(HashMap[address, uint256])


@external
def __init__(_vote_id: uint256, _desired_vote: uint256, _reward_token: address):
    """
    @notice Contract constructor
    @dev Vote must be active to deploy the contract
    @param _vote_id ID of the vote to apply a reward to
    @param _desired_vote Vote outcome to incentivize. 1 for passing, 2 for failing.
    @param _reward_token Reward token address
    """
    vote: VoteData = Voting(VOTING).getVote(_vote_id)
    assert vote.is_open
    assert _desired_vote in [1, 2]

    self.vote_id = _vote_id
    self.desired_vote = _desired_vote
    self.snapshot_block = vote.snapshot_block
    self.reward_token = _reward_token


@internal
def _update_vote_state():
    vote: VoteData = Voting(VOTING).getVote(self.vote_id)
    assert not vote.is_open, "Vote is still open"

    total_vecrv: uint256 = vote.yea + vote.nay
    has_quorum: bool = total_vecrv * 10**18 / vote.voting_power > vote.min_accept_quorum
    has_support: bool = vote.yea * 10**18 / total_vecrv > vote.support_required

    if self.desired_vote == 1:
        if has_quorum and has_support:
            self.vote_state = 1
            self.eligible_vecrv = vote.yea
        else:
            self.vote_state = 2
    else:
        if has_quorum and has_support:
            self.vote_state = 2
        else:
            self.vote_state = 1
            self.eligible_vecrv = vote.nay


@external
def add_reward_amount(_amount: uint256) -> bool:
    """
    @notice Increase the amount of available rewards
    @dev Only callable while the voting is still active
    @param _amount Amount of the reward token to transfer from the caller
    @return Success bool
    """
    assert self.vote_state == 0, "Vote is not open"

    assert ERC20(self.reward_token).transferFrom(msg.sender, self, _amount)
    self.reward_amount += _amount
    self.given_rewards[msg.sender] += _amount

    return True


@external
def withdraw_reward(_claimant: address = msg.sender) -> bool:
    """
    @notice Withdraw an offered reward
    @dev Only callable if the vote has finished with an undesired outcome
    @param _claimant Address to withdraw for
    @return Success bool
    """
    if self.vote_state == 0:
        self._update_vote_state()

    assert self.vote_state == 2, "Favorable vote outcome"

    amount: uint256 = self.given_rewards[_claimant]
    self.given_rewards[_claimant] = 0
    self.reward_amount -= amount
    assert ERC20(self.reward_token).transfer(_claimant, amount)

    return True


@external
def claim_reward(_claimant: address = msg.sender) -> bool:
    """
    @notice Claim an available reward
    @dev Only callable if the claimant voted correctly
         and the vote ended with the desired outcome
    @param _claimant Address to claim for
    @return Success bool
    """
    if self.vote_state == 0:
        self._update_vote_state()

    assert self.vote_state == 1, "Unfavorable vote outcome"
    assert not self.has_claimed[_claimant], "Already claimed"
    assert Voting(VOTING).getVoterState(self.vote_id, _claimant) == self.desired_vote, "Did not vote correctly"
    self.has_claimed[_claimant] = True

    vecrv: uint256 = VeCRV(VECRV).balanceOfAt(_claimant, self.snapshot_block)
    amount: uint256 = self.reward_amount * vecrv / self.eligible_vecrv
    assert ERC20(self.reward_token).transfer(_claimant, amount)

    return True
