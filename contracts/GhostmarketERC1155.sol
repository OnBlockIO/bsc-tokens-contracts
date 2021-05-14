// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/presets/ERC1155PresetMinterPauserUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/**
 * @dev ERC1155 token with minting, burning, pause, secondary sales royalitiy functions.
 *
 */

contract GhostmarketERC1155 is
    Initializable,
    ERC1155PresetMinterPauserUpgradeable,
    ReentrancyGuardUpgradeable
{
    string public name;
    string public symbol;

    // fee multiplier
    uint256 private _ghostmarketFeeMultiplier;

    // minting fee
    uint256 private _ghostmarketMintingFee;

    //address where the transfer fees will be sent
    address payable private _ghostmarketFeeAddress;

    // struct for secondary sales fees
    struct Fee {
        address payable recipient;
        uint256 value;
    }

    // tokenId => fees array
    mapping(uint256 => Fee[]) public fees;

    // tokenId => locked content string
    mapping(uint256 => string) public _lockedContent;
    // tokenId => locked content view counter
    mapping(uint256 => uint256) private _lockedContentViewTracker;

    event SecondarySaleFees(uint256 tokenId, address recipients, uint256 bps);
    event RoyalitiesAccountChanged(uint256 tokenId, address from, address to);
    event RoyalitiesFeeValueChanged(uint256 tokenId, uint256 value);
    event GhostmarketFeeAddressChanged(address newValue);
    event GhostmarketFeeMultiplierChanged(uint256 newValue);
    event GhostmarketMintFeeChanged(uint256 newValue);
    event GhostmarketFeePaid(address sender, uint256 value);
    event LockedContentViewed(
        address msgSender,
        uint256 tokenId,
        string lockedContent
    );

    function initialize(
        string memory _name,
        string memory _symbol,
        string memory uri
    ) public virtual initializer {
        __ERC1155_init_unchained(uri);
        __ERC1155PresetMinterPauser_init_unchained(uri);
        name = _name;
        symbol = _symbol;
    }

    using CountersUpgradeable for CountersUpgradeable.Counter;

    // _tokenIdTracker to gnerate automated tocken IDs
    CountersUpgradeable.Counter private _tokenIdTracker;

    /**
     * @dev mint ERC1155 tokens with optional royalities, minting fee and locked content
     */
    function mintGhost(
        address to,
        uint256 amount,
        bytes memory data,
        Fee[] memory _fees,
        string memory lockedcontent
    ) public payable nonReentrant {
        super.mint(to, _tokenIdTracker.current(), amount, data);
        if (_fees.length > 0) {
            //fees array length should be 1 for single mint,
            require(_fees.length == 1);
            saveRoyaltyFee(_tokenIdTracker.current(), _fees[0]);
        }
        if (_ghostmarketFeeMultiplier > 0) {
            _sendMintingFee(amount);
        }
        if (
            keccak256(abi.encodePacked(lockedcontent)) !=
            keccak256(abi.encodePacked(""))
        ) {
            setLockedContent(_tokenIdTracker.current(), lockedcontent);
        }
        _tokenIdTracker.increment();
    }

    /**
     * @dev mint multiple ERC1155 tokens
     */
    function mintBatch(
        address to,
        uint256[] memory mintAmounts,
        bytes memory data,
        Fee[] memory _fees
    ) public payable nonReentrant {
        uint256[] memory tokenBatchIds = _getTokenBatchIds(mintAmounts.length);
        super.mintBatch(to, tokenBatchIds, mintAmounts, data);
        if (_fees.length > 0) {
            require(
                _fees.length <= mintAmounts.length,
                "Fees array lenght should be less than or equal to mintAmounts array lenght"
            );
            for (uint256 i = 0; i < _fees.length; i++) {
                saveRoyaltyFee(tokenBatchIds[i], _fees[i]);
            }
        }
        if (_ghostmarketFeeMultiplier > 0) {
            _sendMintingFee(calculateTotalMintAmount(mintAmounts));
        }
    }

    /**
     * @dev calculate the total token amount for batch minting
     */
    function calculateTotalMintAmount(uint256[] memory mintAmountsArray)
        public
        pure
        returns (uint256)
    {
        uint256 totalMintAmount;
        for (uint256 i = 0; i < mintAmountsArray.length; i++) {
            totalMintAmount += mintAmountsArray[i];
        }
        return totalMintAmount;
    }

    /**
     * @dev current _tokenIdTracker
     */
    function getCurrentCounter() public view returns (uint256) {
        return _tokenIdTracker.current();
    }

    /**
     * @dev get last minted token id /  _tokenIdTracker
     */
    function getLastTokenID() public view returns (uint256) {
        if (_tokenIdTracker.current() == 0) {
            return _tokenIdTracker.current();
        } else return _tokenIdTracker.current() - 1;
    }

    /**
     * @dev get multiple IDs for the batch minting process
     */
    function _getTokenBatchIds(uint256 mintAmountsLenght)
        internal
        returns (uint256[] memory)
    {
        uint256[] memory ids = new uint256[](mintAmountsLenght);
        //uint256[mintAmounts] memory ids;
        for (uint256 i = 0; i < mintAmountsLenght; i++) {
            //_tokenIdTracker.increment();
            ids[i] = getCurrentCounter();
            _tokenIdTracker.increment();
        }
        return ids;
    }

    /**
     * @dev change the "secondary sales"/royalities fee value for a specific recipient address
     */
    function updateRoyalitiesFeeValue(
        uint256 _tokenId,
        address _from,
        uint256 _value
    ) external {
        require(
            hasRole(MINTER_ROLE, _msgSender()),
            "updating fee value is not allowed by this account"
        );
        require(_value > 0, "new Fee value should be positive");
        Fee[] memory _fees = fees[_tokenId];
        for (uint256 i = 0; i < _fees.length; i++) {
            if (fees[_tokenId][i].recipient == _from) {
                fees[_tokenId][i].value = _value;
                emit RoyalitiesFeeValueChanged(_tokenId, _value);
            }
        }
    }

    /**
     * @dev change the recepient address of the "secondary sales"/royalities fee
     */
    function updateRoyalitiesAccount(
        uint256 _tokenId,
        address _from,
        address _to
    ) external {
        require(
            hasRole(MINTER_ROLE, _msgSender()),
            "updating fee recepients is not allowed by this account"
        );
        uint256 length = fees[_tokenId].length;
        for (uint256 i = 0; i < length; i++) {
            if (fees[_tokenId][i].recipient == _from) {
                fees[_tokenId][i].recipient = payable(address(uint160(_to)));
                emit RoyalitiesAccountChanged(_tokenId, _from, _to);
            }
        }
    }

    /**
     * @dev get the "secondary sales"/royalities fee recepients with the tokenId
     */
    function getRoyalitiesRecipients(uint256 _tokenId)
        public
        view
        returns (address payable[] memory)
    {
        Fee[] memory _fees = fees[_tokenId];
        address payable[] memory result = new address payable[](_fees.length);
        for (uint256 i = 0; i < _fees.length; i++) {
            result[i] = _fees[i].recipient;
        }
        return result;
    }

    /**
     * @dev get the "secondary sales"/royalities fee for the NFT id
     * fee basis points 10000 = 100%
     */
    function getRoyaltyFeeBps(uint256 _tokenId)
        public
        view
        returns (uint256[] memory)
    {
        Fee[] memory _fees = fees[_tokenId];
        uint256[] memory result = new uint256[](_fees.length);
        for (uint256 i = 0; i < _fees.length; i++) {
            result[i] = _fees[i].value;
        }
        return result;
    }

    /**
     * @dev save the "secondary sales"/royalities fee for the NFT id
     * fee basis points 10000 = 100%
     */
    function saveRoyaltyFee(uint256 _tokenId, Fee memory _fee) internal {
        require(_fee.recipient != address(0x0), "Recipient should be present");
        require(_fee.value > 0, "Fee value should be positive");
        fees[_tokenId].push(_fee);
        emit SecondarySaleFees(_tokenId, _fee.recipient, _fee.value);
    }

    /**
     * @dev send minting fee to Ghostmarket
     */
    function _sendMintingFee(uint256 nftAmount) internal {
        require(
            _ghostmarketFeeAddress != address(0),
            "Ghostmarket minting Fee Address not set"
        );
        require(
            nftAmount > 0,
            "nft minting amount should be greater then zero"
        );
        require(_ghostmarketMintingFee > 0, "Ghostmarket minting Fee is zero");
        uint256 feevalue = _calculateGhostmarketMintingFee(nftAmount);
        (bool success, ) = _ghostmarketFeeAddress.call{value: feevalue}("");
        require(success, "Transfer failed.");
        emit GhostmarketFeePaid(msg.sender, feevalue);
    }

    /**
     * @dev set the wallet address where fees will be collected
     */
    function setGhostmarketFeeAddress(address payable gmfa) public {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, _msgSender()),
            "Caller must have admin role to set minting fee address"
        );

        _ghostmarketFeeAddress = gmfa;
        emit GhostmarketFeeAddressChanged(_ghostmarketFeeAddress);
    }

    /**
     * @dev sets the transfer fee multiplier
     */
    function setGhostmarketFeeMultiplier(uint256 gmfm) public {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, _msgSender()),
            "Caller must have admin role to set minting fee percent"
        );
        _ghostmarketFeeMultiplier = gmfm;
        emit GhostmarketFeeMultiplierChanged(_ghostmarketFeeMultiplier);
    }

    /**
     * @dev sets the transfer fee
     */
    function setGhostmarketMintFee(uint256 gmmf) public {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, _msgSender()),
            "Caller must have admin role to set minting fee percent"
        );
        _ghostmarketMintingFee = gmmf;
        emit GhostmarketMintFeeChanged(_ghostmarketMintingFee);
    }

    /**
     * @return the ghostmarketFeeAddress
     */
    function ghostmarketFeeAddress() public view returns (address payable) {
        return _ghostmarketFeeAddress;
    }

    /**
     * @return the ghostmarketMintingFee.
     */
    function ghostmarketMintingFee() public view returns (uint256) {
        return _ghostmarketMintingFee;
    }

    /**
     * @return the ghostmarketFeeMultiplier.
     */
    function ghostmarketFeeMultiplier() public view returns (uint256) {
        return _ghostmarketFeeMultiplier;
    }

    /**
     * @return the calculated fee for minting a NFT.
     */
    function _calculateGhostmarketMintingFee(uint256 nftAmount)
        internal
        view
        returns (uint256)
    {
        return (_ghostmarketMintingFee * _ghostmarketFeeMultiplier) / nftAmount;
    }

    /**
     * @dev save locked content as string for a specific _tokenId.
     */
    function setLockedContent(uint256 _tokenId, string memory content)
        internal
    {
        _lockedContent[_tokenId] = content;
    }

    /**
     * @dev locked content for a NFT can be retrived only by emitting an event
     *
     * example event:
     * msgSender: 0x1a1122c2483e8f988F9a800F3A6eE316dB77e4e0 (type: address),
     * tokenId: 0 (type: uint256),
     * lockedContent: 'top secret' (type: string)
     */
    function getLockedContent(address from, uint256 _tokenId)
        public
        returns (string memory)
    {
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: caller is not owner nor approved to get locked content"
        );
        _incrementCurrentLockedContentViewTracker(_tokenId);
        emit LockedContentViewed(
            msg.sender,
            _tokenId,
            _lockedContent[_tokenId]
        );
    }

    /**
     * @dev increment locked content view tracker
     */
    function _incrementCurrentLockedContentViewTracker(uint256 _tokenId)
        private
    {
        _lockedContentViewTracker[_tokenId] =
            _lockedContentViewTracker[_tokenId] +
            1;
    }

    /**
     * @dev get the durrent locked content view tracker for specific _tokenId
     */
    function getCurrentLockedContentViewTracker(uint256 _tokenId)
        public
        view
        returns (uint256)
    {
        return _lockedContentViewTracker[_tokenId];
    }
}