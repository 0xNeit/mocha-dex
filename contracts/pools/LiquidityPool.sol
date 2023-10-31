// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../tokens/MochaToken.sol";
import "../interfaces/IMochaPair.sol";
import "../interfaces/IAsset.sol";

contract LiquidityPool is Ownable, IAsset, ReentrancyGuard {
    using SafeERC20 for ERC20;

    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private _pairs;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt.
        uint256 accMchAmount; // How many rewards the user has got.
    }

    struct UserAssetData {
        uint256 totalDeposit;
        uint256 totalFreezed;
        mapping(address => uint256) freezedAmount;
        mapping(address => uint256) allowances;
    }

    struct UserView {
        uint256 stakedAmount;
        uint256 unclaimedRewards;
        uint256 lpBalance;
        uint256 accMchAmount;
    }

    // Info of each pool.
    struct PoolInfo {
        address lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. mchs to distribute per block.
        uint256 lastRewardBlock; // Last block number that mchs distribution occurs.
        uint256 accMchPerShare; // Accumulated mchs per share, times 1e12.
        uint256 totalAmount; // Total amount of current pool deposit.
        uint256 allocMchAmount;
        uint256 accMchAmount;
    }

    struct PoolView {
        uint256 pid;
        address lpToken;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 rewardsPerBlock;
        uint256 accMchPerShare;
        uint256 allocMchAmount;
        uint256 accMchAmount;
        uint256 totalAmount;
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
    mapping(address => mapping(address => UserAssetData)) private userAssetData;
    // pid corresponding address
    mapping(address => uint256) public LpOfPid;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when mch mining starts.
    uint256 public startBlock;
    uint256 public halvingPeriod = 3952800; // half year

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        MochaToken _mch,
        uint256 _mchPerBlock,
        uint256 _startBlock,
        address _initialOwner
    ) Ownable(_initialOwner) {
        mch = _mch;
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

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        address _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        require(_lpToken != address(0), "LiquidityPool: _lpToken is the zero address");

        require(!EnumerableSet.contains(_pairs, _lpToken), "LiquidityPool: _lpToken is already added to the pool");
        // return EnumerableSet.add(_pairs, _lpToken);
        EnumerableSet.add(_pairs, _lpToken);

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint + (_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accMchPerShare: 0,
                totalAmount: 0,
                allocMchAmount: 0,
                accMchAmount: 0
            })
        );
        LpOfPid[_lpToken] = getPoolLength() - 1;
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

        uint256 lpSupply = ERC20(pool.lpToken).balanceOf(address(this));
        if (lpSupply == 0) {
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
            pool.accMchPerShare = pool.accMchPerShare + (mchReward * (1e12) / (lpSupply));
            pool.allocMchAmount = pool.allocMchAmount + (mchReward);
            pool.accMchAmount = pool.allocMchAmount + (mchReward);
        }
        pool.lastRewardBlock = block.number;
    }

    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pendingAmount = user.amount * (pool.accMchPerShare) / (1e12) - (user.rewardDebt);
            if (pendingAmount > 0) {
                safeMchTransfer(msg.sender, pendingAmount);
                user.accMchAmount = user.accMchAmount + (pendingAmount);
                pool.allocMchAmount = pool.allocMchAmount - (pendingAmount);
            }
        }
        if (_amount > 0) {
            ERC20(pool.lpToken).safeTransferFrom(msg.sender, address(this), _amount);
            user.amount = user.amount + (_amount);
            pool.totalAmount = pool.totalAmount + (_amount);
        }
        user.rewardDebt = user.amount * (pool.accMchPerShare) / (1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    function pendingMch(uint256 _pid, address _user) public view returns (uint256) {
        require(_pid <= poolInfo.length - 1, "LiquidityPool: Can not find this pool");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accMchPerShare = pool.accMchPerShare;
        uint256 lpSupply = ERC20(pool.lpToken).balanceOf(address(this));
        if (user.amount > 0) {
            if (block.number > pool.lastRewardBlock) {
                uint256 blockReward = getMchBlockReward(pool.lastRewardBlock);
                uint256 mchReward = blockReward * (pool.allocPoint) / (totalAllocPoint);
                accMchPerShare = accMchPerShare + (mchReward * (1e12) / (lpSupply));
                return user.amount * (accMchPerShare) / (1e12) - (user.rewardDebt);
            }
            if (block.number == pool.lastRewardBlock) {
                return user.amount * (accMchPerShare) / (1e12) - (user.rewardDebt);
            }
        }
        return 0;
    }

    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][tx.origin];
        require(user.amount >= _amount, "LiquidityPool: withdraw not good");
        updatePool(_pid);
        uint256 pendingAmount = user.amount * (pool.accMchPerShare) / (1e12) - (user.rewardDebt);
        if (pendingAmount > 0) {
            safeMchTransfer(tx.origin, pendingAmount);
            user.accMchAmount = user.accMchAmount + (pendingAmount);
            pool.allocMchAmount = pool.allocMchAmount - (pendingAmount);
        }
        if (_amount > 0) {
            user.amount = user.amount - (_amount);
            pool.totalAmount = pool.totalAmount - (_amount);
            ERC20(pool.lpToken).safeTransfer(tx.origin, _amount);
        }
        user.rewardDebt = user.amount * (pool.accMchPerShare) / (1e12);
        emit Withdraw(tx.origin, _pid, _amount);
    }

    function harvestAll() public nonReentrant {
        for (uint256 i = 0; i < poolInfo.length; i++) {
            withdraw(i, 0);
        }
    }

    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        ERC20(pool.lpToken).safeTransfer(msg.sender, amount);
        pool.totalAmount = pool.totalAmount - (amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
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

    function getPairsLength() public view returns (uint256) {
        return EnumerableSet.length(_pairs);
    }

    function getPairs(uint256 _index) public view returns (address) {
        require(_index <= getPairsLength() - 1, "LiquidityPool: index out of bounds");
        return EnumerableSet.at(_pairs, _index);
    }

    function getPoolLength() public view returns (uint256) {
        return poolInfo.length;
    }

    function getAllPools() external view returns (PoolInfo[] memory) {
        return poolInfo;
    }

    function getPoolView(uint256 pid) public view returns (PoolView memory) {
        require(pid < poolInfo.length, "LiquidityPool: pid out of range");
        PoolInfo memory pool = poolInfo[pid];
        address lpToken = pool.lpToken;
        ERC20 token0 = ERC20(IMochaPair(lpToken).token0());
        ERC20 token1 = ERC20(IMochaPair(lpToken).token1());
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
                lpToken: lpToken,
                allocPoint: pool.allocPoint,
                lastRewardBlock: pool.lastRewardBlock,
                accMchPerShare: pool.accMchPerShare,
                rewardsPerBlock: rewardsPerBlock,
                allocMchAmount: pool.allocMchAmount,
                accMchAmount: pool.accMchAmount,
                totalAmount: pool.totalAmount,
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

    function getPoolViewByAddress(address lpToken) public view returns (PoolView memory) {
        uint256 pid = LpOfPid[lpToken];
        return getPoolView(pid);
    }

    function getAllPoolViews() external view returns (PoolView[] memory) {
        PoolView[] memory views = new PoolView[](poolInfo.length);
        for (uint256 i = 0; i < poolInfo.length; i++) {
            views[i] = getPoolView(i);
        }
        return views;
    }

    function getUserView(address lpToken, address account) public view returns (UserView memory) {
        uint256 pid = LpOfPid[lpToken];
        UserInfo memory user = userInfo[pid][account];
        uint256 unclaimedRewards = pendingMch(pid, account);
        uint256 lpBalance = ERC20(lpToken).balanceOf(account);
        return
            UserView({
                stakedAmount: user.amount,
                unclaimedRewards: unclaimedRewards,
                lpBalance: lpBalance,
                accMchAmount: user.accMchAmount
            });
    }

    function getUserViews(address account) external view returns (UserView[] memory) {
        address lpToken;
        UserView[] memory views = new UserView[](poolInfo.length);
        for (uint256 i = 0; i < poolInfo.length; i++) {
            lpToken = address(poolInfo[i].lpToken);
            views[i] = getUserView(lpToken, account);
        }
        return views;
    }

    function approve(
        address _spender,
        address _asset,
        uint256 _amount
    ) external override returns (bool) {
        require(msg.sender != address(0), "IAsset: approve from the zero address");
        require(_spender != address(0), "IAsset: approve to the zero address");
        require(
            _amount >= userAssetData[msg.sender][_asset].freezedAmount[_spender],
            "IAsset: approve amount less than freezedAmount"
        );
        userAssetData[msg.sender][_asset].allowances[_spender] = _amount;
        emit Approve(msg.sender, _spender, _asset, _amount);
        return true;
    }

    function freezeAsset(
        address _user,
        address _asset,
        uint256 _amount
    ) external override returns (bool) {
        require(
            userAssetData[_user][_asset].allowances[msg.sender] >=
                userAssetData[_user][_asset].freezedAmount[msg.sender] + (_amount),
            "IAsset: freeze must less than allowanced"
        );
        require(getUserAvailableAsset(_user, _asset) >= _amount, "IAsset: there is not enough asset to be freezed");

        UserAssetData storage data = userAssetData[_user][_asset];
        data.totalFreezed = data.totalFreezed + (_amount);
        data.freezedAmount[msg.sender] = data.freezedAmount[msg.sender] + (_amount);
        emit FreezeAsset(_user, _asset, _amount);
        return true;
    }

    function unfreezeAsset(
        address _user,
        address _asset,
        uint256 _amount
    ) external override returns (bool) {
        UserAssetData storage data = userAssetData[_user][_asset];
        require(data.freezedAmount[msg.sender] >= _amount, "IAsset: there is not enough frezon asset to be unfreezed");

        data.totalFreezed = data.totalFreezed - (_amount);
        data.freezedAmount[msg.sender] = data.freezedAmount[msg.sender] - (_amount);
        emit UnfreezeAsset(_user, _asset, _amount);
        return true;
    }

    function transferFrom(
        address _from,
        address _receiver,
        address _asset,
        uint256 _amount
    ) external override returns (bool) {
        require(
            userAssetData[_from][_asset].allowances[msg.sender] >= _amount,
            "IAsset: amount over than the allowanced"
        );
        require(
            userAssetData[_from][_asset].freezedAmount[msg.sender] >= _amount,
            "IAsset: amount over than the frezon asset"
        );
        require(
            ERC20(_asset).balanceOf(address(this)) >= _amount,
            "IAsset: there is not enough frezon asset to transfer"
        );

        UserAssetData storage data = userAssetData[_from][_asset];
        data.totalDeposit = data.totalDeposit - (_amount);
        data.totalFreezed = data.totalFreezed - (_amount);
        data.freezedAmount[msg.sender] = data.freezedAmount[msg.sender] - (_amount);
        data.allowances[msg.sender] = data.allowances[msg.sender] - (_amount);
        ERC20(_asset).safeTransfer(_receiver, _amount);
        emit TransferFrom(_from, _receiver, _asset, _amount);
        return true;
    }

    function getUserAsset(address _user, address _asset) external view override returns (uint256) {
        return userAssetData[_user][_asset].totalDeposit;
    }

    function getUserAvailableAsset(address _user, address _asset) public view override returns (uint256) {
        UserAssetData storage data = userAssetData[_user][_asset];
        uint256 result = data.totalDeposit - (data.totalFreezed);
        return result;
    }
}
