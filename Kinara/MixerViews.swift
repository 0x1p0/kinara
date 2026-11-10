import SwiftUI

// The mixer's controls: a compact section in the menu bar panel, and the
// strips Settings → Mixer lists. Monochrome, like the rest of Kinara.

extension MixerModel {
    /// Demo channels for RenderUI and previews. Never touches Core Audio.
    static let preview = MixerModel(defaults: UserDefaults(suiteName: "com.kinara.mixer-preview") ?? .standard, preview: true)
}

/// The menu bar panel's "Apps" section.
struct MixerMenuSection: View {
    @ObservedObject var mixer: MixerModel
    @AppStorage("mixerMenuExpanded") private var expanded = true
    @State private var showsOthers = false
    private static let maximumRows = 4

    // Spelled out: older Swift (Xcode 26, as on CI) makes the generated
    // initializer private when a view has private state.
    init(mixer: MixerModel) { self.mixer = mixer }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("Apps").font(.system(size: 12.5, weight: .semibold))
                    if !mixer.playingChannels.isEmpty {
                        Text("\(mixer.playingChannels.count)").font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide app volumes" : "Show app volumes")

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if mixer.permission != .authorized { MixerPermissionRow(mixer: mixer) }
                    MixerBanners(mixer: mixer)
                    let rows = mixer.playingChannels
                    if rows.isEmpty {
                        Text("Apps appear here when they play sound.").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if rows.count > Self.maximumRows {
                        ScrollView { channelList(rows) }.frame(height: CGFloat(Self.maximumRows) * 54)
                    } else {
                        channelList(rows)
                    }
                    if mixer.showOtherApps, !mixer.otherChannels.isEmpty {
                        Button { showsOthers.toggle() } label: {
                            Label(showsOthers ? "Hide other apps" : "Other apps (\(mixer.otherChannels.count))",
                                  systemImage: showsOthers ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                        if showsOthers { channelList(mixer.otherChannels) }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func channelList(_ list: [MixerChannel]) -> some View {
        VStack(spacing: 10) { ForEach(list) { MixerChannelRow(channel: $0, mixer: mixer) } }
    }
}

/// Asks for System Audio Recording, which rerouting an app's sound needs.
struct MixerPermissionRow: View {
    @ObservedObject var mixer: MixerModel
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "waveform.badge.mic").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(mixer.permission == .denied ? "Allow Kinara in Screen & System Audio Recording to change each app’s sound."
                                                 : "Kinara needs System Audio Recording to change each app’s sound. Nothing is recorded or saved.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(mixer.permission == .denied ? "Open System Settings…" : "Allow…") { mixer.requestPermission() }
                    .controlSize(.small)
            }
        }
    }
}

/// Solo and call-ducking status, each with a one-click way out.
struct MixerBanners: View {
    @ObservedObject var mixer: MixerModel
    var body: some View {
        if let solo = mixer.soloChannel {
            banner(icon: "headphones", text: "Only \(solo.name) is playing", action: "Stop") { mixer.endSolo() }
        }
        if mixer.isDucking, let caller = mixer.callers.first {
            banner(icon: "phone.fill", text: "\(caller.name) is on a call, so other apps are lower", action: "Don’t lower") { mixer.pauseDuckingForThisCall() }
        }
    }

    private func banner(icon: String, text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 11)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action, action: perform).controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// One app: icon, name and status, mute, solo, output, and its fader.
struct MixerChannelRow: View {
    @ObservedObject var channel: MixerChannel
    @ObservedObject var mixer: MixerModel
    var large = false

    private var audible: Bool { !channel.isMuted && !channel.isSilencedBySolo && channel.volume > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 8 : 5) {
            HStack(spacing: 8) {
                Image(nsImage: channel.icon).resizable().interpolation(.high).frame(width: large ? 28 : 22, height: large ? 28 : 22)
                    .opacity(audible ? 1 : 0.45)
                VStack(alignment: .leading, spacing: 0) {
                    Text(channel.name).font(.system(size: large ? 13.5 : 12, weight: .medium)).lineLimit(1)
                    Text(channel.problem ?? channel.status).font(.system(size: large ? 11.5 : 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(channel.isMuted ? "Muted" : "\(Int((channel.volume * 100).rounded()))%")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
                iconButton(channel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", on: channel.isMuted,
                           help: channel.isMuted ? "Unmute \(channel.name)" : "Mute \(channel.name)") { mixer.toggleMute(channel) }
                iconButton("headphones", on: channel.isSoloed,
                           help: channel.isSoloed ? "Stop solo" : "Hear only \(channel.name)") { mixer.toggleSolo(channel) }
                outputMenu
            }
            Slider(value: Binding(get: { Double(channel.volume) }, set: { mixer.setVolume(Float($0), for: channel) }),
                   in: 0...Double(mixer.maxVolume))
                .controlSize(.mini)
                .opacity(channel.isMuted ? 0.5 : 1)
                .accessibilityLabel("\(channel.name) volume")
                .accessibilityValue(channel.isMuted ? "Muted" : "\(Int(channel.volume * 100)) percent")
        }
        .animation(.easeOut(duration: 0.18), value: channel.isMuted)
    }

    private func iconButton(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : .primary)
                .background(on ? Color.primary : Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(help).accessibilityLabel(help)
    }

    private var outputMenu: some View {
        Menu {
            Button { mixer.setRoute(nil, for: channel) } label: {
                Label("Default output\(mixer.defaultDeviceName.isEmpty ? "" : " (\(mixer.defaultDeviceName))")",
                      systemImage: channel.deviceUID == nil ? "checkmark" : "speaker.wave.2")
            }
            Divider()
            ForEach(mixer.devices) { device in
                Button { mixer.setRoute(device.uid, for: channel) } label: {
                    Label(device.name, systemImage: channel.deviceUID == device.uid ? "checkmark" : device.symbol)
                }
            }
        } label: {
            Image(systemName: mixer.device(uid: channel.deviceUID)?.symbol ?? "hifispeaker")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(channel.deviceUID != nil ? Color(nsColor: .windowBackgroundColor) : .primary)
                .background(channel.deviceUID != nil ? Color.primary : Color.primary.opacity(0.08), in: Circle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(channel.deviceUID.flatMap { uid in mixer.device(uid: uid)?.name }.map { "Plays on \($0)" } ?? "Choose where \(channel.name) plays")
        .accessibilityLabel("Output for \(channel.name)")
    }
}
