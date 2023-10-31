// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./tokens/MochaToken.sol";


contract MochaKeeper is Ownable {

    struct MochaApplication {
        address mochaMember; // Address of member
        uint256 totalValue; // Total amount of mocha that can be requested
        uint256 transferedValue; // Total transfered mocha 
        uint256 perBlockLimit; //  
        uint256 startBlock; // 
    } 

    // The Mocha TOKEN!
    MochaToken public mocha;
    mapping(address => MochaApplication) public applications;
    bool public appPublished; // when published, applications can not be modified
    address public immutable devAddr; // 1/4 extra
    address public immutable investorAddr; // 1/8 extra
    address public immutable foundationAddr;// 1/8 extra

    event ApplicationAdded(address indexed mochaMember, uint256 totalValue, uint256 perBlockLimit, uint256 startBlock );
    event ApplicationPublished(address publisher);

    event MochaForRequestor(address indexed to, uint256 amount);
    
    modifier appNotPublished() {
        require(!appPublished, "MochaKeeper: app published");
        _;
    }

    constructor(
        MochaToken _mocha,
        address _devAddr,
        address _investorAddr,
        address _foundationAddr,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_devAddr != address(0));
        require(_investorAddr != address(0));
        require(_foundationAddr != address(0)); 
        require(address(_mocha) !=  address(0));

        mocha = _mocha;
        appPublished = false;
        devAddr = _devAddr;
        investorAddr = _investorAddr;
        foundationAddr = _foundationAddr;
    }


    function addApplication(address _mochaMember , uint256 _totalValue, uint256 _perBlockLimit, uint256 _startBlock ) public onlyOwner appNotPublished {
        MochaApplication storage app = applications[_mochaMember];
        app.mochaMember = _mochaMember;
        app.totalValue = _totalValue;
        app.transferedValue = 0;
        app.perBlockLimit = _perBlockLimit;
        app.startBlock = _startBlock;
        emit ApplicationAdded(_mochaMember, _totalValue, _perBlockLimit, _startBlock);
    
    }

    function publishApplication() public onlyOwner appNotPublished {
        appPublished = true;
        emit ApplicationPublished(msg.sender);
    }
 

    function requestForMocha(uint256 _amount) public  returns (uint256) {
        // when reward is zero, this should not revert because the swap methods still depend on this
        if(_amount == 0){
            return 0;
        }
        MochaApplication storage app = applications[msg.sender];
        require(app.mochaMember == msg.sender, "not mocha member"  );
        require(block.number >app.startBlock, "not start");
        uint256 unlocked = block.number - (app.startBlock) * (app.perBlockLimit);
        uint256 newTransfered = app.transferedValue + (_amount);
        require(newTransfered <=  unlocked, "transferd is over unlocked "); 
        require(newTransfered <= app.totalValue,"transferd is over total ");

        // when 1 mocha is mint, 0.3 should be sent (0.1 for investor, 0.1 for foundtaion, 0.1 for dev) 
        // mint to dev, investor, foundation
        mocha.mint(devAddr, _amount / (10));
        mocha.mint(investorAddr, _amount / (10));
        mocha.mint(foundationAddr, _amount / (10));

        uint256 leftAmount = _queryActualMochaReward(_amount);

        if(!mocha.mint(msg.sender,leftAmount)){
            // mocha not enough
            leftAmount = 0;
        }else{ 
            // mint ok
            app.transferedValue = newTransfered;
        }

        emit MochaForRequestor(msg.sender, leftAmount);
        return leftAmount;
    }

    function queryActualMochaReward(uint256 _amount) public pure returns (uint256) {
        return _queryActualMochaReward(_amount);
    }

    function _queryActualMochaReward(uint256 _amount) internal pure returns (uint256) {
        uint256 actualAmount =  _amount / (10) * (7);
        return actualAmount;
    }
}
