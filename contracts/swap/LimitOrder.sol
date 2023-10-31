// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/utils/Context.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '../interfaces/IMochaRouter02.sol';
import '../interfaces/IMochaPair.sol';
import '../interfaces/IMochaFactory.sol';
import '../interfaces/ITaskTreasury.sol';
import '../libraries/MochaLibrary.sol';
import '../libraries/Math.sol';


contract LimitOrder is Ownable {

    enum OrderStatus { Invalid, Pending, Success, Cancel }

    struct SingleOrder {
        uint256 index;
        address inToken;
        address outToken;
        uint256 inExactAmount;
        uint256 outMinAmount;
        uint256 deadline;
        address userAddress;
        OrderStatus orderStatus;
    }

    struct UserInfo{
        mapping(uint256 => SingleOrder) orders;
    }

    event createTaskEvent(address userAddress, uint256 taskId, address inToken, address outToken, uint256 inExactNum, uint256 minOut, uint256 deadline);
    event cancelTaskEvent(address userAddress, uint256 taskId);
    event execTaskEvent(address userAddress, uint256 taskId);

    ITaskTreasury public taskTreasury;
    IMochaRouter02 public immutable router;
    IMochaFactory public immutable factory;

    address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    mapping(address => UserInfo) userInfos;
    address[] public orderList;

    uint256 taskIdGenerator;
    address receiver;
    

    constructor( address _router, address _receiver, address _initialOwner) Ownable(_initialOwner) {
        router = IMochaRouter02(_router);
        factory = IMochaFactory(router.factory());
        taskIdGenerator = 0;
        receiver = _receiver;
    }

    fallback() payable external {}

    receive() payable external {}

    function _transfer(
        address payable _to,
        address _paymentToken,
        uint256 _amount
    ) internal {
        if (_paymentToken == ETH) {
            (bool success, ) = _to.call{value: _amount}("");
            require(success, "_transfer: ETH transfer failed");
        } else {
            SafeERC20.safeTransfer(IERC20(_paymentToken), _to, _amount);
        }
    }

    function setTreasury(address _taskTreasury) external onlyOwner{
        taskTreasury = ITaskTreasury(_taskTreasury);
    }

    function checkTreasury() internal view{
        require(address(taskTreasury) != address(0x0), "taskTreasury have not set");
    } 
    
    
    function checkSwapValid(address inToken, address outToken, uint256 inExactNum, uint256 minOut)
        public
        returns (bool, address[] memory)
    {
        require(inToken != outToken, "same token error");
        if(inToken == ETH){
            return checkSwapTokenToTokenValid(router.WETH(), outToken, inExactNum, minOut);
        }
        else if(outToken == ETH)
        {
            return checkSwapTokenToTokenValid(inToken, router.WETH(), inExactNum, minOut);
        }
        else
        {
            return checkSwapTokenToTokenValid(inToken, outToken, inExactNum, minOut);
        }
    }

    function checkSwapTokenToTokenValid(address inToken, address outToken, uint256 inExactNum, uint256 minOut)
        public
        returns (bool, address[] memory)
    {
        address[] memory path1 = new address[](2);
        path1[0] = inToken;
        path1[1] = outToken;
        bool resultDirect = checkSwapVaildByPath(path1, inExactNum, minOut);
        if(!resultDirect){
            if(inToken != router.WETH() && outToken != router.WETH()){
                address[] memory path2 = new address[](3);
                path2[0] = inToken;
                path2[1] = router.WETH();
                path2[2] = outToken;
                return (checkSwapVaildByPath(path2, inExactNum, minOut), path2 );
            }
        }
        return (resultDirect, path1);
    }

    function checkSwapVaildByPath( address[] memory path ,uint256 inExactNum, uint256 minOut)
        view
        public
        returns (bool)
    {
        require(path.length >= 2, "path length is required not less than 2");
        for(uint i = 0; i < path.length - 1; i++){
            if(factory.getPair( path[i], path[i+1]) == address(0x0)){
                return false;
            }
        }
        uint256[] memory amounts = MochaLibrary.getAmountsOut(address(factory), inExactNum, path);
        if(amounts[amounts.length - 1] >= minOut){
            return true;
        }
        return false;
    }
   
    function createTask(address inToken, address outToken, uint256 inExactNum, uint256 minOut, uint256 expireTime) 
        payable
        external
        returns( uint256 )
    {
        checkTreasury();
        if(inToken == ETH){
            require(msg.value == inExactNum, "ETH Amount Error");
            taskTreasury.depositFunds{value:inExactNum}(msg.sender, inToken, inExactNum);
        }
        else{
            IERC20 token = IERC20(inToken);
            uint256 allowance = token.allowance(msg.sender, address(this));
            require(allowance >= inExactNum, "Check the token allowance");
            token.transferFrom(msg.sender, address(this), inExactNum);
            token.approve(address(taskTreasury), inExactNum);
            taskTreasury.depositFunds(msg.sender, inToken, inExactNum);
        }

        UserInfo storage info = userInfos[msg.sender];
        SingleOrder storage order = info.orders[taskIdGenerator];
        orderList.push(msg.sender);
        order.index = taskIdGenerator;
        order.inToken = inToken;
        order.outToken = outToken;
        order.inExactAmount = inExactNum;
        order.outMinAmount = minOut;
        order.userAddress = msg.sender;
        //deadline 3 months
        order.deadline = block.timestamp + expireTime;
        order.orderStatus = OrderStatus.Pending;
        emit createTaskEvent(msg.sender, order.index, inToken, outToken, inExactNum, minOut, order.deadline);
        taskIdGenerator++;
        return order.index;
    }

    function getInAmountWithoutFee(uint256 value) internal pure returns(uint256) {
        return value * 998 / 1000;
    }

    function checkTaskCanExec(address userAddress, uint256 taskId)
        external
        returns (bool)
    {
        UserInfo storage info = userInfos[userAddress];
        SingleOrder storage order = info.orders[taskId];
        require(order.orderStatus != OrderStatus.Invalid, "Order is not exist");
        require(order.orderStatus == OrderStatus.Pending, "Order Status Error");
        
        (bool re,) = checkSwapValid( order.inToken, order.outToken, getInAmountWithoutFee(order.inExactAmount), order.outMinAmount);
        return re;
    }

    function execTask(address userAddress, uint256 taskId)
        external
    {
        checkTreasury();
        UserInfo storage info = userInfos[userAddress];
        SingleOrder storage order = info.orders[taskId];
        require(order.orderStatus != OrderStatus.Invalid, "Order is not exist");
        require(order.orderStatus == OrderStatus.Pending, "Order Status Error");
        require(order.deadline >= block.timestamp, "Order is Expired" );
        taskTreasury.useFunds(order.inToken, order.inExactAmount, userAddress);
        uint256 realInAmount = getInAmountWithoutFee(order.inExactAmount);
        (bool re, address[] memory path) = checkSwapValid(order.inToken, order.outToken, realInAmount, order.outMinAmount);
        require(re == true, "swap cannot exec");
        if(order.inToken == ETH){
            router.swapExactETHForTokens{value: realInAmount}(order.outMinAmount, path, userAddress, block.timestamp + 20 * 60);
        }
        else{
            IERC20 token = IERC20(order.inToken);
            require(token.balanceOf(address(this)) == order.inExactAmount, "useFunds error");
            token.approve( address(router), realInAmount);
            if(order.outToken == ETH){
                router.swapExactTokensForETH(realInAmount, order.outMinAmount, path, userAddress,  block.timestamp + 20 * 60);
            }
            else{
                router.swapExactTokensForTokens(realInAmount, order.outMinAmount, path, userAddress,  block.timestamp + 20 * 60);
            }
        }
        _transfer(payable(receiver), order.inToken, order.inExactAmount - realInAmount);
        order.orderStatus = OrderStatus.Success;
        emit execTaskEvent(userAddress, taskId);
    }

    function cancelTask(address userAddress, uint256 taskId) external {
        checkTreasury();
        UserInfo storage info = userInfos[userAddress];
        SingleOrder storage order = info.orders[taskId];
        require(userAddress == msg.sender || msg.sender == owner(), "user error");
        require(order.orderStatus != OrderStatus.Invalid, "Order is not exist");
        require(order.orderStatus == OrderStatus.Pending, "Order Status Error");
        taskTreasury.useFunds(order.inToken, order.inExactAmount, userAddress);
        _transfer( payable(userAddress), order.inToken, order.inExactAmount);
        order.orderStatus = OrderStatus.Cancel;
        emit cancelTaskEvent(userAddress, taskId);
    }

    function getOrderInfo(uint256 from, uint256 offset) external view returns( SingleOrder[] memory ) {
        if(offset <=0 ){
            SingleOrder[] memory empty = new SingleOrder[](0);
            return empty;
        }
        SingleOrder[] memory re = new SingleOrder[](offset);
        if(orderList.length <= from){
            return re;
        }
        else{
           
            for(uint i = 0; i < offset; i++){
                if(i + from >= orderList.length){
                    return re;
                }
                SingleOrder storage temp =  userInfos[orderList[i + from]].orders[ i + from];
                re[i] = temp;
            }
        }
        return re;
    }

    function getLength() external view returns( uint ){
        return orderList.length;
    }
}
