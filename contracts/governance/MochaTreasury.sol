// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../libraries/MochaLibrary.sol";
import "../interfaces/IMochaRouter02.sol";

contract MochaTreasury is Ownable {
    using SafeERC20 for IERC20;

    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private _callers;
    EnumerableSet.AddressSet private _stableCoins; // all stable coins must have a pair with USDT
    address public _owner;

    address public factory;
    address public router;
    address public feeTo;
    address public USDT;
    address public MCH;
    address public investor;
    address public nftBonus;
    address public destroyAddress;
    address public emergencyAddress;

    uint256 public nftBonusRatio;
    uint256 public investorRatio;
    uint256 public totalFee;
    uint256 public nftBonusAmount;
    uint256 public totalDistributedFee;
    uint256 public totalBurnedMCH;
    uint256 public totalRepurchasedUSDT;

    struct PairInfo {
        uint256 count; // how many times the liquidity burned
        uint256 burnedLiquidity;
        address token0;
        address token1;
        uint256 amountOfToken0;
        uint256 amountOfToken1;
        uint256 amountOfUSD;
    }

    mapping(address => PairInfo) public pairs;

    event Burn(address pair, uint256 liquidity, uint256 amountA, uint256 amountB);
    event Swap(address token0, address token1, uint256 amountIn, uint256 amountOut);
    event Distribute(
        uint256 totalAmount,
        uint256 repurchasedAmount,
        uint256 teamAmount,
        uint256 nftBonusAmount,
        uint256 burnedAmount
    );
    event Repurchase(uint256 amountIn, uint256 burnedAmount);
    event NFTPoolTransfer(address nftBonus, uint256 amount);

    constructor(
        address _factory,
        address _router,
        address _feeTo,
        address _usdt,
        address _mch,
        address _destroy,
        address _initialOwner
    ) Ownable(_initialOwner) {
        factory = _factory;
        router = _router;
        feeTo = _feeTo;
        USDT = _usdt;
        MCH = _mch;
        destroyAddress = _destroy;
        _owner = _initialOwner;
    }

    function setNftBonusRatio(uint256 _ratio) public onlyOwner {
        require(_ratio > 0 && _ratio < 100, "MochaTreasury: ratio is out of range");
        nftBonusRatio = _ratio;
    }

    function setInvestorRatio(uint256 _ratio) public onlyOwner {
        require(_ratio > 0 && _ratio < 100, "MochaTreasury: ratio is out of range");
        investorRatio = _ratio;
    }

    function setEmergencyAddress(address _newAddress) public onlyOwner {
        require(_newAddress != address(0), "MochaTreasury: address is zero");
        emergencyAddress = _newAddress;
    }

    function setInvestorAddress(address _newAddress) public onlyOwner {
        require(_newAddress != address(0), "MochaTreasury: address is zero");
        investor = _newAddress;
    }

    function setNftBonusAddress(address _newAddress) public onlyOwner {
        require(_newAddress != address(0), "MochaTreasury: address is zero");
        nftBonus = _newAddress;
    }

    function _removeLiquidity(address _token0, address _token1) internal returns (uint256 amount0, uint256 amount1) {
        address pair = MochaLibrary.pairFor(factory, _token0, _token1);
        uint256 liquidity = IERC20(pair).balanceOf(feeTo);
        IMochaPair(pair).transferFrom(feeTo, pair, liquidity);
        (amount0, amount1) = IMochaPair(pair).burn(address(this));

        pairs[pair].count += 1;
        pairs[pair].burnedLiquidity = pairs[pair].burnedLiquidity + (liquidity);
        if (pairs[pair].token0 == address(0)) {
            pairs[pair].token0 = IMochaPair(pair).token0();
            pairs[pair].token1 = IMochaPair(pair).token1();
        }
        pairs[pair].amountOfToken0 = pairs[pair].amountOfToken0 + (amount0);
        pairs[pair].amountOfToken1 = pairs[pair].amountOfToken1 + (amount1);

        emit Burn(pair, liquidity, amount0, amount1);
    }

    // swap any token to stable token
    function _swap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        address _to
    ) internal returns (uint256 amountOut) {
        address pair = MochaLibrary.pairFor(factory, _tokenIn, _tokenOut);
        (uint256 reserve0, uint256 reserve1, ) = IMochaPair(pair).getReserves();

        (uint256 reserveInput, uint256 reserveOutput) =
            _tokenIn == IMochaPair(pair).token0() ? (reserve0, reserve1) : (reserve1, reserve0);
        amountOut = MochaLibrary.getAmountOut(_amountIn, reserveInput, reserveOutput);
        IERC20(_tokenIn).safeTransfer(pair, _amountIn);

        _tokenIn == IMochaPair(pair).token0()
            ? IMochaPair(pair).swap(0, amountOut, _to, new bytes(0))
            : IMochaPair(pair).swap(amountOut, 0, _to, new bytes(0));

        emit Swap(_tokenIn, _tokenOut, _amountIn, amountOut);
    }

    function swap(address _token0, address _token1) external onlyCaller {
        require(isStableCoin(_token0) || isStableCoin(_token1), "MochaTreasury: must has a stable coin");

        (address token0, address token1) = MochaLibrary.sortTokens(_token0, _token1);
        (uint256 amount0, uint256 amount1) = _removeLiquidity(token0, token1);
        address pair = MochaLibrary.pairFor(factory, token0, token1);

        uint256 amountOut;
        if (isStableCoin(token0)) {
            amountOut = _swap(token1, token0, amount1, address(this));
            if (token0 != USDT) {
                amountOut = _swap(token0, USDT, amountOut + (amount0), address(this));
            }
        } else {
            amountOut = _swap(token0, token1, amount0, address(this));
            if (token1 != USDT) {
                amountOut = _swap(token1, USDT, amountOut + (amount1), address(this));
            }
        }

        totalFee = totalFee + (amountOut);
        pairs[pair].amountOfUSD = pairs[pair].amountOfUSD + (amountOut);
    }

    function distribute(uint256 _amount) external onlyCaller {
        require(_amount < IERC20(USDT).balanceOf(address(this)), "MochaTreasury: amount exceeds balance of contract");
        uint256 _teamAmount = _amount + (investorRatio) / (100);
        uint256 _nftBonusAmount = _amount * (nftBonusRatio) / (100);
        uint256 _repurchasedAmount = _amount - (_teamAmount) - (_nftBonusAmount);
        uint256 _burnedAmount = repurchase(_repurchasedAmount);
        IERC20(USDT).safeTransfer(investor, _teamAmount);

        nftBonusAmount = nftBonusAmount + (_nftBonusAmount);
        totalDistributedFee = totalDistributedFee + (_amount);

        emit Distribute(_amount, _repurchasedAmount, _teamAmount, _nftBonusAmount, _burnedAmount);
    }

    function sendToNftPool(uint256 _amount) external onlyCaller {
        require(_amount < nftBonusAmount, "MochaTreasury: amount exceeds nft bonus amount");
        IERC20(USDT).safeTransfer(investor, _amount);
        emit NFTPoolTransfer(nftBonus, _amount);
    }

    function repurchase(uint256 _amountIn) internal returns (uint256 amountOut) {
        require(IERC20(USDT).balanceOf(address(this)) >= _amountIn, "MochaTreasury: amount is less than USDT balance");

        amountOut = _swap(USDT, MCH, _amountIn, destroyAddress);

        totalRepurchasedUSDT = totalRepurchasedUSDT + (_amountIn);
        totalBurnedMCH = totalBurnedMCH + (amountOut);
    }

    function emergencyWithdraw(address _token) public onlyOwner {
        require(IERC20(_token).balanceOf(address(this)) > 0, "MochaTreasury: insufficient contract balance");
        IERC20(_token).transfer(emergencyAddress, IERC20(_token).balanceOf(address(this)));
    }

    function addCaller(address _newCaller) public onlyOwner returns (bool) {
        require(_newCaller != address(0), "MochaTreasury: address is zero");
        return EnumerableSet.add(_callers, _newCaller);
    }

    function delCaller(address _delCaller) public onlyOwner returns (bool) {
        require(_delCaller != address(0), "MochaTreasury: address is zero");
        return EnumerableSet.remove(_callers, _delCaller);
    }

    function getCallerLength() public view returns (uint256) {
        return EnumerableSet.length(_callers);
    }

    function isCaller(address _caller) public view returns (bool) {
        return EnumerableSet.contains(_callers, _caller);
    }

    function getCaller(uint256 _index) public view returns (address) {
        require(_index <= getCallerLength() - 1, "MochaTreasury: index out of bounds");
        return EnumerableSet.at(_callers, _index);
    }

    function addStableCoin(address _token) public onlyOwner returns (bool) {
        require(_token != address(0), "MochaTreasury: address is zero");
        return EnumerableSet.add(_stableCoins, _token);
    }

    function delStableCoin(address _token) public onlyOwner returns (bool) {
        require(_token != address(0), "MochaTreasury: address is zero");
        return EnumerableSet.remove(_stableCoins, _token);
    }

    function getStableCoinLength() public view returns (uint256) {
        return EnumerableSet.length(_stableCoins);
    }

    function isStableCoin(address _token) public view returns (bool) {
        return EnumerableSet.contains(_stableCoins, _token);
    }

    function getStableCoin(uint256 _index) public view returns (address) {
        require(_index <= getStableCoinLength() - 1, "MochaTreasury: index out of bounds");
        return EnumerableSet.at(_stableCoins, _index);
    }

    modifier onlyCaller() {
        require(isCaller(msg.sender), "MochaTreasury: not the caller");
        _;
    }
}
