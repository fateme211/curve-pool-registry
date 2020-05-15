# @version 0.1.0

from vyper.interfaces import ERC20

MAX_COINS: constant(int128) = 7

struct AddressArray:
    length: int128
    addresses: address[65536]

struct PoolArray:
    location: int128
    decimals: bytes32
    coins: address[MAX_COINS]
    underlying_coins: address[MAX_COINS]
    calldata: bytes[72]

contract CurvePool:
    def A() -> uint256: constant
    def fee() -> uint256: constant
    def coins(i: int128) -> address: constant
    def underlying_coins(i: int128) -> address: constant
    def get_dy(i: int128, j: int128, dx: uint256) -> uint256: constant
    def get_dy_underlying(i: int128, j: int128, dx: uint256) -> uint256: constant
    def exchange(i: int128, j: int128, dx: uint256, min_dy: uint256): modifying
    def exchange_underlying(i: int128, j: int128, dx: uint256, min_dy: uint256): modifying


admin: address

pool_list: public(address[65536])  # master list of pools
pool_count: public(int128)  # actual length of pool_list

pool_data: map(address, PoolArray)  # data for specific pools
markets: map(address, AddressArray)  # list of pools where a token is tradeable
underlying_markets: map(address, AddressArray)  # list of pools where a token is tradeable


@public
def __init__():
    self.admin = msg.sender


@private
def _add_pool_to_market(_coin: address, _pool: address):
    _length: int128 = self.markets[_coin].length
    self.markets[_coin].addresses[_length] = _pool
    self.markets[_coin].length = _length + 1


@public
def add_pool(
    _pool: address,
    _n_coins: int128,
    _decimals: uint256[MAX_COINS],
    _calldata: bytes[72],
):
    """
    @notice Add a pool to the registry
    @dev Only callable by admin
    @param _pool Pool address to add
    @param _n_coins Number of coins in the pool
    @param _decimals Underlying coin decimal values
    @param _calldata Calldata to query coin rates
    """

    assert msg.sender == self.admin  # dev: admin-only function
    assert self.pool_data[_pool].coins[0] == ZERO_ADDRESS  # dev: pool exists

    # add pool to pool_list
    _length: int128 = self.pool_count
    self.pool_list[_length] = _pool
    self.pool_count = _length + 1
    self.pool_data[_pool].location = _length
    self.pool_data[_pool].calldata = _calldata

    _decimals_packed: uint256 = 0

    for i in range(MAX_COINS):
        if i == _n_coins:
            break

        _decimals_packed += shift(_decimals[i], i * 16)

        # add coin
        _coin: address = CurvePool(_pool).coins(i)
        ERC20(_coin).approve(_pool, MAX_UINT256)
        self.pool_data[_pool].coins[i] = _coin
        _length = self.markets[_coin].length
        self.markets[_coin].addresses[_length] = _pool
        self.markets[_coin].length = _length + 1

        # add underlying coin
        _ucoin: address = CurvePool(_pool).underlying_coins(i)
        if _ucoin != _coin:
            ERC20(_ucoin).approve(_pool, MAX_UINT256)

        self.pool_data[_pool].underlying_coins[i] = _ucoin
        _length = self.underlying_markets[_ucoin].length
        self.underlying_markets[_ucoin].addresses[_length] = _pool
        self.underlying_markets[_ucoin].length = _length + 1

    self.pool_data[_pool].decimals = convert(_decimals_packed, bytes32)


@public
def remove_pool(_pool: address):
    """
    @notice Remove a pool to the registry
    @dev Only callable by admin
    @param _pool Pool address to remove
    """
    assert msg.sender == self.admin  # dev: admin-only function
    assert self.pool_data[_pool].coins[0] != ZERO_ADDRESS  # dev: pool does not exist

    # remove _pool from pool_list
    _location: int128 = self.pool_data[_pool].location
    _length: int128 = self.pool_count - 1

    if _location < _length:
        # replace _pool with final value in pool_list
        _addr: address = self.pool_list[_length]
        self.pool_list[_location] = _addr
        self.pool_data[_addr].location = _location

    # delete final pool_list value
    self.pool_list[_length] = ZERO_ADDRESS
    self.pool_count = _length

    for i in range(MAX_COINS):
        _coin: address = self.pool_data[_pool].coins[i]
        if _coin == ZERO_ADDRESS:
            break

        # delete coin address from pool_data
        self.pool_data[_pool].coins[i] = ZERO_ADDRESS

        # remove coin from markets
        _length = self.markets[_coin].length - 1
        for x in range(65536):
            if x > _length:
                break
            if self.markets[_coin].addresses[x] == _pool:
                self.markets[_coin].addresses[x] = self.markets[_coin].addresses[_length]
                break
        self.markets[_coin].addresses[_length] = ZERO_ADDRESS
        self.markets[_coin].length = _length

        # delete underlying_coin from pool_data
        _coin = self.pool_data[_pool].underlying_coins[i]
        self.pool_data[_pool].underlying_coins[i] = ZERO_ADDRESS

        # remove underlying_coin from underlying_markets
        _length = self.underlying_markets[_coin].length - 1
        for x in range(65536):
            if x > _length:
                break
            if self.underlying_markets[_coin].addresses[x] == _pool:
                self.underlying_markets[_coin].addresses[x] = self.underlying_markets[_coin].addresses[_length]
                break
        self.underlying_markets[_coin].addresses[_length] = ZERO_ADDRESS
        self.underlying_markets[_coin].length = _length


@public
@constant
def get_pool_info(_pool: address) -> (uint256, uint256):
    """
    @notice Get info on a pool
    @param _pool Pool address
    @return Amplification coefficient
    @return Pool fee
    """
    return CurvePool(_pool).A(), CurvePool(_pool).fee()


@public
@constant
def get_pool_coins(_pool: address) -> (address[MAX_COINS], address[MAX_COINS], uint256[MAX_COINS]):
    """
    @notice Get information on coins in a pool
    @dev Empty values in the returned arrays may be ignored
    @param _pool Pool address
    @return Coin addresses
    @return Underlying coin addresses
    @return Underlying coin decimal values
    """
    _decimals: uint256[MAX_COINS] = empty(uint256[MAX_COINS])
    _decimals_packed: bytes32 = self.pool_data[_pool].decimals

    for i in range(MAX_COINS):
        _decimals[i] = convert(slice(_decimals_packed, 30 - (i * 2), 2), uint256)
        if _decimals[i] == 0:
            break

    return self.pool_data[_pool].coins, self.pool_data[_pool].underlying_coins, _decimals


# TODO let this be @constant
@public
def get_pool_rates(_pool: address) -> uint256[MAX_COINS]:
    """
    @notice Get rates between coins and underlying coins
    @dev For coins where there is no underlying coin, or where
         the underlying coin cannot be swapped, the rate is
         given as 1e18
    @param _pool Pool address
    @return Rates between coins and underlying coins
    """
    _rates: uint256[MAX_COINS] = empty(uint256[MAX_COINS])
    _calldata: bytes[72] = self.pool_data[_pool].calldata
    for i in range(MAX_COINS):
        _coin: address = self.pool_data[_pool].coins[i]
        if _coin == ZERO_ADDRESS:
            break
        if _coin == self.pool_data[_pool].underlying_coins[i]:
            _rates[i] = 1 ** 18
        else:
            _response: bytes[32] = raw_call(_coin, _calldata, outsize=32)
            _rates[i] = convert(_response, uint256)

    return _rates


@public
@constant
def find_pool_for_coins(_from: address, _to: address, i: uint256 = 0) -> address:
    """
    @notice Find an available pool for exchanging two coins
    @dev For coins where there is no underlying coin, or where
         the underlying coin cannot be swapped, the rate is
         given as 1e18
    @param _from Address of coin to be sent
    @param _to Address of coin to be received
    @param i Index value. When multiple pools are available
            this value is used to return the n'th address.
    @return Pool address
    """
    _increment: uint256 = i

    _length: int128 = self.markets[_from].length
    for x in range(65536):
        if x == _length:
            break
        _pool: address = self.markets[_from].addresses[x]
        if _to in self.pool_data[_pool].coins:
            if _increment == 0:
                return _pool
            _increment -= 1

    _length = self.underlying_markets[_from].length
    for x in range(65536):
        if x == _length:
            break
        _pool: address = self.underlying_markets[_from].addresses[x]
        if _to in self.pool_data[_pool].underlying_coins:
            if _increment == 0:
                return _pool
            _increment -= 1

    return ZERO_ADDRESS


@public
@constant
def get_pool_balances(_pool: address) -> (uint256[MAX_COINS], uint256[MAX_COINS]):
    """
    @notice Get all coin balances for a pool
    @dev For coins where there is no underlying coin, or where
         the underlying coin cannot be swapped, the rate is
         given as 1e18
    @param _pool Pool address
    @return Coin balances
    @return Underlying coin balances
    """
    _balances: uint256[MAX_COINS] = empty(uint256[MAX_COINS])
    _underlying_balances: uint256[MAX_COINS] = empty(uint256[MAX_COINS])

    for i in range(MAX_COINS):
        _coin: address = self.pool_data[_pool].coins[i]
        if _coin == ZERO_ADDRESS:
            break
        _balances[i] = ERC20(_coin).balanceOf(_pool)
        _underlying_coin: address = self.pool_data[_pool].underlying_coins[i]
        if _coin == _underlying_coin:
            _underlying_balances[i] = _balances[i]
        else:
            _underlying_balances[i] = ERC20(_underlying_coin).balanceOf(_pool)

    return _balances, _underlying_balances


@private
@constant
def _get_token_indices(
    _pool: address,
    _from: address,
    _to: address,
    _is_underlying: bool
) -> (int128, int128):
    """
    Convert coin addresses to indices for use with pool methods.
    """
    i: int128 = -1
    j: int128 = -1
    _coin: address = ZERO_ADDRESS

    for x in range(MAX_COINS):
        if _is_underlying:
            _coin = self.pool_data[_pool].underlying_coins[x]
        else:
            _coin = self.pool_data[_pool].coins[x]
        if _coin == _from:
            i = x
        elif _coin == _to:
            j = x
        elif _coin == ZERO_ADDRESS:
            break
    assert min(i, j) != -1

    return i, j


@public
@constant
def get_exchange_amount(
    _pool: address,
    _from: address,
    _to: address,
    _amount: uint256
) -> uint256:
    """
    @notice Get the current number of coins received in an exchange
    @param _pool Pool address
    @param _from Address of coin to be sent
    @param _to Address of coin to be received
    @param _amount Quantity of `_from` to be sent
    @return Quantity of `_to` to be received
    """
    i: int128 = 0
    j: int128 = 0
    i, j = self._get_token_indices(_pool, _from, _to, False)

    return CurvePool(_pool).get_dy(i, j, _amount)


@public
@constant
def get_exchange_underlying_amount(
    _pool: address,
    _from: address,
    _to: address,
    _amount: uint256
) -> uint256:
    """
    @notice Get the current number of coins received in an exchange
    @param _pool Pool address
    @param _from Address of coin to be sent
    @param _to Address of coin to be received
    @param _amount Quantity of `_from` to be sent
    @return Quantity of `_to` to be received
    """
    i: int128 = 0
    j: int128 = 0
    i, j = self._get_token_indices(_pool, _from, _to, True)

    return CurvePool(_pool).get_dy_underlying(i, j, _amount)


@public
@nonreentrant("lock")
def exchange(
    _pool: address,
    _from: address,
    _to: address,
    _amount: uint256,
    _expected: uint256
) -> bool:
    """
    @notice Perform an exchange.
    @dev Prior to calling this function you must approve
         this contract to transfer `_amount` coins from `_from`
    @param _from Address of coin being sent
    @param _to Address of coin being received
    @param _amount Quantity of `_from` being sent
    @param _expected Minimum quantity of `_from` received
           in order for the transaction to succeed
    @return True
    """
    i: int128 = 0
    j: int128 = 0
    i, j = self._get_token_indices(_pool, _from, _to, False)

    _initial_balance: uint256 = ERC20(_to).balanceOf(self)

    ERC20(_from).transferFrom(msg.sender, self, _amount)
    CurvePool(_pool).exchange(i, j, _amount, _expected)

    _received: uint256 = ERC20(_to).balanceOf(self) - _initial_balance
    ERC20(_to).transfer(msg.sender, _received)

    return True


@public
@nonreentrant("lock")
def exchange_underlying(
    _pool: address,
    _from: address,
    _to: address,
    _amount: uint256,
    _expected: uint256
) -> bool:
    """
    @notice Perform an exchange of underlying coins.
    @dev Prior to calling this function you must approve
         this contract to transfer `_amount` coins from `_from`
    @param _from Address of coin being sent
    @param _to Address of coin being received
    @param _amount Quantity of `_from` being sent
    @param _expected Minimum quantity of `_from` received
           in order for the transaction to succeed
    @return True
    """
    i: int128 = 0
    j: int128 = 0
    i, j = self._get_token_indices(_pool, _from, _to, True)

    _initial_balance: uint256 = ERC20(_to).balanceOf(self)

    ERC20(_from).transferFrom(msg.sender, self, _amount)
    CurvePool(_pool).exchange_underlying(i, j, _amount, _expected)

    _received: uint256 = ERC20(_to).balanceOf(self) - _initial_balance
    ERC20(_to).transfer(msg.sender, _received)

    return True
