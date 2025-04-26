// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract sGoldV2 is ERC20Burnable, Ownable {
    error sGoldV2__AmountMustBeMoreThanZero();
    error sGoldV2__BurnAmountExceedsBalance();
    error sGoldV2__NotZeroAddress();

    constructor() ERC20("sGoldV2", "sGV2") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert sGoldV2__AmountMustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert sGoldV2__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert sGoldV2__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert sGoldV2__AmountMustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
