import SwiftUI
import TgWsProxyCore

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @ObservedObject private var log = AppLog.shared
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    actions
                    if vm.showSettings {
                        settings
                    }
                    backgroundNote
                    cfRow
                    logs
                }
                .padding()
            }
            .navigationTitle("TgWsProxy")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(vm.showSettings ? "Hide" : "Settings") {
                        if !vm.running {
                            vm.syncDraftFromStore()
                        }
                        vm.showSettings.toggle()
                    }
                }
            }
            .sheet(isPresented: $vm.showFirstRun) {
                firstRunSheet
            }
            .sheet(isPresented: $showShare) {
                if let url = vm.shareURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(vm.running ? "Running" : "Stopped")
                .font(.title2.bold())
                .foregroundStyle(vm.running ? Color.green : Color.secondary)
            Text(vm.statusLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(storeLink)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private var storeLink: String {
        vm.store.config.proxyLink()
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(vm.running ? "Stop" : "Start") {
                vm.toggle()
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.running ? .red : .blue)
            .frame(maxWidth: .infinity)

            HStack {
                Button("Copy link") { vm.copyLink() }
                    .buttonStyle(.bordered)
                Button("Open Telegram") { vm.openTelegram() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(.headline)
            if vm.running {
                Text("Stop the proxy to edit settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Group {
                labeledField("Port", text: $vm.draftPort)
                labeledField("Secret (32 hex)", text: $vm.draftSecret)
                labeledMultiline("DC IP (dc:ip per line)", text: $vm.draftDcIp)
                labeledField("CF workers", text: $vm.draftWorkers)
                labeledField("CF user domains", text: $vm.draftUserDomains)
                labeledField("Pool size", text: $vm.draftPoolSize)
                Toggle("CF proxy fallback", isOn: $vm.draftCfproxy)
                Toggle("Verbose logs", isOn: $vm.draftVerbose)
            }
            .disabled(vm.running)

            Button("Save settings") {
                vm.applyDraftIfStopped()
            }
            .disabled(vm.running)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var backgroundNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Background").font(.headline)
            Text("iOS may suspend the local listener when this app is not in the foreground. Keep TgWsProxy open while using Telegram. No VPN / Packet Tunnel in this build.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cfRow: some View {
        HStack {
            Button("Refresh CF") {
                Task { await vm.refreshCF() }
            }
            .buttonStyle(.bordered)
            Text(vm.cfStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Logs").font(.headline)
                Spacer()
                Button("Clear") { vm.clearLogs() }
                Button("Share") {
                    vm.prepareShare()
                    showShare = vm.shareURL != nil
                }
            }
            ScrollView {
                Text(log.text.isEmpty ? "—" : log.text)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 220)
            .padding(8)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var firstRunSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Connect Telegram").font(.title2.bold())
                Text("1. Tap Start and keep this app open.")
                Text("2. Tap Open Telegram (or Copy link).")
                Text("3. In Telegram: Settings → Data and Storage → Proxy — enable it.")
                Text("4. Manual: server 127.0.0.1, port 1443, secret from the app (dd + 32 hex).")
                Spacer()
                Button("Got it") { vm.dismissFirstRun() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .presentationDetents([.medium])
    }

    private func labeledField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
        }
    }

    private func labeledMultiline(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .frame(minHeight: 72)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
