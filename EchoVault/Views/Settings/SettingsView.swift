import SwiftUI

struct SettingsView: View {
    @Environment(WebDAVSettings.self) private var settings
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayer.self) private var player
    @AppStorage("interface.hapticsEnabled") private var hapticsEnabled = true

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    WebDAVConnectionView()
                } label: {
                    LabeledContent {
                        Text(settings.configuration == nil ? "Not configured" : "Connected")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("WebDAV Connection", systemImage: "externaldrive.connected.to.line.below")
                    }
                }

                if let configuration = settings.configuration {
                    LabeledContent("Server", value: configuration.rootURL.host ?? settings.endpoint)
                    if settings.allowsInsecureHTTP {
                        Label("Using unencrypted HTTP", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("WebDAV")
            } footer: {
                Text("Connect and browse from the WebDAV tab.")
            }
            .listRowBackground(EchoVaultTheme.background)

            Section("Local storage") {
                LabeledContent(
                    "Local library size",
                    value: ByteCountFormatter.string(
                        fromByteCount: library.librarySizeBytes,
                        countStyle: .file
                    )
                )
                LabeledContent("WebDAV downloads", value: "\(library.cachedTracks.count)")
                LabeledContent(
                    "WebDAV storage",
                    value: ByteCountFormatter.string(
                        fromByteCount: library.cacheSizeBytes,
                        countStyle: .file
                    )
                )
                Text(
                    "Delete individual local copies from a track’s actions menu or by swiping left in Library."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .listRowBackground(EchoVaultTheme.background)

            Section {
                Toggle(
                    "Shuffle",
                    isOn: Binding(
                        get: { player.isShuffleEnabled },
                        set: { player.isShuffleEnabled = $0 }
                    )
                )
                Toggle("Control haptics", isOn: $hapticsEnabled)
            } header: {
                Text("Playback")
            } footer: {
                Text("Shuffle, repeat mode, and haptic preferences are remembered.")
            }
            .listRowBackground(EchoVaultTheme.background)

            Section("About") {
                HStack(spacing: 14) {
                    AppLogoView(cornerRadius: 14)
                        .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("EchoVault")
                            .font(.headline)
                        Text("Version \(appVersion)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                LabeledContent("Offline playback", value: "Enabled")
            }
            .listRowBackground(EchoVaultTheme.background)
        }
        .echoVaultBlackSurface()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.view")
    }

    private var appVersion: String {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "1.0"
        let build =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "1"
        return "\(version) (\(build))"
    }
}

struct WebDAVConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WebDAVSettings.self) private var settings

    let dismissAfterConnection: Bool

    init(dismissAfterConnection: Bool = false) {
        self.dismissAfterConnection = dismissAfterConnection
    }

    var body: some View {
        WebDAVSettingsForm(settings: settings) {
            if dismissAfterConnection {
                dismiss()
            }
        }
    }
}

private enum ConnectionStatus: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
}

private struct WebDAVSettingsForm: View {
    let settings: WebDAVSettings
    let connected: () -> Void

    @State private var endpoint: String
    @State private var username: String
    @State private var password: String
    @State private var allowsInsecureHTTP: Bool
    @State private var status: ConnectionStatus = .idle

    init(settings: WebDAVSettings, connected: @escaping () -> Void) {
        self.settings = settings
        self.connected = connected
        _endpoint = State(initialValue: settings.endpoint)
        _username = State(initialValue: settings.username)
        _password = State(initialValue: settings.password)
        _allowsInsecureHTTP = State(initialValue: settings.allowsInsecureHTTP)
        _status = State(
            initialValue: settings.credentialLoadError.map(ConnectionStatus.failure) ?? .idle
        )
    }

    var body: some View {
        Form {
            Section {
                TextField("https:// or http://server.example/music/", text: $endpoint)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("WebDAV server address")

                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
                    .textContentType(.password)

                Toggle("Allow insecure HTTP", isOn: $allowsInsecureHTTP)
                    .tint(.orange)
                    .accessibilityHint(
                        "Allows unencrypted connections to HTTP WebDAV servers"
                    )

                if allowsInsecureHTTP {
                    Label(
                        "HTTP exposes credentials and music to anyone who can observe the network.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("WebDAV server")
            } footer: {
                Text(
                    "HTTPS is strongly recommended. Saved credentials remain protected in this device's Keychain."
                )
            }
            .listRowBackground(EchoVaultTheme.background)

            Section {
                Button {
                    Task {
                        await connectAndSave()
                    }
                } label: {
                    HStack {
                        Spacer()
                        if status == .testing {
                            ProgressView()
                        } else {
                            Image(systemName: "externaldrive.connected.to.line.below")
                        }
                        Text(status == .testing ? "Connecting…" : "Connect & Browse")
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(status == .testing)
                .accessibilityIdentifier("webdav.connect")

                statusView
            }
            .listRowBackground(EchoVaultTheme.background)
        }
        .echoVaultBlackSurface()
        .navigationTitle("WebDAV Connection")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .disabled(status == .testing)
        .accessibilityIdentifier("webdav.connection.form")
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            HStack {
                ProgressView()
                Text("Testing connection…")
                    .foregroundStyle(.secondary)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label {
                Text(message)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func connectAndSave() async {
        status = .testing
        do {
            let configuration = try WebDAVConfiguration(
                endpoint: endpoint,
                username: username,
                password: password,
                allowsInsecureHTTP: allowsInsecureHTTP
            )
            try await WebDAVClient(configuration: configuration).checkConnection()
            try Task.checkCancellation()
            try settings.save(
                endpoint: endpoint,
                username: username,
                password: password,
                allowsInsecureHTTP: allowsInsecureHTTP
            )
            endpoint = settings.endpoint
            allowsInsecureHTTP = settings.allowsInsecureHTTP
            status = .success("Connected. Your music is ready to browse.")
            connected()
        } catch is CancellationError {
            return
        } catch {
            status = .failure(WebDAVConnectionErrorMessage.message(for: error))
        }
    }
}

#Preview("Settings") {
    let library = MusicLibrary()
    NavigationStack {
        SettingsView()
    }
    .environment(WebDAVSettings())
    .environment(library)
    .environment(AudioPlayer())
}
