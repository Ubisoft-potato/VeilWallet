import Foundation
import BigInt

/// Only the fixed native-currency Classic pools. Notes never enter RPC requests.
public struct PrivacyPoolClient: Sendable {
    public let rpc: RPCClient
    public init(rpc: RPCClient) { self.rpc = rpc }
    func read(_ address: String, _ signature: String, _ args: [String] = []) async throws -> Data {
        try await rpc.readContract(ContractInvocation(contract: address, signature: signature, arguments: args))
    }
    func boolean(_ address: String, _ signature: String, _ args: [String]) async throws -> Bool {
        let n = try ContractABI.uint(await read(address, signature, args))
        guard n <= 1 else { throw WalletError.invalid(L("message.the_privacy_contract_returned_an_invalid_boolean")) }; return n == 1
    }
    @discardableResult
    public func verify(_ pool: PrivacyPool) async throws -> String {
        guard PrivacyPoolCatalog.find(pool.id) == pool, rpc.chain.isEVM, rpc.chain.id == pool.chainID else { throw WalletError.invalid(L("message.privacy_pool_network_or_pinned_deployment_does_not_match")) }
        guard try await ContractABI.uint(read(pool.contract, "denomination()")) == pool.amount,
              try await ContractABI.uint(read(pool.contract, "levels()")) == 20 else { throw WalletError.invalid(L("message.pool_denomination_or_circuit_depth_differs_from_the_pinned_configuration")) }
        return try await ContractABI.address(read(pool.contract, "verifier()"))
    }
    /// A synthetic PUBLIC zero-preimage fixture checks the pinned prover before
    /// funding. Never substitute an actual note here: that would reveal linkage.
    public func verifyPublicProver(pool: PrivacyPool, runtime: PrivacyProofRuntime) async throws {
        let verifier = try await verify(pool)
        let fixture = try await runtime.publicFixtureProof()
        guard fixture.publicSignals[2] == "57005", fixture.publicSignals[3] == "0", fixture.publicSignals[4] == "0", fixture.publicSignals[5] == "0" else { throw WalletError.invalid(L("message.public_proof_self_test_inputs_do_not_match")) }
        try await verifyProof(fixture, verifier: verifier)
    }
    private func verifyProof(_ proof: PrivacyProof, verifier: String) async throws {
        guard proof.publicSignals.count == 6, (try? Data(strictHex: proof.proof).count) == 256,
              try await boolean(verifier, "verifyProof(bytes,uint256[6])", [proof.proof, ContractABI.json(proof.publicSignals)]) else { throw WalletError.invalid(L("message.the_on_chain_verifier_rejected_the_local_zero_knowledge_proof")) }
    }
    public func prepareDeposit(note: PrivacyNoteSummary, sender: String) async throws -> TransactionPreview {
        guard let pool = note.pool, note.depositHash == nil, note.withdrawalHash == nil else { throw WalletError.invalid(L("message.this_note_already_has_a_submission_record_verify_the_original")) }
        _ = try await verify(pool)
        guard try await !boolean(pool.contract, "commitments(bytes32)", [note.commitment]) else { throw WalletError.invalid(L("message.this_commitment_was_already_deposited")) }
        let intent = PrivacyTransactionIntent(kind: .deposit, noteID: note.id, poolID: pool.id, recipient: sender, commitment: note.commitment, root: nil, nullifierHash: nil, fee: 0)
        let call = try ContractInvocation(contract: pool.contract, signature: "deposit(bytes32)", arguments: [note.commitment], nativeValue: pool.amount)
        return try await rpc.prepareContract(sender: sender, invocation: call, purpose: .privacy(intent, call))
    }
    public func prepareWithdrawal(note: PrivacyNoteSummary, proof: PrivacyProof, sender: String) async throws -> TransactionPreview {
        guard let pool = note.pool, note.withdrawalHash == nil, proof.commitment == note.commitment,
              proof.publicSignals.count == 6, proof.publicSignals[0] == String(BigUInt(try Data(strictHex: proof.root))), proof.publicSignals[1] == String(BigUInt(try Data(strictHex: proof.nullifierHash))), proof.publicSignals[2] == String(BigUInt(try Data(strictHex: sender))),
              proof.publicSignals[3...5].allSatisfy({ $0 == "0" }) else { throw WalletError.invalid(L("message.direct_withdrawal_recipient_must_be_the_current_signing_account_without")) }
        let intent = PrivacyTransactionIntent(kind: .withdraw, noteID: note.id, poolID: pool.id, recipient: sender, commitment: note.commitment, root: proof.root, nullifierHash: proof.nullifierHash, fee: 0)
        let call = try ContractInvocation(contract: pool.contract, signature: "withdraw(bytes,bytes32,bytes32,address,address,uint256,uint256)", arguments: [proof.proof, proof.root, proof.nullifierHash, sender, Self.zero, "0", "0"])
        try await revalidate(intent, call: call, sender: sender)
        return try await rpc.prepareContract(sender: sender, invocation: call, purpose: .privacy(intent, call))
    }
    static let zero = "0x0000000000000000000000000000000000000000"
    func revalidate(_ intent: PrivacyTransactionIntent, call: ContractInvocation, sender: String) async throws {
        guard let pool = PrivacyPoolCatalog.find(intent.poolID), intent.recipient.lowercased() == sender.lowercased(), call.contract.lowercased() == pool.contract.lowercased(), intent.fee == 0 else { throw WalletError.invalid(L("message.privacy_transaction_differs_from_the_approved_account_or_pool")) }
        let verifier = try await verify(pool)
        if intent.kind == .deposit {
            let expected = try ContractInvocation(contract: pool.contract, signature: "deposit(bytes32)", arguments: [intent.commitment], nativeValue: pool.amount)
            guard call == expected, try await !boolean(pool.contract, "commitments(bytes32)", [intent.commitment]) else { throw WalletError.invalid(L("message.deposit_calldata_or_commitment_state_changed")) }
        } else {
            guard let root = intent.root, let nullifier = intent.nullifierHash, call.arguments.count == 7 else { throw WalletError.invalid(L("message.withdrawal_public_inputs_missing")) }
            let expected = try ContractInvocation(contract: pool.contract, signature: "withdraw(bytes,bytes32,bytes32,address,address,uint256,uint256)", arguments: [call.arguments[0], root, nullifier, sender, Self.zero, "0", "0"])
            guard call == expected, (try? Data(strictHex: call.arguments[0]).count) == 256,
                  try await boolean(pool.contract, "isKnownRoot(bytes32)", [root]),
                  try await !boolean(pool.contract, "isSpent(bytes32)", [nullifier]) else { throw WalletError.invalid(L("message.the_withdrawal_root_expired_the_note_was_spent_or_calldata")) }
            let signals = try [root, nullifier, sender].map { String(BigUInt(try Data(strictHex: $0))) } + ["0", "0", "0"]
            let proof = PrivacyProof(commitment: intent.commitment, nullifierHash: nullifier, root: root, proof: call.arguments[0], publicSignals: signals)
            try await verifyProof(proof, verifier: verifier)
        }
    }
}
