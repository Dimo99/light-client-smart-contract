// SPDX-License-Identifier: MIT
// Etherum beacon light client.
// Current arthitecture diverges from spec's proposed updated splitting them into:
// - Finalized header updates: To import a recent finalized header signed by a known sync committee by `import_finalized_header`.
// - Sync period updates: To advance to the next committee by `import_next_sync_committee`.
//
// To stay synced to the current sync period it needs:
// - Get finalized_header_update and sync_period_update at least once per period.
//
// To get light-client best finalized update at period N:
// - Fetch best finalized block's sync_aggregate_header in period N
// - Fetch parent_block/attested_block by sync_aggregate_header's parent_root
// - Fetch finalized_checkpoint_root and finalized_checkpoint_root_witness in attested_block
// - Fetch finalized_header by finalized_checkpoint_root
//
// - sync_aggregate -> parent_block/attested_block -> finalized_checkpoint -> finalized_header
//
// To get light-client sync period update at period N:
// - Fetch the finalized_header in light-client
// - Fetch the finalized_block by finalized_header.slot
// - Fetch next_sync_committee and next_sync_committee_witness in finalized_block
//
// - finalized_header -> next_sync_committee
//
// ```
//                       Finalized               Block   Sync
//                       Checkpoint              Header  Aggreate
// ----------------------|-----------------------|-------|---------> time
//                        <---------------------   <----
//                         finalizes               signs
// ```
//
// To initialize, it needs:
// - BLS verify contract
// - Trust finalized_header
// - current_sync_committee of the trust finalized_header
// - genesis_validators_root of genesis state
//
// When to trigger a committee update sync:
//
//  period 0         period 1         period 2
// -|----------------|----------------|----------------|-> time
//              | now
//               - active current_sync_committee
//               - known next_sync_committee, signed by current_sync_committee
//
//
// next_sync_committee can be imported at any time of the period, not strictly at the period borders.
// - No need to query for period 0 next_sync_committee until the end of period 0
// - After the import next_sync_committee of period 0, populate period 1's committee

pragma solidity 0.8.9;

import "./Bitfield.sol";
import "./BeaconChain.sol";

interface IBLS {
    function fast_aggregate_verify(
        bytes[] calldata pubkeys,
        bytes calldata message,
        bytes calldata signature
    ) external pure returns (bool);
}

contract BeaconLightClient is BeaconChain, Bitfield {
    // address(0x0800)
    address private immutable BLS_PRECOMPILE;

    bytes32 public immutable GENESIS_VALIDATORS_ROOT;

    // A bellatrix beacon state has 25 fields, with a depth of 5.
    // | field                               | gindex | depth |
    // | ----------------------------------- | ------ | ----- |
    // | next_sync_committee                 | 55     | 5     |
    // | finalized_checkpoint_root           | 105    | 6     |
    uint64 constant private NEXT_SYNC_COMMITTEE_INDEX = 55;
    uint64 constant private NEXT_SYNC_COMMITTEE_DEPTH = 5;

    uint64 constant private FINALIZED_CHECKPOINT_ROOT_INDEX = 105;
    uint64 constant private FINALIZED_CHECKPOINT_ROOT_DEPTH = 6;

    uint64 constant private EPOCHS_PER_SYNC_COMMITTEE_PERIOD = 256;
    uint64 constant private SLOTS_PER_EPOCH = 32;

    bytes4 constant private DOMAIN_SYNC_COMMITTEE = 0x07000000;

    struct SyncAggregate {
        bytes32[2] sync_committee_bits;
        bytes sync_committee_signature;
    }

    struct FinalizedHeaderUpdate {
        // The beacon block header that is attested to by the sync committee
        BeaconBlockHeader attested_header;

        // Next sync committee corresponding to the finalized header
        SyncCommittee next_sync_committee;
        bytes32[] next_sync_committee_branch;

        // The finalized beacon block header attested to by Merkle branch
        BeaconBlockHeader finalized_header;
        bytes32[] finality_branch;

        // Sync committee aggregate signature
        SyncAggregate sync_aggregate;

        // Fork version for the aggregate signature
        bytes4 fork_version;

        // Slot at which the aggregate signature was created (untrusted)
        uint64 signature_slot;
    }

    // Beacon block header that is finalized
    BeaconBlockHeader public finalized_header;

    // Execution payload state root of finalized header
    bytes32 public latest_execution_payload_state_root;

    SyncCommittee public prev_sync_committee;

    constructor(
        address _bls,
        uint64 _slot,
        uint64 _proposer_index,
        bytes32 _parent_root,
        bytes32 _state_root,
        bytes32 _body_root,
        bytes[SYNC_COMMITTEE_SIZE] memory _pubkeys,
        bytes memory _aggregate_pubkey,
        bytes32 _genesis_validators_root
    ) {
        BLS_PRECOMPILE = _bls;
        finalized_header = BeaconBlockHeader(_slot, _proposer_index, _parent_root, _state_root, _body_root);
        prev_sync_committee = SyncCommittee(_pubkeys, _aggregate_pubkey);
        GENESIS_VALIDATORS_ROOT = _genesis_validators_root;
    }

    function state_root() public view returns (bytes32) {
        return finalized_header.state_root;
    }

    function light_client_update(FinalizedHeaderUpdate calldata update) external {
        require(is_supermajority(update.sync_aggregate.sync_committee_bits), "!supermajor");

        require(
            verify_signed_header(
            update.sync_aggregate,
            prev_sync_committee,
            update.fork_version,
            update.attested_header),
            "!sign");

        require(
            verify_finalized_header(
            update.finalized_header,
            update.finality_branch,
            update.attested_header.state_root),
            "!finalized_header"
        );

        uint64 finalized_period = compute_sync_committee_period(finalized_header.slot);
        uint64 signature_period = compute_sync_committee_period(update.signature_slot);
        require(
            signature_period == finalized_period ||
            signature_period == finalized_period + 1,
            "!signature_period");

        require(
            verify_next_sync_committee(
            update.next_sync_committee,
            update.next_sync_committee_branch,
            update.attested_header.state_root),
            "!next_sync_committee"
        );

        prev_sync_committee = update.next_sync_committee;
        finalized_header = update.finalized_header;
    }

    function verify_signed_header(
        SyncAggregate calldata sync_aggregate,
        SyncCommittee storage sync_committee,
        bytes4 fork_version,
        BeaconBlockHeader calldata header
    ) internal view returns (bool) {
        // Verify sync committee aggregate signature
        uint participants = sum(sync_aggregate.sync_committee_bits);
        bytes[] memory participant_pubkeys = new bytes[](participants);
        uint64 n = 0;
        for (uint64 i = 0; i < SYNC_COMMITTEE_SIZE; ++i) {
            uint index = i >> 8;
            uint sindex = i / 8 % 32;
            uint offset = i % 8;
            if (uint8(sync_aggregate.sync_committee_bits[index][sindex]) >> offset & 1 == 1) {
                participant_pubkeys[n++] = sync_committee.pubkeys[i];
            }
        }

        bytes32 domain = compute_domain(DOMAIN_SYNC_COMMITTEE, fork_version, GENESIS_VALIDATORS_ROOT);
        bytes32 signing_root = compute_signing_root(header, domain);
        bytes memory message = abi.encodePacked(signing_root);
        bytes memory signature = sync_aggregate.sync_committee_signature;
        require(signature.length == BLSSIGNATURE_LENGTH, "!signature");
        return fast_aggregate_verify(participant_pubkeys, message, signature);
    }

    function verify_finalized_header(
        BeaconBlockHeader calldata header,
        bytes32[] calldata finality_branch,
        bytes32 attested_header_root
    ) internal pure returns (bool) {
        require(finality_branch.length == FINALIZED_CHECKPOINT_ROOT_DEPTH, "!finality_branch");
        bytes32 header_root = hash_tree_root(header);
        return is_valid_merkle_branch(
            header_root,
            finality_branch,
            FINALIZED_CHECKPOINT_ROOT_DEPTH,
            FINALIZED_CHECKPOINT_ROOT_INDEX,
            attested_header_root
        );
    }

    function verify_next_sync_committee(
        SyncCommittee calldata next_sync_committee,
        bytes32[] calldata next_sync_committee_branch,
        bytes32 header_state_root
    ) internal pure returns (bool) {
        require(next_sync_committee_branch.length == NEXT_SYNC_COMMITTEE_DEPTH, "!next_sync_committee_branch");
        bytes32 next_sync_committee_root = hash_tree_root(next_sync_committee);
        return is_valid_merkle_branch(
            next_sync_committee_root,
            next_sync_committee_branch,
            NEXT_SYNC_COMMITTEE_DEPTH,
            NEXT_SYNC_COMMITTEE_INDEX,
            header_state_root
        );
    }

    function is_supermajority(bytes32[2] calldata sync_committee_bits) internal pure returns (bool) {
        return sum(sync_committee_bits) * 3 >= SYNC_COMMITTEE_SIZE * 2;
    }

    function fast_aggregate_verify(bytes[] memory pubkeys, bytes memory message, bytes memory signature) internal view returns (bool valid) {
        bytes memory input = abi.encodeWithSelector(
            IBLS.fast_aggregate_verify.selector,
            pubkeys,
            message,
            signature
        );
        (bool ok, bytes memory out) = BLS_PRECOMPILE.staticcall(input);
        if (ok) {
            if (out.length == 32) {
                valid = abi.decode(out, (bool));
            }
        } else {
            if (out.length > 0) {
                assembly {
                    let returndata_size := mload(out)
                    revert(add(32, out), returndata_size)
                }
            } else {
                revert("!verify");
            }
        }
    }

    function compute_sync_committee_period(uint64 slot) internal pure returns (uint64) {
        return slot / SLOTS_PER_EPOCH / EPOCHS_PER_SYNC_COMMITTEE_PERIOD;
    }

    function sum(bytes32[2] memory x) internal pure returns (uint256) {
        uint256[] memory arr = new uint256[](2);
        arr[0] = uint256(x[0]);
        arr[1] = uint256(x[1]);

        return countSetBits(arr);
    }
}
