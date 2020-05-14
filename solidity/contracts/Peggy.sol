pragma solidity ^0.6.6;
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract Peggy {
	using SafeMath for uint256;

	// These are updated often
	bytes32 public lastCheckpoint;
	uint256 public lastTxNonce = 0;

	// These are set once at initialization
	address public tokenContract;
	bytes32 public peggyId;
	uint256 public powerThreshold;

	event LogValsetUpdated(address[] _validators, uint256[] _powers);

	// - Make a new checkpoint from the supplied validator set
	function makeCheckpoint(
		address[] memory _newValidators,
		uint256[] memory _newPowers,
		uint256 _newValsetNonce
	) public view returns (bytes32) {
		// bytes32 encoding of "checkpoint"
		bytes32 methodName = 0x636865636b706f696e7400000000000000000000000000000000000000000000;
		bytes32 newCheckpoint = keccak256(abi.encodePacked(peggyId, methodName, _newValsetNonce));

		{
			for (uint256 i = 0; i < _newValidators.length; i = i.add(1)) {
				// - Check that validator powers are decreasing or equal (this allows the next
				//   caller to break out of signature evaluation ASAP to save more gas)
				if (i != 0) {
					require(
						!(_newPowers[i] > _newPowers[i - 1]),
						"Validator power must not be higher than previous validator in batch"
					);
				}
				newCheckpoint = keccak256(
					abi.encodePacked(newCheckpoint, _newValidators[i], _newPowers[i])
				);
			}
		}

		return newCheckpoint;
	}

	// - Check that the supplied current validator set matches the saved checkpoint
	// TODO: can probably eliminate this and just use makeCheckpoint
	function checkCheckpoint(
		address[] memory _suppliedValidators,
		uint256[] memory _suppliedPowers,
		uint256 _suppliedValsetNonce
	) public view {
		// bytes32 encoding of "checkpoint"
		bytes32 methodName = 0x636865636b706f696e7400000000000000000000000000000000000000000000;
		bytes32 suppliedCheckpoint = keccak256(
			abi.encodePacked(peggyId, methodName, _suppliedValsetNonce)
		);

		for (uint256 i = 0; i < _suppliedValidators.length; i = i.add(1)) {
			suppliedCheckpoint = keccak256(
				abi.encodePacked(suppliedCheckpoint, _suppliedValidators[i], _suppliedPowers[i])
			);
		}

		require(
			suppliedCheckpoint == lastCheckpoint,
			"Supplied validators and powers do not match checkpoint."
		);
	}

	function checkValidatorSignatures(
		// The current validator set and their powers
		address[] memory _currentValidators,
		uint256[] memory _currentPowers,
		// The current validator's signatures
		uint8[] memory _v,
		bytes32[] memory _r,
		bytes32[] memory _s,
		// This is what we are checking they have signed
		bytes32 theHash
	) public view {
		uint256 cumulativePower = 0;

		for (uint256 k = 0; k < _currentValidators.length; k = k.add(1)) {
			// Check that the current validator has signed off on the hash
			require(
				_currentValidators[k] == ecrecover(theHash, _v[k], _r[k], _s[k]),
				"Current validator signature does not match."
			);

			// Sum up cumulative power
			cumulativePower = cumulativePower + _currentPowers[k];

			// Break early to avoid wasting gas
			if (cumulativePower > powerThreshold) {
				break;
			}
		}

		// Check that there was enough power
		require(
			cumulativePower > powerThreshold,
			"Submitted validator set does not have enough power."
		);
	}

	function updateValset(
		// The new version of the validator set
		address[] memory _newValidators,
		uint256[] memory _newPowers,
		uint256 _newValsetNonce,
		// The current validators that approve the change
		address[] memory _currentValidators,
		uint256[] memory _currentPowers,
		uint256 _currentValsetNonce,
		// These are arrays of the parts of the current validator's signatures
		uint8[] memory _v,
		bytes32[] memory _r,
		bytes32[] memory _s
	) public {
		// CHECKS

		// Check that new validators and powers set is well-formed
		require(_newValidators.length == _newPowers.length, "Malformed new validator set");

		// Check that current validators, powers, and signatures (v,r,s) set is well-formed
		require(
			_currentValidators.length == _currentPowers.length &&
				_currentValidators.length == _v.length &&
				_currentValidators.length == _r.length &&
				_currentValidators.length == _s.length,
			"Malformed current validator set"
		);

		// - Check that the supplied current validator set matches the saved checkpoint
		checkCheckpoint(_currentValidators, _currentPowers, _currentValsetNonce);

		// - Check that the valset nonce is incremented by one
		require(
			_newValsetNonce == _currentValsetNonce.add(1),
			"Valset nonce must be incremented by one"
		);

		// - Get hash (checkpoint) of new validator set. This hash is used for two purposes. First, it
		//   is used to check that the current validator set approves of the new one. Second,
		//   it is stored as the checkpoint and used next time to validate the valset supplied by
		//   the caller. This allows us to avoid storing all validators and saves gas.
		bytes32 newCheckpoint = makeCheckpoint(_newValidators, _newPowers, _newValsetNonce);

		// - Check that enough current validators have signed off on the new validator set
		checkValidatorSignatures(_currentValidators, _currentPowers, _v, _r, _s, newCheckpoint);

		// ACTIONS

		// Stored to be used next time by checkCheckpoint to validate that the valset
		// supplied by the caller is correct.
		lastCheckpoint = newCheckpoint;

		// LOGS

		emit LogValsetUpdated(_newValidators, _newPowers);
	}

	function submitBatch(
		// The validators that approve the batch
		address[] memory _currentValidators,
		uint256[] memory _currentPowers,
		uint256 _currentValsetNonce,
		// These are arrays of the parts of the validators signatures
		uint8[] memory _v,
		bytes32[] memory _r,
		bytes32[] memory _s,
		// The batch of transactions
		uint256[] memory _amounts,
		address[] memory _destinations,
		uint256[] memory _fees,
		uint256[] memory _nonces // TODO: multi-erc20 support (input contract address).
	) public {
		// CHECKS

		// - Check that current validators, powers, and signatures (v,r,s) set is well-formed
		require(
			_currentValidators.length == _currentPowers.length &&
				_currentValidators.length == _v.length &&
				_currentValidators.length == _r.length &&
				_currentValidators.length == _s.length,
			"Malformed current validator set"
		);

		// - Check that the transaction batch is well-formed
		require(
			_amounts.length == _destinations.length &&
				_amounts.length == _fees.length &&
				_amounts.length == _nonces.length,
			"Malformed batch of transactions"
		);

		// - Check that the supplied current validator set matches the saved checkpoint
		checkCheckpoint(_currentValidators, _currentPowers, _currentValsetNonce);

		// - Get hash of the transaction batch
		// - Check that the tx nonces are higher than the stored nonce and are
		// strictly increasing (can have gaps) TODO: Why not increasing by 1?

		// bytes32 encoding of "transactionBatch"
		bytes32 methodName = 0x7472616e73616374696f6e426174636800000000000000000000000000000000;
		bytes32 transactionsHash = keccak256(abi.encodePacked(peggyId, methodName));

		uint256 lastTxNonceTemp = lastTxNonce;
		{
			for (uint256 i = 0; i < _amounts.length; i = i.add(1)) {
				require(
					_nonces[i] > lastTxNonceTemp,
					"Transaction nonces in batch must be strictly increasing"
				);
				lastTxNonceTemp = _nonces[i];

				transactionsHash = keccak256(
					abi.encodePacked(
						transactionsHash,
						_amounts[i],
						_destinations[i],
						_fees[i],
						_nonces[i]
					)
				);
			}
		}

		// - Check that enough current validators have signed off on the transaction batch
		checkValidatorSignatures(_currentValidators, _currentPowers, _v, _r, _s, transactionsHash);

		// ACTIONS

		// Store nonce
		lastTxNonce = lastTxNonceTemp;

		// - Send transaction amounts to destinations
		// - Send transaction fees to msg.sender
		{
			for (uint256 i = 0; i < _amounts.length; i = i.add(1)) {
				IERC20(tokenContract).transfer(_destinations[i], _amounts[i]);
				IERC20(tokenContract).transfer(msg.sender, _fees[i]);
			}
		}
	}

	// TODO: we need to think this through a bit more. What needs to be in here and signed?
	constructor(
		// The token that this bridge bridges
		address _tokenContract,
		// A unique identifier for this peggy instance to use in signatures
		bytes32 _peggyId,
		// How much voting power is needed to approve operations
		uint256 _powerThreshold,
		// The validator set
		address[] memory _validators,
		uint256[] memory _powers,
		// These are arrays of the parts of the validators signatures
		bytes32[] memory _r,
		uint8[] memory _v,
		bytes32[] memory _s
	) public {
		// CHECKS

		// Check that validators, powers, and signatures (v,r,s) set is well-formed
		require(
			_validators.length == _powers.length &&
				_validators.length == _v.length &&
				_validators.length == _r.length &&
				_validators.length == _s.length,
			"Malformed current validator set"
		);

		bytes32 newCheckpoint = makeCheckpoint(_validators, _powers, 0);

		checkValidatorSignatures(
			_validators,
			_powers,
			_v,
			_r,
			_s,
			// TODO: we need to think carefully about what they sign here
			keccak256(abi.encodePacked(newCheckpoint, _tokenContract, _peggyId, _powerThreshold))
		);

		// ACTIONS

		tokenContract = _tokenContract;
		peggyId = _peggyId;
		powerThreshold = _powerThreshold;
	}
}