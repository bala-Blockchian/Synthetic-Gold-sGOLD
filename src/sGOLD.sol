// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";

/*
 * @title sGOLD - Synthetic Gold Token with ETH Collateralization
 * @author Balamurugan Nagarajan
 * @notice This contract allows users to mint synthetic gold tokens (sGOLD) by depositing ETH as collateral.
 *         It utilizes price feeds for gold and ETH/USD via Chainlink oracles to ensure proper collateralization,
 *         and includes mechanisms for health factor checks and collateral redemption.
 */
contract sGOLD is ERC20 {
    using OracleLib for AggregatorV3Interface;

    error sGOLD_feeds__InsufficientCollateral();

    address private i_goldFeed;
    address private i_ethUsdFeed;
    uint256 public constant DECIMALS = 8;
    uint256 public constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 public constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address user => uint256 goldMinted) public s_goldMintedPerUser;
    mapping(address user => uint256 ethCollateral) public s_ethCollateralPerUser;

    constructor(address goldFeed, address ethUsdFeed) ERC20("Synthetic Gold (Feeds)", "sGOLD") {
        i_goldFeed = goldFeed;
        i_ethUsdFeed = ethUsdFeed;
    }

    function depositAndMint(uint256 amountToMint) external payable {
        s_ethCollateralPerUser[msg.sender] += msg.value;
        s_goldMintedPerUser[msg.sender] += amountToMint;
        uint256 healthFactor = getHealthFactor(msg.sender);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert sGOLD_feeds__InsufficientCollateral();
        }
        _mint(msg.sender, amountToMint);
    }

    function redeemAndBurn(uint256 amountToRedeem) external {
        uint256 valueRedeemed = getUsdAmountFromGold(amountToRedeem);
        uint256 ethToReturn = getEthAmountFromUsd(valueRedeemed);
        s_goldMintedPerUser[msg.sender] -= amountToRedeem;
        s_ethCollateralPerUser[msg.sender] -= ethToReturn;
        uint256 healthFactor = getHealthFactor(msg.sender);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert sGOLD_feeds__InsufficientCollateral();
        }
        _burn(msg.sender, amountToRedeem);

        (bool success,) = msg.sender.call{value: ethToReturn}("");
        if (!success) {
            revert("sGOLD_feeds: transfer failed");
        }
    }

    function getHealthFactor(address user) public view returns (uint256) {
        (uint256 totalGoldMintedValueInUsd, uint256 totalCollateralEthValueInUsd) = getAccountInformationValue(user);
        return _calculateHealthFactor(totalGoldMintedValueInUsd, totalCollateralEthValueInUsd);
    }

    function getUsdAmountFromGold(uint256 amountGoldInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(i_goldFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (amountGoldInWei * (uint256(price) * ADDITIONAL_FEED_PRECISION)) / PRECISION;
    }

    function getUsdAmountFromEth(uint256 ethAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(i_ethUsdFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (ethAmountInWei * (uint256(price) * ADDITIONAL_FEED_PRECISION)) / PRECISION;
    }

    function getEthAmountFromUsd(uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(i_ethUsdFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / ((uint256(price) * ADDITIONAL_FEED_PRECISION) * PRECISION);
    }

    function getAccountInformationValue(address user)
        public
        view
        returns (uint256 totalGoldMintedValueUsd, uint256 totalCollateralValueUsd)
    {
        (uint256 totalGoldMinted, uint256 totalCollateralEth) = _getAccountInformation(user);
        totalGoldMintedValueUsd = getUsdAmountFromGold(totalGoldMinted);
        totalCollateralValueUsd = getUsdAmountFromEth(totalCollateralEth);
    }

    function _calculateHealthFactor(uint256 goldMintedValueUsd, uint256 collateralValueUsd)
        internal
        pure
        returns (uint256)
    {
        if (goldMintedValueUsd == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / goldMintedValueUsd;
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalGoldMinted, uint256 totalCollateralEth)
    {
        totalGoldMinted = s_goldMintedPerUser[user];
        totalCollateralEth = s_ethCollateralPerUser[user];
    }
}
