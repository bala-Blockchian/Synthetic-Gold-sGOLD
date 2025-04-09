## Overview

sGOLD is an ERC20-compatible synthetic asset pegged to the price of gold. Users deposit ETH as collateral to mint sGOLD tokens. The protocol uses Chainlink price feeds to determine asset values and implements collateral management logic to ensure responsible issuance.

## Features

- Synthetic gold token minting using ETH as collateral
- Oracle-based pricing via Chainlink (ETH/USD and XAU/USD)
- Collateral ratio enforcement
- Health factor calculations for risk management
- Liquidation mechanism (in progress)

## Technical Details

- Solidity: ^0.8.13
- Chainlink Oracles for ETH and Gold prices
- ERC20 standard (OpenZeppelin)
- Foundry development and test framework


## Collateralization Logic

- Collateral: ETH
- Minted Token: sGOLD (pegged to Gold price in USD)
- Minimum Health Factor: 1.0
- Liquidation Threshold: 50%
- Pricing Oracles: Chainlink


