// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import '../interfaces/IMochaFactory.sol';
import './MochaPair.sol';

contract MochaFactory is IMochaFactory {
    address public override feeTo;
    address public override feeToSetter;
    uint256 public override feeToRate;

    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;

    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view override returns (uint256) {
        return allPairs.length;
    }

    function pairCodeHash() external pure returns (bytes32) {
        return keccak256(type(MochaPair).creationCode);
    }

    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        require(tokenA != tokenB, 'Mocha: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'Mocha: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'Mocha: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(MochaPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        MochaPair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external override {
        require(msg.sender == feeToSetter, 'MochaFactory: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external override {
        require(msg.sender == feeToSetter, 'MochaFactory: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }

    function setFeeToRate(uint256 _rate) external override {
        require(msg.sender == feeToSetter, 'MochaFactory: FORBIDDEN');
        require(_rate > 0, 'MochaFactory: FEE_TO_RATE_OVERFLOW');
        feeToRate = _rate - (1);
    }
}
