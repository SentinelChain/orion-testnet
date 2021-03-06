pragma solidity 0.4.24;

import "openzeppelin-solidity/contracts/token/ERC20/BurnableToken.sol";
import "openzeppelin-solidity/contracts/token/ERC20/MintableToken.sol";
import "openzeppelin-solidity/contracts/token/ERC20/DetailedERC20.sol";
import "../shared/ERC677/IBurnableMintableERC677Token.sol";
import "../shared/ERC677/ERC677Receiver.sol";
import "../shared/IWhitelist.sol";
import "./SeniTokenConfig.sol";


contract SeniToken is
    IBurnableMintableERC677Token,
    DetailedERC20,
    BurnableToken,
    MintableToken,
    SeniTokenConfig {

    address public bridgeContract;
    IWhitelist public whitelist;

    event ContractFallbackCallFailed(address from, address to, uint value);

    modifier validRecipient(address _recipient) {
        require(_recipient != address(0));
        require(_recipient != address(this));
        _;
    }

    modifier isWhitelisted(address _addr) {
        require(whitelist.isWhitelisted(_addr));
        _;
    }

    constructor(IWhitelist _whitelistContract)
        public
        DetailedERC20(NAME, SYMBOL, DECIMALS)
    {
        require(_whitelistContract != address(0));
        whitelist = _whitelistContract;
    }

    function transferAndCall(address _to, uint _value, bytes _data)
        external
        validRecipient(_to)
        returns (bool)
    {
        require(_superTransfer(_to, _value));
        emit Transfer(msg.sender, _to, _value, _data);

        if (_isContract(_to)) {
            require(_contractFallback(_to, _value, _data));
        }
        return true;
    }

    function setBridgeContract(address _bridgeContract) public onlyOwner {
        require(_bridgeContract != address(0) && _isContract(_bridgeContract));
        bridgeContract = _bridgeContract;
    }

    function setWhitelistContract(IWhitelist _whitelistContract)
        public
        onlyOwner
    {
        require(
            _whitelistContract != address(0) && _isContract(_whitelistContract)
        );
        whitelist = _whitelistContract;
    }

    function transfer(address _to, uint256 _value) public returns (bool)
    {
        require(_superTransfer(_to, _value));
        if (_isContract(_to) && !_contractFallback(_to, _value, new bytes(0))) {
            if (_to == bridgeContract) {
                revert();
            } else {
                emit ContractFallbackCallFailed(msg.sender, _to, _value);
            }
        }
        return true;
    }

    function claimTokens(address _token, address _to) public onlyOwner {
        require(_to != address(0));
        if (_token == address(0)) {
            _to.transfer(address(this).balance);
            return;
        }

        DetailedERC20 token = DetailedERC20(_token);
        uint256 balance = token.balanceOf(address(this));
        require(token.transfer(_to, balance));
    }

    function mint(address _to, uint256 _amount)
        public
        isWhitelisted(_to)
        returns (bool)
    {
        return super.mint(_to, _amount);
    }

    function finishMinting() public returns (bool) {
        revert();
    }

    function renounceOwnership() public onlyOwner {
        revert();
    }

    function transferFrom(address _from, address _to, uint256 _value)
        public
        isWhitelisted(_to)
        returns (bool)
    {
        super.transferFrom(_from, _to, _value);
    }

    function _contractFallback(address _to, uint _value, bytes _data)
        internal
        returns(bool)
    {
        return _to.call(
            abi.encodeWithSignature(
                "onTokenTransfer(address,uint256,bytes)",
                msg.sender,
                _value,
                _data
            )
        );
    }

    function _isContract(address _addr)
        internal
        view
        returns (bool)
    {
        uint length;
        assembly { length := extcodesize(_addr) }
        return length > 0;
    }

    function _superTransfer(address _to, uint256 _value)
        internal
        isWhitelisted(_to)
        returns(bool)
    {
        return super.transfer(_to, _value);
    }
}
