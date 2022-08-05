// struct FinalizedHeaderUpdate {
//         // The beacon block header that is attested to by the sync committee
//         BeaconBlockHeader attested_header;

//         // Next sync committee corresponding to the finalized header
//         SyncCommittee next_sync_committee;
//         bytes32[] next_sync_committee_branch;

//         // The finalized beacon block header attested to by Merkle branch
//         // BeaconBlockHeader finalized_header;
//         bytes32[] finality_branch;

//         // Sync committee aggregate signature
//         SyncAggregate sync_aggregate;

//         // Fork version for the aggregate signature
//         bytes4 fork_version;

//         // Slot at which the aggregate signature was created (untrusted)
//         uint64 signature_slot;
//     }
