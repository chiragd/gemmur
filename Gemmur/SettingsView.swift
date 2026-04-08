import SwiftUI
import AVFoundation

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 420)
    }
}

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissions = PermissionsManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Permission banners at top — only visible when something is missing
                PermissionBanners(permissions: permissions)

                DictationSection(settings: settings)
                Divider()
                BackendSection(settings: settings)
                Divider()
                SystemSection(settings: settings)
            }
            .padding()
        }
        .onAppear {
            permissions.refreshMicStatus()
            permissions.refreshAccessibilityStatus()
        }
    }
}

// MARK: - Permission banners

private struct PermissionBanners: View {
    @ObservedObject var permissions: PermissionsManager

    var micMissing: Bool { permissions.micStatus != .authorized }
    var axMissing: Bool  { !permissions.accessibilityGranted }

    var body: some View {
        if micMissing || axMissing {
            VStack(spacing: 8) {
                if micMissing {
                    PermissionBanner(
                        icon: "mic.slash.fill",
                        title: "Microphone access required",
                        detail: "Gemmur needs microphone access to capture your speech.",
                        buttonLabel: permissions.micStatus == .notDetermined ? "Grant Access" : "Open Privacy Settings",
                        action: {
                            if permissions.micStatus == .notDetermined {
                                Task { await permissions.ensureMicrophone() }
                            } else {
                                permissions.openMicrophoneSettings()
                            }
                        }
                    )
                }

                if axMissing {
                    PermissionBanner(
                        icon: "accessibility",
                        title: "Accessibility access required",
                        detail: "Gemmur needs Accessibility access to insert text into other apps.",
                        buttonLabel: "Open Privacy Settings",
                        action: { Task { await permissions.ensureAccessibility() } }
                    )
                }
            }
        }
    }
}

private struct PermissionBanner: View {
    let icon: String
    let title: String
    let detail: String
    let buttonLabel: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(buttonLabel, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Dictation section

private struct DictationSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SectionHeader("Dictation")

        SettingsRow(label: "Push-to-talk key") {
            Picker("", selection: $settings.hotkey) {
                ForEach(HotkeyOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 200)
        }

        SettingsRow(label: "Tone") {
            Picker("", selection: $settings.tone) {
                ForEach(DictationTone.allCases) { tone in
                    Text(tone.rawValue).tag(tone)
                }
            }
            .labelsHidden()
            .frame(width: 200)
        }
    }
}

// MARK: - Backend section

private struct BackendSection: View {
    @ObservedObject var settings: AppSettings
    @State private var checkStatus: BackendCheckStatus = .idle

    enum BackendCheckStatus { case idle, checking, ok, error(String) }

    var body: some View {
        SectionHeader("Inference backend")

        SettingsRow(label: "Backend") {
            Text("Ollama (localhost:11434)")
                .foregroundStyle(.secondary)
        }

        SettingsRow(label: "Model") {
            Picker("", selection: $settings.model) {
                ForEach(OllamaModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .labelsHidden()
            .frame(width: 240)
        }

        HStack {
            Button("Check connection") {
                Task { await checkBackend() }
            }
            .controlSize(.small)

            switch checkStatus {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView().controlSize(.small)
            case .ok:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }

        Text("Run \(Image(systemName: "terminal")) ollama pull \(settings.model.rawValue) to download the model.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func checkBackend() async {
        checkStatus = .checking
        do {
            try await OllamaBackend(model: settings.model.rawValue).checkAvailability()
            checkStatus = .ok
        } catch {
            checkStatus = .error(error.localizedDescription)
        }
    }
}

// MARK: - System section

private struct SystemSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SectionHeader("System")
        Toggle("Launch at login", isOn: $settings.launchAtLogin)
    }
}

// MARK: - Shared layout helpers

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.headline)
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Text(label).frame(width: 140, alignment: .leading)
            content()
            Spacer()
        }
    }
}

// MARK: - About Tab

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            Text("Gemmur")
                .font(.title).fontWeight(.bold)

            Text("Local, privacy-first dictation powered by Gemma 4.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }
}

#Preview {
    SettingsView().frame(width: 480, height: 420)
}
