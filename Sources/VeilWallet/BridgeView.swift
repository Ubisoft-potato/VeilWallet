import SwiftUI
import WalletCore
import BigInt

extension AppModel {
    func bridgeClient() -> BridgeClient { BridgeClient(transport: TorTransport(gate: gate), chains: local.chains, isolation: isolationKey, noncePolicy: EVMNoncePolicy(activities: local.activities)) }
    func checkBridge(_ activity: Activity, destinationHash: String) async throws {
        guard ready, let record = activity.bridge else { throw WalletError.networkBlocked }
        let selectedWallet = walletID, selectedChain = chainID
        let operation = epoch; busy = true; defer { if operation == epoch { busy = false } }
        let result = try await bridgeClient().status(record: record, sourceHash: activity.effectiveHash, destinationHash: destinationHash.isEmpty ? nil : destinationHash)
        guard unlocked, walletID == selectedWallet, chainID == selectedChain, let index = local.activities.firstIndex(where: { $0.id == activity.id }) else { return }
        local.activities[index].bridge = result.record; local.activities[index].status = result.label; try await saveLocal()
    }
}
struct BridgeQuoteDetails: View {
    let quote: BridgeQuote
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReviewDetail(L("message.bridge_protocol"), quote.source.bridgeProtocol.name)
            ReviewDetail(L("message.pay_usdt"), Ethereum.formatUnits(quote.amount, decimals: quote.source.decimals, precision: 18))
            ReviewDetail(L("message.destination_recipient"), quote.recipient)
            ReviewDetail(L("message.estimated_usdt_received"), Ethereum.formatUnits(quote.expectedDestination, decimals: quote.destination.decimals, precision: 18))
            ReviewDetail(quote.absoluteMinimumEnforced ? L("message.on_chain_minimum_usdt_received") : L("message.minimum_estimate_at_current_rates_usdt"), Ethereum.formatUnits(quote.minimumDestination, decimals: quote.destination.decimals, precision: 18))
            if !quote.absoluteMinimumEnforced { Text(L("message.allbridge_enforces_a_slippage_ratio_administrator_fee_changes_can_alter")).font(.system(size: 11)).foregroundStyle(.orange) }
            ReviewDetail(L("message.message_fee") + quote.source.nativeSymbol, Ethereum.formatUnits(quote.nativeFee, decimals: quote.source.nativeDecimals, precision: 18))
            ReviewDetail(L("message.source_bridge_contract_spender"), quote.source.contract)
            ReviewDetail(L("message.source_destination_token"), quote.source.tokenAddress + " → " + quote.destination.tokenAddress)
        }
    }
}
struct BridgeView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var sourceID = ""
    @ViewState private var recipient = ""
    @ViewState private var amount = ""
    @ViewState private var slippage = "50"
    @ViewState private var quote: BridgeQuote?
    @ViewState private var approval = false
    @ViewState private var plan: BridgeTransactionPlan?
    @ViewState private var error: String?
    @ViewState private var busy = false
    @ViewState private var task: Task<Void, Never>?
    private var destination: BridgeDeployment? { BridgeCatalog.find(sourceID).flatMap { BridgeCatalog.destinations(for: $0).first } }
    var body: some View {
        SheetFrame(title: L("message.bridge_usdt"), subtitle: model.chain.name + L("message.fixed_deployments_local_encoding_quotes_and_broadcast_through_tor")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(L("message.direct_route"), selection: $sourceID) {
                        ForEach(BridgeCatalog.on(model.chainID)) { source in Text(source.bridgeProtocol.name).tag(source.id) }
                    }.disabled(busy)
                    if let destination { Text(L("message.destination_network") + (model.local.chains.first { $0.id == destination.networkID }?.name ?? String(destination.networkID))).font(.headline) }
                    if BridgeCatalog.find(sourceID)?.isTestnet == true {
                        Text(L("bridge.testnet_delivery_unverified")).font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    FieldLabel(title: L("message.full_receiving_address_on_the_destination_network")) { TextField(destination?.networkID == TronAddress.chainID ? "T…" : "0x…", text: $recipient).disabled(busy) }
                    Button(L("message.use_this_wallet_s_destination_chain_account")) { if let destination, let chain = model.local.chains.first(where: { $0.id == destination.networkID }), let account = model.wallet?.accounts(on: chain).first { recipient = account.networkAddress } }.disabled(busy)
                    FieldLabel(title: L("message.amount_to_pay_usdt")) { TextField("0.00", text: $amount).disabled(busy) }
                    FieldLabel(title: L("message.slippage_in_basis_points_50_0_5_range_1_1000")) { TextField("50", text: $slippage).disabled(busy) }
                    Text(L("message.eth_tron_uses_allbridge_oft_eth_bsc_uses_stargate_v2")).font(.system(size: 11)).foregroundStyle(.secondary)
                    if let quote { Panel(padding: 16) { BridgeQuoteDetails(quote: quote) } }
                    if approval { Text(L("message.sign_an_exact_amount_approval_first_reset_an_insufficient_nonzero")).font(.system(size: 11)).foregroundStyle(.orange) }
                    ErrorText(text: error)
                    HStack {
                        Button(L("message.on_chain_quote")) { perform(0) }.disabled(busy || !model.ready)
                        Spacer()
                        if busy { Button(L("action.cancel")) { task?.cancel() }; ProgressView().controlSize(.small) }
                        Button(approval ? L("message.preview_approval") : L("message.preview_bridge")) { perform(approval ? 1 : 2) }.buttonStyle(PrimaryButton()).disabled(busy || !model.ready || quote == nil || model.wallet?.canSign != true)
                    }
                }
            }.frame(height: 590)
        }.onAppear { sourceID = BridgeCatalog.on(model.chainID).first?.id ?? "" }
            .onChange(of: sourceID) { _, _ in quote = nil; recipient = "" }
            .onChange(of: recipient) { _, _ in quote = nil }.onChange(of: amount) { _, _ in quote = nil }.onChange(of: slippage) { _, _ in quote = nil }
            .onChange(of: model.walletID) { _, _ in task?.cancel(); quote = nil }
            .onChange(of: model.chainID) { _, _ in
                task?.cancel(); quote = nil; approval = false
                sourceID = BridgeCatalog.on(model.chainID).first?.id ?? ""
                recipient = ""
            }
            .onDisappear { task?.cancel() }
            .sheet(isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil; quote = nil } })) {
                if let plan { switch plan { case .evm(let preview): EVMReviewView(preview: preview).environmentObject(model); case .tron(let native): TronTransactionReviewView(plan: native).environmentObject(model) } }
            }
    }
    private func perform(_ stage: Int) {
        guard let sender = model.address, let destination, BridgeCatalog.find(sourceID)?.networkID == model.chainID else { return }
        let wallet = model.walletID, chain = model.chainID, client = model.bridgeClient()
        busy = true; error = nil
        task = Task {
            defer { busy = false }
            do {
                if stage == 0 {
                    guard let bp = UInt32(slippage) else { throw WalletError.invalid(L("message.slippage_must_be_an_integer_number_of_basis_points")) }
                    let result = try await client.quote(sourceID: sourceID, destinationID: destination.id, sender: sender, recipient: recipient, amount: amount, slippageBP: bp)
                    let needs = try await client.needsApproval(result)
                    guard !Task.isCancelled, model.ready, wallet == model.walletID, chain == model.chainID else { return }; quote = result; approval = needs
                } else if let quote {
                    let result = try await (stage == 1 ? client.prepareApproval(quote) : client.prepareTransfer(quote))
                    guard !Task.isCancelled, model.ready, wallet == model.walletID, chain == model.chainID else { return }; plan = result
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
struct BridgeActivityView: View {
    let activity: Activity
    @EnvironmentObject private var model: AppModel
    @ViewState private var destinationHash = ""
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let bridge = activity.bridge {
                ReviewDetail(L("message.destination_recipient"), bridge.recipient)
                if let guid = bridge.guid { ReviewDetail(L("message.bridge_guid"), guid) }
                if let hash = bridge.destinationHash { ReviewDetail(L("message.destination_transaction_hash"), hash) }
                FieldLabel(title: L("message.destination_transaction_hash_leave_blank_to_verify_only_the_source")) { TextField(L("message.when_provided_the_destination_rpc_verifies_the_guid_recipient_and"), text: $destinationHash) }
                Button(L("message.verify_bridge_receipt_through_tor")) { Task { do { try await model.checkBridge(activity, destinationHash: destinationHash) } catch { self.error = error.localizedDescription } } }.disabled(!model.ready)
                Text(L("message.source_confirmation_does_not_prove_destination_receipt_this_version_does")).font(.system(size: 10)).foregroundStyle(.secondary)
                ErrorText(text: error)
            }
        }
    }
}
