// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {sGoldV2} from "./sGoldV2.sol";

contract sGoldV2Engine is ReentrancyGuard {
    error sGoldV2Engine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
    error sGoldV2Engine__NeedsMoreThanZero();
    error sGoldV2Engine__TokenNotAllowed(address token);
    error sGoldV2Engine__TransferFailed();
    error sGoldV2Engine__BreaksHealthFactor(uint256 healthFactorValue);
    error sGoldV2Engine__MintFailed();
    error sGoldV2Engine__HealthFactorOk();
    error sGoldV2Engine__HealthFactorNotImproved();

    using OracleLib for AggregatorV3Interface;

    sGoldV2 private immutable i_sGoldV2;

    address private immutable i_goldFeed;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;

    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amount) private s_sGoldV2Minted;

    address[] private s_collateralTokens;

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert sGoldV2Engine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert sGoldV2Engine__TokenNotAllowed(token);
        }
        _;
    }

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address sGoldV2Address,
        address goldFeed
    ) {
        i_goldFeed = goldFeed;
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert sGoldV2Engine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_sGoldV2 = sGoldV2(sGoldV2Address);
    }

    function depositCollateralAndMintsGoldV2(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountsGoldV2ToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintsGoldV2(amountsGoldV2ToMint);
    }

    function redeemCollateralForsGoldV2(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountsGoldV2ToBurn
    ) external moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) {
        _burnsGoldV2(amountsGoldV2ToBurn, msg.sender, msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnsGoldV2(uint256 amount) external moreThanZero(amount) {
        _burnsGoldV2(amount, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        isAllowedToken(collateral)
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert sGoldV2Engine__HealthFactorOk();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);
        _burnsGoldV2(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert sGoldV2Engine__HealthFactorNotImproved();
        }
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintsGoldV2(uint256 amountsGoldV2ToMint) public moreThanZero(amountsGoldV2ToMint) nonReentrant {
        s_sGoldV2Minted[msg.sender] += amountsGoldV2ToMint;
        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_sGoldV2.mint(msg.sender, amountsGoldV2ToMint);
        if (!minted) {
            revert sGoldV2Engine__MintFailed();
        }
    }

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert sGoldV2Engine__TransferFailed();
        }
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert sGoldV2Engine__TransferFailed();
        }
    }

    function _burnsGoldV2(uint256 amountToBurn, address onBehalfOf, address from) private {
        s_sGoldV2Minted[onBehalfOf] -= amountToBurn;
        bool success = i_sGoldV2.transferFrom(from, address(this), amountToBurn);
        if (!success) {
            revert sGoldV2Engine__TransferFailed();
        }
        i_sGoldV2.burn(amountToBurn);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalMintedInUsd, uint256 collateralValueInUsd)
    {
        uint256 totalMinted = s_sGoldV2Minted[user];
        totalMintedInUsd = getUsdAmountFromGold(totalMinted);
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalMinted, collateralValueInUsd);
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getUsdAmountFromGold(uint256 amountGoldInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(i_goldFeed);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (amountGoldInWei * uint256(price) * ADDITIONAL_FEED_PRECISION) / PRECISION;
    }

    function _calculateHealthFactor(uint256 totalMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalMinted;
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert sGoldV2Engine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function calculateHealthFactor(uint256 totalMinted, uint256 collateralValueInUsd) external pure returns (uint256) {
        return _calculateHealthFactor(totalMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getUsdValue(address token, uint256 amount) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }
}
