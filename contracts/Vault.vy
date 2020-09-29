#@version 0.2.4

# TODO: Add ETH Configuration
# TODO: Add Delegated Configuration
from vyper.interfaces import ERC20

implements: ERC20

interface DetailedERC20:
    def name() -> String[42]: view
    def symbol() -> String[20]: view
    def decimals() -> uint256: view

event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256


name: public(String[64])
symbol: public(String[32])
decimals: public(uint256)

balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])
totalSupply: public(uint256)

token: public(ERC20)
governance: public(address)
guardian: public(address)
pendingGovernance: address

struct StrategyParams:
    active: bool
    activation: uint256  # Activation block.number
    debtLimit: uint256  # Maximum borrow amount
    rateLimit: uint256  # Increase/decrease per block
    lastSync: uint256  # block.number of the last time a sync occured
    totalDebt: uint256
    totalReturns: uint256

event StrategyUpdate:
    strategy: indexed(address)
    returnAdded: uint256
    debtAdded: uint256
    totalReturn: uint256
    totalDebt: uint256
    debtLimit: uint256

# NOTE: Track the total for overhead targeting purposes
strategies: public(HashMap[address, StrategyParams])

emergencyShutdown: public(bool)

debtLimit: public(uint256)  # Debt limit for the Vault across all strategies
debtChangeLimit: public(decimal)  # Amount strategy debt limit can change based on return profile
totalDebt: public(uint256)  # Amount of tokens that all strategies have borrowed

rewards: public(address)
performanceFee: public(uint256)
PERFORMANCE_FEE_MAX: constant(uint256) = 10000

@external
def __init__(_token: address, _governance: address, _rewards: address):
    # TODO: Non-detailed Configuration?
    self.token = ERC20(_token)
    self.name = concat("yearn ", DetailedERC20(_token).name())
    self.symbol = concat("y", DetailedERC20(_token).symbol())
    self.decimals = DetailedERC20(_token).decimals()
    self.governance = _governance
    self.rewards = _rewards
    self.guardian = msg.sender
    self.performanceFee = 500  # 5%
    self.debtLimit = ERC20(_token).totalSupply() / 1000  # 0.1% of total supply of token
    self.debtChangeLimit =  0.005  # up to +/- 0.5% change allowed for strategy debt limits


# 2-phase commit for a change in governance
@external
def setGovernance(_governance: address):
    assert msg.sender == self.governance
    self.pendingGovernance = _governance


@external
def acceptGovernance():
    assert msg.sender == self.pendingGovernance
    self.governance = msg.sender


@external
def setRewards(_rewards: address):
    assert msg.sender == self.governance
    self.rewards = _rewards


@external
def setDebtLimit(_limit: uint256):
    assert msg.sender == self.governance
    self.debtLimit = _limit


@external
def setDebtChangeLimit(_limit: decimal):
    assert msg.sender == self.governance
    self.debtChangeLimit = _limit


@external
def setPerformanceFee(_fee: uint256):
    assert msg.sender == self.governance
    self.performanceFee = _fee


@external
def setGuardian(_guardian: address):
    assert msg.sender in [self.guardian, self.governance]
    self.guardian = _guardian


@external
def setEmergencyShutdown(_active: bool):
    """
    Activates Vault mode where all Strategies go into full withdrawal
    """
    assert msg.sender in [self.guardian, self.governance]
    self.emergencyShutdown = _active


@external
def transfer(_to : address, _value : uint256) -> bool:
    self.balanceOf[msg.sender] -= _value
    self.balanceOf[_to] += _value
    log Transfer(msg.sender, _to, _value)
    return True


@external
def transferFrom(_from : address, _to : address, _value : uint256) -> bool:
    self.balanceOf[_from] -= _value
    self.balanceOf[_to] += _value
    if self.allowance[_from][msg.sender] < MAX_UINT256:  # Unlimited approval (saves an SSTORE)
       self.allowance[_from][msg.sender] -= _value
    log Transfer(_from, _to, _value)
    return True


@external
def approve(_spender : address, _value : uint256) -> bool:
    self.allowance[msg.sender][_spender] = _value
    log Approval(msg.sender, _spender, _value)
    return True


@internal
def _issueSharesForAmount(_to: address, _amount: uint256):
    shares: uint256 = 0
    if self.totalSupply > 0:
        # Mint amount of shares based on what the Vault is managing overall
        totalAssets: uint256 = self.token.balanceOf(self) + self.totalDebt
        shares = (_amount / totalAssets) * self.totalSupply
    else:
        # No existing shares, so mint 1:1
        shares = _amount

    # Mint new shares
    self.totalSupply += shares
    self.balanceOf[_to] += shares
    log Transfer(ZERO_ADDRESS, _to, shares)


@external
def deposit(_amount: uint256):
    # Get new collateral
    reserve: uint256 = self.token.balanceOf(self)
    self.token.transferFrom(msg.sender, self, _amount)
    # TODO: `Deflationary` configuration only
    assert self.token.balanceOf(self) - reserve == _amount  # Deflationary token check
    self._issueSharesForAmount(msg.sender, _amount)


@view
@internal
def _shareValue(_shares: uint256) -> uint256:
    return (_shares * (self.token.balanceOf(self) + self.totalDebt)) / self.totalSupply


@external
def withdraw(_maxShares: uint256):
    # Take the lesser of the amount _maxShares is worth, or the amount in the "free" pool
    value: uint256 = min(self._shareValue(_maxShares), self.token.balanceOf(self))
    # Calculate how many shares correspond to that value
    shares: uint256 = value * self.totalSupply / (self.token.balanceOf(self) + self.totalDebt)
    assert value == self._shareValue(shares)  # Sanity check (TODO: Validate unnecessary)

    # Burn shares
    self.totalSupply -= shares
    self.balanceOf[msg.sender] -= shares
    log Transfer(msg.sender, ZERO_ADDRESS, shares)

    # Withdraw balance
    self.token.transfer(msg.sender, value)


@view
@external
def pricePerShare() -> uint256:
    return self._shareValue(10 ** self.decimals)


@external
def addStrategy(
    _strategy: address,
    _seedCapital: uint256,
    _debtLimit: uint256,
    _rateLimit: uint256,
):
    assert msg.sender == self.governance
    assert self.totalDebt + _seedCapital <= self.debtLimit
    self.strategies[_strategy] = StrategyParams({
        active: True,
        activation: block.number,
        debtLimit: _debtLimit,
        rateLimit: _rateLimit,
        lastSync: block.number,
        totalDebt: _seedCapital,
        totalReturns: 0,
    })
    self.totalDebt += _seedCapital
    self.token.transfer(_strategy, _seedCapital)

    log StrategyUpdate(_strategy, 0, _seedCapital, 0, _seedCapital, _debtLimit)


@external
def updateStrategy(_strategy: address, _debtLimit: uint256, _rateLimit: uint256):
    assert msg.sender == self.governance
    self.strategies[_strategy].debtLimit = _debtLimit
    self.strategies[_strategy].rateLimit = _rateLimit


@external
def migrateStrategy(_newVersion: address):
    """
    Only a strategy can migrate itself to a new version
    NOTE: Strategy must successfully migrate all capital and positions to
          new Strategy, or else this will upset the balance of the Vault
    """
    assert self.strategies[msg.sender].active
    assert not self.strategies[_newVersion].active
    strategy: StrategyParams = self.strategies[msg.sender]
    self.strategies[msg.sender] = empty(StrategyParams)
    self.strategies[_newVersion] = strategy
    # TODO: Ensure a smooth transition in terms of  strategy return


@external
def revokeStrategy(_strategy: address = msg.sender):
    """
    Governance can revoke a strategy
    OR
    A strategy can revoke itself (Emergency Exit Mode)
    """
    assert msg.sender in [_strategy, self.governance]
    self.strategies[_strategy].debtLimit = 0


@view
@internal
def _creditAvailable(_strategy: address) -> uint256:
    """
    Amount of tokens in vault a strategy has access to as a credit line
    """
    if self.emergencyShutdown:
        return 0

    params: StrategyParams = self.strategies[_strategy]

    # Exhausted credit line
    if params.debtLimit <= params.totalDebt or self.debtLimit <= self.totalDebt:
        return 0

    # Start with debt limit left for the strategy
    available: uint256 = params.debtLimit - params.totalDebt

    # Adjust by the global debt limit left
    available = min(available, self.debtLimit - self.totalDebt)

    # Adjust by the rate limit algorithm (limits the step size per sync)
    available = min(available, params.rateLimit * (block.number - params.lastSync))

    # Can only borrow up to what the contract has in reserve
    # NOTE: Running near 100% is discouraged
    return min(available, self.token.balanceOf(self))


@view
@external
def creditAvailable(_strategy: address = msg.sender) -> uint256:
    return self._creditAvailable(_strategy)


@view
@internal
def _expectedReturn(_strategy: address) -> uint256:
    params: StrategyParams = self.strategies[_strategy]
    blockDelta: uint256 = (block.number - params.lastSync)
    if blockDelta > 0:
        return (params.totalReturns * blockDelta) / (block.number - params.activation)
    else:
        return 0  # Covers the scenario when block.number == params.activation


@view
@external
def expectedReturn(_strategy: address = msg.sender) -> uint256:
    return self._expectedReturn(_strategy)


@external
def sync(_return: uint256):
    """
    Strategies call this.
    _return: amount Strategy has made since last sync, and is given back to Vault
    """
    # NOTE: For approved strategies, this is the most efficient behavior.
    #       Strategy reports back what it has free (usually in terms of ROI)
    #       and then Vault "decides" here whether to take some back or give it more.
    #       Note that the most it can take is `_return`, and the most it can give is
    #       all of the remaining reserves. Anything outside of those bounds is abnormal
    #       behavior.
    # NOTE: All approved strategies must have increased diligience around
    #       calling this function, as abnormal behavior could become catastrophic

    # Only approved strategies can call this function
    assert self.strategies[msg.sender].active

    # Issue new shares to cover fee (if strategy is not shutting down)
    # NOTE: In effect, this reduces overall share price by performanceFee
    # NOTE: No fee is taken when a strategy is unwinding it's position
    if self.strategies[msg.sender].debtLimit > 0:
        fee: uint256 = (_return * self.performanceFee) / PERFORMANCE_FEE_MAX
        self._issueSharesForAmount(self.rewards, fee)

    # Update borrow based on delta between credit available and reported earnings
    # NOTE: This is just used to adjust the balance of tokens based on debtLimit
    credit: uint256 = self._creditAvailable(msg.sender)
    if _return < credit:  # credit surplus, give to strategy
        diff: uint256 = credit - _return
        self.token.transfer(msg.sender, diff)
        self.strategies[msg.sender].totalDebt += diff
        self.totalDebt += diff
    elif _return > credit:  # credit deficit, take from strategy
        diff: uint256 = _return - credit  # Take the difference
        self.token.transferFrom(msg.sender, self, diff)
        # NOTE: Cannot return more than you borrowed (after adjusting for returns)
        self.strategies[msg.sender].totalDebt -= diff
        self.totalDebt -= diff
    # else if matching, don't do anything because it is performing well as is

    # Adjust future debt limit based on current return vs. past performance
    expected_return: uint256 = self._expectedReturn(msg.sender)
    debtMultiplier: decimal = convert(_return, decimal) / convert(expected_return, decimal)
    newDebtLimit: decimal = convert(self.strategies[msg.sender].debtLimit, decimal)
    newDebtLimit *= max(min(1.0 + self.debtChangeLimit, debtMultiplier), 1.0 - self.debtChangeLimit)
    self.strategies[msg.sender].debtLimit = convert(newDebtLimit, uint256)

    # Returns are always "realized gains"
    self.strategies[msg.sender].totalReturns += _return
    # Update sync time
    self.strategies[msg.sender].lastSync = block.number

    log StrategyUpdate(
        msg.sender,
        _return,
        credit,
        self.strategies[msg.sender].totalReturns,
        self.strategies[msg.sender].totalDebt,
        self.strategies[msg.sender].debtLimit,
    )
