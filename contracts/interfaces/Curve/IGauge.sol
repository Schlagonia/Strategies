//SPDX-License-Identifier: Unlicense
pragma solidity ^0.6.12;


interface IGauge {

    function deposit(uint256) external;

    function balanceOf(address) external view returns (uint256);

    function withdraw(uint256 _value) external; // _claim_rewards=False
    function withdraw(uint256 _value, bool _claim_rewards) external;

    function claim_rewards() external;

    function claimable_reward(
        address _owner,
        address _token
    ) external view returns (uint256 _claimable);

    function claimable_reward_write(address _addr, address _token) external returns (uint256);
}
