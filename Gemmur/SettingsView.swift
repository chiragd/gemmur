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

    var body: some View {
        SectionHeader("Inference backend")

        SettingsRow(label: "Backend") {
            Picker("", selection: $settings.inferenceBackend) {
                ForEach(InferenceBackend.allCases) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .labelsHidden()
            .frame(width: 240)
        }

        SettingsRow(label: "Voice model") {
            HStack(spacing: 6) {
                Picker("", selection: $settings.whisperModel) {
                    ForEach(WhisperModel.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
                whisperStateView
            }
        }

        if settings.inferenceBackend.usesMLX {
            SettingsRow(label: settings.inferenceBackend == .aiOnly ? "AI model" : "AI rewrite model") {
                HStack(spacing: 6) {
                    Picker("", selection: $settings.aiModel) {
                        ForEach(AIModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                    aiModelStateView
                }
            }

            let hint = settings.inferenceBackend == .voiceAndAI
                ? "AI rewrite model used for Cleaned up, Formal, and Casual tones."
                : "AI model runs after voice transcription for every tone."
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var whisperStateView: some View {
        switch settings.whisperModelState {
        case .notLoaded:
            EmptyView()
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .failed(let err):
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.caption).lineLimit(1)
        }
    }

    @ViewBuilder
    private var aiModelStateView: some View {
        switch settings.aiModelState {
        case .notLoaded:
            EmptyView()
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .failed(let err):
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.caption).lineLimit(1)
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
