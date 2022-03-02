// SPDX-FileCopyrightText: 2021 Lido <info@lido.fi>

// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.7.0;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract ERC721Mock is ERC721 {
    constructor() ERC721("Mock NFT", "mNFT") {}

    function mintToken(uint256 _tokenId) public {
        _mint(msg.sender, _tokenId);
    }
}
