// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../tokens/MochaToken.sol";
import "../interfaces/IMochaPair.sol";
import "../interfaces/IMochaFactory.sol";
import "../libraries/MochaLibrary.sol";

interface IOracle {
    function update(address tokenA, address tokenB) external returns (bool);

    function updateBlockInfo() external returns (bool);

    function getQuantity(address token, uint256 amount) external view returns (uint256);
}

contract TradingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private _pairs;

    // Info of each user.
    struct UserInfo {
        uint256 quantity;
        uint256 accQuantity;
        uint256 pendingReward;
        uint256 rewardDebt; // Reward debt.
        uint256 accMchAmount; // How many rewards the user has got.
    }

    struct UserView {
        uint256 quantity;
        uint256 accQuantity;
        uint256 unclaimedRewards;
        uint256 accMchAmount;
    }

    // Info of each pool.
    struct PoolInfo {
        address pair; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. mchs to distribute per block.
        uint256 lastRewardBlock; // Last block number that mchs distribution occurs.
        uint256 accMchPerShare; // Accumulated mchs per share, times 1e12.
        uint256 quantity; // LP Token Total Supply
        uint256 accQuantity;
        uint256 allocMchAmount;
        uint256 accMchAmount;
    }

    struct PoolView {
        uint256 pid;
        address pair;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 rewardsPerBlock;
        uint256 accMchPerShare;
        uint256 allocMchAmount;
        uint256 accMchAmount;
        uint256 quantity;
        uint256 accQuantity;
        address token0;
        string symbol0;
        string name0;
        uint8 decimals0;
        address token1;
        string symbol1;
        string name1;
        uint8 decimals1;
    }

    // The MCH Token!
    MochaToken public mch;
    // mch tokens created per block.
    uint256 public mchPerBlock;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // pid corresponding address
    mapping(address => uint256) public pairOfPid;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    uint256 public totalQuantity = 0;
    IOracle public oracle;
    // router address
    address public router;
    // factory address
    IMochaFactory public factory;
    // The block number when mch mining starts.
    uint256 public startBlock;
    uint256 public halvingPeriod = 3952800; // half year

    event Swap(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        MochaToken _mch,
        IMochaFactory _factory,
        IOracle _oracle,
        address _router,
        uint256 _mchPerBlock,
        uint256 _startBlock,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(address(_mch) != address(0));
        require(address(_factory) != address(0));
        require(_router != address(0));
        require(address(_oracle) != address(0));
        mch = _mch;
        factory = _factory;
        oracle = _oracle;
        router = _router;
        mchPerBlock = _mchPerBlock;
        startBlock = _startBlock;
    }

    function phase(uint256 blockNumber) public view returns (uint256) {
        if (halvingPeriod == 0) {
            return 0;
        }
        if (blockNumber > startBlock) {
            return (blockNumber - (startBlock) - (1)) / (halvingPeriod);
        }
        return 0;
    }

    function getMchPerBlock(uint256 blockNumber) public view returns (uint256) {
        uint256 _phase = phase(blockNumber);
        return mchPerBlock / (2**_phase);
    }

    function getMchBlockReward(uint256 _lastRewardBlock) public view returns (uint256) {
        uint256 blockReward = 0;
        uint256 lastRewardPhase = phase(_lastRewardBlock);
        uint256 currentPhase = phase(block.number);
        while (lastRewardPhase < currentPhase) {
            lastRewardPhase++;
            uint256 height = lastRewardPhase * (halvingPeriod) + (startBlock);
            blockReward = blockReward + ((height - (_lastRewardBlock)) * (getMchPerBlock(height)));
            _lastRewardBlock = height;
        }
        blockReward = blockReward + ((block.number - (_lastRewardBlock)) * (getMchPerBlock(block.number)));
        return blockReward;
    }

    // Add a new pair to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        address _pair,
        bool _withUpdate
    ) public onlyOwner {
        require(_pair != address(0), "TradingPool: _pair is the zero address");

        require(!EnumerableSet.contains(_pairs, _pair), "TradingPool: _pair is already added to the pool");
        // return EnumerableSet.add(_pairs, _pair);
        EnumerableSet.add(_pairs, _pair);

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint + (_allocPoint);
        poolInfo.push(
            PoolInfo({
                pair: _pair,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accMchPerShare: 0,
                quantity: 0,
                accQuantity: 0,
                allocMchAmount: 0,
                accMchAmount: 0
            })
        );
        pairOfPid[_pair] = getPoolLength() - 1;
    }

    // Update the given pool's mch allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint - (poolInfo[_pid].allocPoint) + (_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        if (pool.quantity == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 blockReward = getMchBlockReward(pool.lastRewardBlock);

        if (blockReward <= 0) {
            return;
        }

        uint256 mchReward = blockReward * (pool.allocPoint) / (totalAllocPoint);

        bool minRet = mch.mint(address(this), mchReward);
        if (minRet) {
            pool.accMchPerShare = pool.accMchPerShare + (mchReward * (1e12) / (pool.quantity));
            pool.allocMchAmount = pool.allocMchAmount + (mchReward);
            pool.accMchAmount = pool.accMchAmount + (mchReward);
        }
        pool.lastRewardBlock = block.number;
    }

    function swap(
        address account,
        address input,
        address output,
        uint256 amount
    ) public onlyRouter returns (bool) {
        require(account != address(0), "TradingPool: swap account is zero address");
        require(input != address(0), "TradingPool: swap input is zero address");
        require(output != address(0), "TradingPool: swap output is zero address");

        if (getPoolLength() <= 0) {
            return false;
        }

        address pair = MochaLibrary.pairFor(address(factory), input, output);

        PoolInfo storage pool = poolInfo[pairOfPid[pair]];
        // If it does not exist or the allocPoint is 0 then return
        if (pool.pair != pair || pool.allocPoint <= 0) {
            return false;
        }

        uint256 quantity = IOracle(oracle).getQuantity(output, amount);
        if (quantity <= 0) {
            return false;
        }

        updatePool(pairOfPid[pair]);
        IOracle(oracle).update(input, output);
        IOracle(oracle).updateBlockInfo();

        UserInfo storage user = userInfo[pairOfPid[pair]][account];
        if (user.quantity > 0) {
            uint256 pendingReward = user.quantity * (pool.accMchPerShare) / (1e12) - (user.rewardDebt);
            if (pendingReward > 0) {
                user.pendingReward = user.pendingReward + (pendingReward);
            }
        }

        if (quantity > 0) {
            pool.quantity = pool.quantity + (quantity);
            pool.accQuantity = pool.accQuantity + (quantity);
            totalQuantity = totalQuantity + (quantity);
            user.quantity = user.quantity + (quantity);
            user.accQuantity = user.accQuantity + (quantity);
        }
        user.rewardDebt = user.quantity * (pool.accMchPerShare) / (1e12);
        emit Swap(account, pairOfPid[pair], quantity);

        return true;
    }

    function pendingMch(uint256 _pid, address _user) public view returns (uint256) {
        require(_pid <= poolInfo.length - 1, "TradingPool: Can not find this pool");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accMchPerShare = pool.accMchPerShare;

        if (user.quantity > 0) {
            if (block.number > pool.lastRewardBlock) {
                uint256 blockReward = getMchBlockReward(pool.lastRewardBlock);
                uint256 mchReward = blockReward * (pool.allocPoint) / (totalAllocPoint);
                accMchPerShare = accMchPerShare + (mchReward * (1e12) / (pool.quantity));
                return user.pendingReward + (user.quantity * (accMchPerShare) / (1e12) - (user.rewardDebt));
            }
            if (block.number == pool.lastRewardBlock) {
                return user.pendingReward + (user.quantity * (accMchPerShare) / (1e12) - (user.rewardDebt));
            }
        }
        return 0;
    }

    function pendingMchAll(address _user) external view returns (uint256) {
        uint256 total = 0;
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; ++_pid) {
            PoolInfo storage pool = poolInfo[_pid];
            UserInfo storage user = userInfo[_pid][_user];
            uint256 accMchPerShare = pool.accMchPerShare;
            if (block.number > pool.lastRewardBlock) {
                uint256 blockReward = getMchBlockReward(pool.lastRewardBlock);
                uint256 mchReward = blockReward * (pool.allocPoint) / (totalAllocPoint);
                accMchPerShare = accMchPerShare + (mchReward * (1e12) / (pool.quantity));
                return user.pendingReward + (user.quantity * (accMchPerShare) / (1e12) - (user.rewardDebt));
            }
            if (block.number == pool.lastRewardBlock) {
                return user.pendingReward + (user.quantity * (accMchPerShare) / (1e12) - (user.rewardDebt) + total);
            }
        }
        return total;
    }

    function withdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][tx.origin];

        updatePool(_pid);
        uint256 pendingAmount = pendingMch(_pid, tx.origin);

        if (pendingAmount > 0) {
            safeMchTransfer(tx.origin, pendingAmount);
            pool.quantity = pool.quantity - (user.quantity);
            pool.allocMchAmount = pool.allocMchAmount - (pendingAmount);
            user.accMchAmount = user.accMchAmount + (pendingAmount);
            user.quantity = 0;
            user.rewardDebt = 0;
            user.pendingReward = 0;
        }
        emit Withdraw(tx.origin, _pid, pendingAmount);
    }

    function harvestAll() public {
        for (uint256 i = 0; i < poolInfo.length; i++) {
            withdraw(i);
        }
    }

    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        safeMchTransfer(msg.sender, user.pendingReward);

        pool.quantity = pool.quantity - (user.quantity);
        pool.allocMchAmount = pool.allocMchAmount - (user.pendingReward);
        user.accMchAmount = user.accMchAmount + (user.pendingReward);
        user.quantity = 0;
        user.rewardDebt = 0;
        user.pendingReward = 0;
        emit EmergencyWithdraw(msg.sender, _pid, user.quantity);
    }

    // Safe mch transfer function, just in case if rounding error causes pool to not have enough mchs.
    function safeMchTransfer(address _to, uint256 _amount) internal {
        uint256 mchBalance = mch.balanceOf(address(this));
        if (_amount > mchBalance) {
            mch.transfer(_to, mchBalance);
        } else {
            mch.transfer(_to, _amount);
        }
    }

    // Set the number of mch produced by each block
    function setMchPerBlock(uint256 _newPerBlock) public onlyOwner {
        massUpdatePools();
        mchPerBlock = _newPerBlock;
    }

    function setHalvingPeriod(uint256 _block) public onlyOwner {
        halvingPeriod = _block;
    }

    function setRouter(address newRouter) public onlyOwner {
        require(newRouter != address(0), "TradingPool: new router is the zero address");
        router = newRouter;
    }

    function setOracle(IOracle _oracle) public onlyOwner {
        require(address(_oracle) != address(0), "TradingPool: new oracle is the zero address");
        oracle = _oracle;
    }

    function getPairsLength() public view returns (uint256) {
        return EnumerableSet.length(_pairs);
    }

    function getPairs(uint256 _index) public view returns (address) {
        require(_index <= getPairsLength() - 1, "TradingPool: index out of bounds");
        return EnumerableSet.at(_pairs, _index);
    }

    function getPoolLength() public view returns (uint256) {
        return poolInfo.length;
    }

    function getAllPools() external view returns (PoolInfo[] memory) {
        return poolInfo;
    }

    function getPoolView(uint256 pid) public view returns (PoolView memory) {
        require(pid < poolInfo.length, "TradingPool: pid out of range");
        PoolInfo memory pool = poolInfo[pid];
        address pair = address(pool.pair);
        ERC20 token0 = ERC20(IMochaPair(pair).token0());
        ERC20 token1 = ERC20(IMochaPair(pair).token1());
        string memory symbol0 = token0.symbol();
        string memory name0 = token0.name();
        uint8 decimals0 = token0.decimals();
        string memory symbol1 = token1.symbol();
        string memory name1 = token1.name();
        uint8 decimals1 = token1.decimals();
        uint256 rewardsPerBlock = pool.allocPoint * (mchPerBlock) / (totalAllocPoint);
        return
            PoolView({
                pid: pid,
                pair: pair,
                allocPoint: pool.allocPoint,
                lastRewardBlock: pool.lastRewardBlock,
                accMchPerShare: pool.accMchPerShare,
                rewardsPerBlock: rewardsPerBlock,
                allocMchAmount: pool.allocMchAmount,
                accMchAmount: pool.accMchAmount,
                quantity: pool.quantity,
                accQuantity: pool.accQuantity,
                token0: address(token0),
                symbol0: symbol0,
                name0: name0,
                decimals0: decimals0,
                token1: address(token1),
                symbol1: symbol1,
                name1: name1,
                decimals1: decimals1
            });
    }

    function getPoolViewByAddress(address pair) public view returns (PoolView memory) {
        uint256 pid = pairOfPid[pair];
        return getPoolView(pid);
    }

    function getAllPoolViews() external view returns (PoolView[] memory) {
        PoolView[] memory views = new PoolView[](poolInfo.length);
        for (uint256 i = 0; i < poolInfo.length; i++) {
            views[i] = getPoolView(i);
        }
        return views;
    }

    function getUserView(address pair, address account) public view returns (UserView memory) {
        uint256 pid = pairOfPid[pair];
        UserInfo memory user = userInfo[pid][account];
        uint256 unclaimedRewards = pendingMch(pid, account);
        return
            UserView({
                quantity: user.quantity,
                accQuantity: user.accQuantity,
                unclaimedRewards: unclaimedRewards,
                accMchAmount: user.accMchAmount
            });
    }

    function getUserViews(address account) external view returns (UserView[] memory) {
        address pair;
        UserView[] memory views = new UserView[](poolInfo.length);
        for (uint256 i = 0; i < poolInfo.length; i++) {
            pair = address(poolInfo[i].pair);
            views[i] = getUserView(pair, account);
        }
        return views;
    }

    modifier onlyRouter() {
        require(msg.sender == router, "TradingPool: caller is not the router");
        _;
    }
}
