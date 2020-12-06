pragma solidity >=0.4.24;


interface IReserve {
    function buyReserveAndTransfer(uint256 mintAmount) external;
}
