pragma solidity >=0.4.24;


interface ISeigniorageShares {
    function setDividendPoints(address account, uint256 totalDividends) external returns (bool);
    function setDividendPointsEuro(address account, uint256 totalDividends) external returns (bool);

    function mintShares(address account, uint256 amount) external returns (bool);

    function lastDividendPoints(address who) external view returns (uint256);
    function lastDividendPointsEuro(address who) external view returns (uint256);
    
    function externalRawBalanceOf(address who) external view returns (uint256);
    function externalTotalSupply() external view returns (uint256);

    function deleteShare(address account, uint256 amount) external;
}
