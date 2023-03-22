const { ethers } = require('hardhat');

const TOKEN_DECIMALS = 6;
const TOKEN_MULTIPLIER = ethers.BigNumber.from(10).pow(TOKEN_DECIMALS);

const NULL_ADDRESS = '0x0000000000000000000000000000000000000000';
const NIL_UUID = '00000000-0000-0000-0000-000000000000';
const NIL_DIGEST = '0000000000000000000000000000000000000000000000000000000000000000';

module.exports = {
    TOKEN_DECIMALS,
    TOKEN_MULTIPLIER,
    NULL_ADDRESS,
    NIL_UUID,
    NIL_DIGEST,
};
