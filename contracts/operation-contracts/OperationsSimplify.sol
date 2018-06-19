pragma solidity ^0.4.23;

import "../validator-contracts/ImmediateSetSimplify.sol";

contract Operations {

	struct Release {
		uint32 forkBlock;
		uint8 track;
		uint24 semver;
		bool critical;
		mapping (bytes32 => bytes32) checksum;
	}

	struct Build {
		bytes32 release;
		bytes32 platform;
	}

	struct Client {
		bool isClient;
		uint index;
		mapping (bytes32 => Release) release;
		mapping (uint8 => bytes32) current;
		mapping (bytes32 => Build) build;
	}

	enum Status {
		Undecided,
		Accepted,
		Rejected
	}

	struct Fork {
		string name;
		bytes32 spec;
		bool hard;
		bool ratified;
		uint requiredCount;
		mapping (address => Status) status;
	}

	struct Transaction {
		uint requiredCount;
		mapping (address => Status) status;
		address to;
		bytes data;
		uint value;
		uint gas;
	}
	
	Validator public validator;
	uint32 public clientsRequired;
	uint32 public latestFork;
	uint32 public proposedFork;
	address public grandOwner = msg.sender;
	address[] clientOwnerList;
	
	mapping (uint32 => Fork) public fork;
	mapping (address => Client) public client;
	mapping (bytes32 => Transaction) public proxy;

	event Received(address indexed from, uint value, bytes data);
	event TransactionProposed(address indexed client, bytes32 indexed txid, address indexed to, bytes data, uint value, uint gas);
	event TransactionConfirmed(address indexed client, bytes32 indexed txid);
	event TransactionRejected(address indexed client, bytes32 indexed txid);
	event TransactionRelayed(bytes32 indexed txid, bool success);
	event ForkProposed(address indexed client, uint32 indexed number, string indexed name, bytes32 spec, bool hard);
	event ForkAcceptedBy(address indexed client, uint32 indexed number);
	event ForkRejectedBy(address indexed client, uint32 indexed number);
	event ForkRejected(uint32 indexed forkNumber);
	event ForkRatified(uint32 indexed forkNumber);
	event ReleaseAdded(address indexed client, uint32 indexed forkBlock, bytes32 release, uint8 track, uint24 semver, bool indexed critical);
	event ChecksumAdded(address indexed client, bytes32 indexed release, bytes32 indexed platform, bytes32 checksum);
	event ClientAdded(address client);
	event ClientRemoved(address indexed client);
	event ClientOwnerChanged(address indexed old, address indexed now);
	event ClientRequiredChanged(address indexed client, bool now);
	event OwnerChanged(address old, address now);

	constructor(Validator _validator) public {
	    require(_validator != address(0));
	    validator = _validator;
	    address[] memory validators = validator.getValidators();
	    for (uint i = 0; i < validators.length; i++) {
	        clientOwnerList.push(validators[i]);
	        client[validators[i]] = Client(true, i);
	        clientsRequired++;
	    }
	}
	
	function clientList() external view returns(address[]) {
	    return clientOwnerList;
	}

	function () payable public { 
	    emit Received(msg.sender, msg.value, msg.data); 
	}

	// Functions for client owners

	function proposeTransaction(bytes32 _txid, address _to, bytes _data, uint _value, uint _gas) only_client_owner only_when_no_proxy(_txid) public returns (uint txSuccess) {
		proxy[_txid] = Transaction(1, _to, _data, _value, _gas);
		proxy[_txid].status[msg.sender] = Status.Accepted;
		txSuccess = checkProxy(_txid);
		emit TransactionProposed(msg.sender, _txid, _to, _data, _value, _gas);
	}

	function confirmTransaction(bytes32 _txid) only_client_owner only_when_proxy(_txid) only_when_proxy_undecided(_txid) public returns (uint txSuccess) {
		proxy[_txid].status[msg.sender] = Status.Accepted;
		proxy[_txid].requiredCount += 1;
		txSuccess = checkProxy(_txid);
		emit TransactionConfirmed(msg.sender, _txid);
	}

	function rejectTransaction(bytes32 _txid) only_client_owner only_when_proxy(_txid) only_when_proxy_undecided(_txid) public {
		delete proxy[_txid];
		emit TransactionRejected(msg.sender, _txid);
	}

	function proposeFork(uint32 _number, string _name, bool _hard, bytes32 _spec) only_client_owner only_when_none_proposed public {
		fork[_number] = Fork(_name, _spec, _hard, false, 0);
		proposedFork = _number;
		emit ForkProposed(msg.sender, _number, _name, _spec, _hard);
	}

	function acceptFork() only_when_proposed only_undecided_client_owner public {
		fork[proposedFork].status[msg.sender] = Status.Accepted;
		emit ForkAcceptedBy(msg.sender, proposedFork);
		noteAccepted(msg.sender);
	}

	function rejectFork() only_when_proposed only_undecided_client_owner only_unratified public {
		fork[proposedFork].status[msg.sender] = Status.Rejected;
		emit ForkRejectedBy(msg.sender, proposedFork);
		noteRejected(msg.sender);
	}

	function setClientOwner(address _newOwner) only_client_owner public {
		client[msg.sender] = client[_newOwner];
		emit ClientOwnerChanged(msg.sender, _newOwner);
	}
	
	function resetClientOwner(address _oldClient, address _newClient) only_owner public {
	    client[_oldClient] = client[_newClient];
		emit ClientOwnerChanged(_oldClient, _newClient);
	}

	function addRelease(bytes32 _release, uint32 _forkBlock, uint8 _track, uint24 _semver, bool _critical) only_client_owner public {
		client[msg.sender].release[_release] = Release(_forkBlock, _track, _semver, _critical);
		client[msg.sender].current[_track] = _release;
		emit ReleaseAdded(msg.sender, _forkBlock, _release, _track, _semver, _critical);
	}

	function addChecksum(bytes32 _release, bytes32 _platform, bytes32 _checksum) only_client_owner public {
		client[msg.sender].build[_checksum] = Build(_release, _platform);
		client[msg.sender].release[_release].checksum[_platform] = _checksum;
		emit ChecksumAdded(msg.sender, _release, _platform, _checksum);
	}

	// Admin functions

	function addClient(address _client) only_client_owner public {
	    require(!client[_client].isClient);
		client[_client].index = clientOwnerList.length;
		clientOwnerList.push(_client);
		setIsClient(_client, true);
		emit ClientAdded(_client);
	}
	
	function addClient(address _client, address sender) only_sender_client_owner(sender) public {
	    require(!client[_client].isClient);
		client[_client].index = clientOwnerList.length;
		clientOwnerList.push(_client);
		setIsClient(_client, true);
		emit ClientAdded(_client);
	}

	function removeClient(address _client) only_client_owner public {
		setIsClient(_client, false);
		uint index = client[_client].index;
		address lastClient = clientOwnerList[clientOwnerList.length - 1];
		clientOwnerList[index] = lastClient;
		clientOwnerList.length--;
		client[lastClient].index = index;
		delete client[_client];
		emit ClientRemoved(_client);
	}
	
	function removeClient(address _client, address sender) only_sender_client_owner(sender) public {
		setIsClient(_client, false, sender);
		uint index = client[_client].index;
		address lastClient = clientOwnerList[clientOwnerList.length - 1];
		clientOwnerList[index] = lastClient;
		clientOwnerList.length--;
		client[lastClient].index = index;
		delete client[_client];
		emit ClientRemoved(_client);
	}

	function setIsClient(address _client, bool _isClient) only_client_owner when_changing_required(_client, _isClient) public {
		emit ClientRequiredChanged(_client, _isClient);
		client[_client].isClient = _isClient;
		clientsRequired = _isClient ? clientsRequired + 1 : (clientsRequired - 1);
		checkFork();
	}
	
	function setIsClient(address _client, bool _isClient, address sender) only_sender_client_owner(sender) when_changing_required(_client, _isClient) internal {
		emit ClientRequiredChanged(_client, _isClient);
		client[_client].isClient = _isClient;
		clientsRequired = _isClient ? clientsRequired + 1 : (clientsRequired - 1);
		checkFork();
	}

	function setOwner(address _newOwner) only_owner public {
		emit OwnerChanged(grandOwner, _newOwner);
		grandOwner = _newOwner;
	}

	// Getters

	function isLatest(address _client, bytes32 _release) constant public returns (bool) {
		return latestInTrack(_client, track(_client, _release)) == _release;
	}

	function track(address _client, bytes32 _release) constant public returns (uint8) {
		return client[_client].release[_release].track;
	}

	function latestInTrack(address _client, uint8 _track) constant public returns (bytes32) {
		return client[_client].current[_track];
	}

	function build(address _client, bytes32 _checksum) constant public returns (bytes32 o_release, bytes32 o_platform) {
		Build memory b = client[_client].build[_checksum];
		o_release = b.release;
		o_platform = b.platform;
	}

	function release(address _client, bytes32 _release) constant public returns (uint32 o_forkBlock, uint8 o_track, uint24 o_semver, bool o_critical) {
		Release memory b = client[_client].release[_release];
		o_forkBlock = b.forkBlock;
		o_track = b.track;
		o_semver = b.semver;
		o_critical = b.critical;
	}

	function checksum(address _client, bytes32 _release, bytes32 _platform) constant public returns (bytes32) {
		return client[_client].release[_release].checksum[_platform];
	}

	// Internals

	function noteAccepted(address _client) internal when_is_client(_client) {
		fork[proposedFork].requiredCount += 1;
		checkFork();
	}

	function noteRejected(address _client) internal when_is_client(_client) {
		emit ForkRejected(proposedFork);
		delete fork[proposedFork];
		proposedFork = 0;
	}

	function checkFork() internal when_have_all_required {
		emit ForkRatified(proposedFork);
		fork[proposedFork].ratified = true;
		latestFork = proposedFork;
		proposedFork = 0;
	}

	function checkProxy(bytes32 _txid) internal when_proxy_confirmed(_txid) returns (uint txSuccess) {
		Transaction memory transaction = proxy[_txid];
		uint value = transaction.value;
		uint gas = transaction.gas;
		bytes memory data = transaction.data;
		bool success = transaction.to.call.value(value).gas(gas)(data);
		emit TransactionRelayed(_txid, success);
		txSuccess = success ? 2 : 1;
		delete proxy[_txid];
	}

	// Modifiers

	modifier only_owner { 
	    require(grandOwner == msg.sender); 
	    _; 
	}
	
	modifier only_sender_client_owner(address sender) { 
	    require(msg.sender == address(validator));
	    require(client[sender].isClient); 
	    _; 
	}
	
	modifier only_client_owner { 
	    require(client[msg.sender].isClient); 
	    _; 
	}
	
	
	modifier only_ratified{ 
	    require(!fork[proposedFork].ratified); 
	    _; 
	}
	
	modifier only_unratified { 
	    require(!fork[proposedFork].ratified);
	    _; 
	}
	
	modifier only_undecided_client_owner {
		require(msg.sender != address(0));
		require(fork[proposedFork].status[msg.sender] == Status.Undecided);
		_;
	}
	
	modifier only_when_none_proposed { 
	    require(proposedFork == 0);
	    _; 
	}
	
	modifier only_when_proposed { 
	    require(bytes(fork[proposedFork].name).length != 0); 
	    _; 
	}
	
	modifier only_when_proxy(bytes32 _txid) { 
	    require(proxy[_txid].requiredCount != 0); 
	    _; 
	}
	
	modifier only_when_no_proxy(bytes32 _txid) { 
	    require(proxy[_txid].requiredCount == 0); 
	    _; 
	}
	
	modifier only_when_proxy_undecided(bytes32 _txid) { 
	    require(proxy[_txid].status[msg.sender] == Status.Undecided); 
	    _; }

	modifier when_is_client(address _client) { 
	    if (client[_client].isClient) 
	    _; 
	}
	
	modifier when_have_all_required { 
	    if (fork[proposedFork].requiredCount >= clientsRequired) 
	    _; 
	}
	
	modifier when_changing_required(address _client, bool _r) { 
	    if (client[_client].isClient != _r) 
	    _; 
	}
	
	modifier when_proxy_confirmed(bytes32 _txid) { 
	    if (proxy[_txid].requiredCount >= clientsRequired) 
	    _; 
	}
}