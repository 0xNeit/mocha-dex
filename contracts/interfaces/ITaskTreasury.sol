// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITaskTreasury {
    /// @notice Events ///
    event FundsDeposited(
        address indexed sender,
        address indexed token,
        uint256 indexed amount
    );

    event FundsWithdrawn(
        address indexed receiver,
        address indexed initiator,
        address indexed token,
        uint256 amount
    );

    /// @notice External functions ///

    function depositFunds(
        address receiver,
        address token,
        uint256 amount
    ) external payable;

    function useFunds(
        address token,
        uint256 amount,
        address user
    ) external;

    /// @notice External view functions ///

    function gelato() external view returns (address);

    function getCreditTokensByUser(address user)
        external
        view
        returns (address[] memory);

    function userTokenBalance(address user, address token)
        external
        view
        returns (uint256);
}