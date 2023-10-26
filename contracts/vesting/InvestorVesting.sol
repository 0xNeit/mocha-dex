// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract InvestorVesting is Ownable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private _whitelist;

    uint256 public totalWeight;
    uint256 public totalAmount;
    uint256 public historyAmount;
    uint256 public startTime;
    address public token;
    uint256 public constant PERIOD = 1 days;
    uint256 public constant CYCLE_TIMES = 365;
    address public _owner;

    struct UserInfo {
        uint256 weight;
        uint256 historyAmount;
    }

    struct UserView {
        uint256 historyAmount;
        uint256 pendingAmount;
        uint256 totalAmount;
    }

    mapping(address => UserInfo) public users;

    event WithDraw(address to, uint256 amount);

    constructor(
        uint256 _timestamp,
        address _token,
        uint256 _totalAmount,
        address _initialOwner
    ) Ownable(_initialOwner) {
        _owner = _initialOwner;
        startTime = _timestamp;
        token = _token;
        totalAmount = _totalAmount;
    }

    function addUser(address _account, uint256 _weight) public onlyOwner {
        require(_weight > 0, "Timelock: weight is 0");
        addWhitelist(_account);
        users[_account].weight = users[_account].weight + (_weight);
        totalWeight = totalWeight + (_weight);
    }

    function setUserWeight(address _account, uint256 _weight) public onlyOwner {
        uint256 formerWeight = users[_account].weight;
        users[_account].weight = _weight;
        totalWeight = totalWeight + (_weight) - (formerWeight);
    }

    function getUserInfo(address _account) public view returns (UserView memory) {
        uint256 pendingAmount = getPendingReward(_account);
        uint256 userHistoryAmount = users[_account].historyAmount;
        uint256 userTotalAmount = users[_account].weight * (totalAmount) / (totalWeight);
        return UserView({historyAmount: userHistoryAmount, pendingAmount: pendingAmount, totalAmount: userTotalAmount});
    }

    function getCurrentCycle() public view returns (uint256 cycle) {
        uint256 pCycle = (block.timestamp - (startTime)) / (PERIOD);
        cycle = pCycle >= CYCLE_TIMES ? CYCLE_TIMES : pCycle;
    }

    function getPendingReward(address _account) public view returns (uint256) {
        if (!isWhitelist(_account)) return 0;

        uint256 cycle = getCurrentCycle();
        uint256 userReward = users[_account].weight * (totalAmount) * (cycle) / (CYCLE_TIMES) / (totalWeight);
        return userReward - (users[_account].historyAmount);
    }

    function withdraw() external {
        require(isWhitelist(msg.sender), "TimeLock: Not in the whitelist");

        uint256 reward = getPendingReward(msg.sender);
        require(reward > 0, "TimeLock: no reward");
        IERC20(token).safeTransfer(msg.sender, reward);
        historyAmount = historyAmount + (reward);
        users[msg.sender].historyAmount = users[msg.sender].historyAmount + (reward);
        emit WithDraw(msg.sender, reward);
    }

    function addWhitelist(address _account) public onlyOwner returns (bool) {
        require(_account != address(0), "TimeLock: address is zero");
        return EnumerableSet.add(_whitelist, _account);
    }

    function delWhitelist(address _account) public onlyOwner returns (bool) {
        require(_account != address(0), "TimeLock: address is zero");
        return EnumerableSet.remove(_whitelist, _account);
    }

    function getWhitelistLength() public view returns (uint256) {
        return EnumerableSet.length(_whitelist);
    }

    function isWhitelist(address _account) public view returns (bool) {
        return EnumerableSet.contains(_whitelist, _account);
    }

    function getWhitelist(uint256 _index) public view returns (address) {
        require(_index <= getWhitelistLength() - 1, "TimeLock: index out of bounds");
        return EnumerableSet.at(_whitelist, _index);
    }
}
