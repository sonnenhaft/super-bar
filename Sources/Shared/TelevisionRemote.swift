import SwiftUI

struct TelevisionRemote: View {
    let tv: TelevisionItem
    let send: (TelevisionAction) -> Void
    @State private var text = ""
    @AppStorage("lg.tv.pointerMode") private var touchMode = true
    @State private var renaming = false
    @State private var draftName = ""

    private var remoteAvailable: Bool { tv.connected && tv.power != false }
    private var buttonSize: CGFloat {
        #if os(iOS)
        44
        #else
        30
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(tv.name, systemImage: "tv").font(.headline).lineLimit(2)
                if tv.canPair {
                    Button { draftName = tv.name; renaming = true } label: {
                        Image(systemName: "pencil").font(.system(size: 14))
                            .frame(width: buttonSize, height: buttonSize)
                    }.buttonStyle(.plain).accessibilityLabel("Rename TV")
                }
                Spacer(minLength: 4)
                if tv.busy {
                    RefreshGlyph(isRefreshing: true, size: 14)
                        .accessibilityHidden(false).accessibilityLabel("Updating TV")
                }
                Circle().fill(tv.power == true ? SuperBarPanelStyle.green : .gray).frame(width: 7, height: 7)
                if let volume = tv.volumePercent {
                    Label(String(volume), systemImage: "speaker.wave.2")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel(tv.liveVolume ? "Volume \(volume)" : "Last volume \(volume)")
                }
                iconButton("gearshape", label: "Connection settings", action: .configure)
            }
            HStack {
                powerButton(on: tv.power != true)
                sourceMenu
                Spacer(minLength: 0)
                iconButton("slider.horizontal.3", label: "TV picture and settings", action: .settings)
                    .disabled(!remoteAvailable)
            }
            HStack(spacing: 5) {
                ForEach(TVShortcut.allCases, id: \.self) { shortcut in
                    let app = shortcut.resolve(tv.apps)
                    Button {
                        if let app { send(.command(.launch(app.id))) }
                    } label: {
                        Text(shortcut.title).font(.system(size: 11, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: buttonSize)
                            .deviceSurface(selected: app != nil && tv.foregroundApp == app?.id, radius: 8)
                    }.buttonStyle(.plain)
                        .disabled(app == nil || !available(.launch(app?.id ?? "")))
                        .opacity(app == nil ? 0.45 : 1)
                        .accessibilityLabel(shortcut.title)
                        .help(app == nil ? "\(shortcut.title) unavailable on this TV" : shortcut.title)
                }
            }
            HStack(spacing: 6) {
                rocker("Volume", value: tv.volumePercent.map(String.init) ?? "—",
                       up: .volumeUp, down: .volumeDown)
                VStack(spacing: 3) {
                    if touchMode && tv.pointerAvailable {
                        TVPointerPad(send: send)
                    } else { directionalPad }
                    Button {
                        touchMode.toggle()
                    } label: {
                        Label(touchMode && tv.pointerAvailable ? "Arrows" : "Touchpad",
                              systemImage: touchMode && tv.pointerAvailable ? "dpad" : "hand.draw")
                            .font(.caption).frame(maxWidth: .infinity, minHeight: 30)
                    }.buttonStyle(.plain).disabled(!tv.pointerAvailable)
                }.frame(maxWidth: .infinity)
                rocker("Channel", value: "CH", up: .command(.channel(up: true)), down: .command(.channel(up: false)))
                    .disabled(!isLiveTV || tv.unsupportedCommands.contains("tv/channelUp") || tv.unsupportedCommands.contains("tv/channelDown"))
            }.disabled(!remoteAvailable || tv.busy)
            HStack(spacing: 5) {
                navigationButton("arrow.uturn.backward", "Back", .back)
                navigationButton("house", "Home", .home)
                navigationButton("rectangle.portrait.and.arrow.right", "Exit", .exit)
                iconButton("line.3.horizontal", label: "Menu", action: .menu)
            }.disabled(!remoteAvailable || tv.busy)
            if let brightness = tv.brightness {
                HStack {
                    Label("Brightness", systemImage: "sun.max")
                    Spacer()
                    iconButton("minus", label: "Decrease brightness", action: .brightness(-5))
                    Text(String(brightness)).monospacedDigit()
                    iconButton("plus", label: "Increase brightness", action: .brightness(5))
                }.font(.caption).disabled(!remoteAvailable || tv.busy)
            }
            extraControls
            if let status = tv.status, !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.panelHistorySurface()
        .alert("Rename TV", isPresented: $renaming) {
            TextField("TV name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { send(.rename(draftName)) }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).count > 80 || draftName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        } message: {
            Text("The name is saved on this device and shown in the widget. Leave it empty to reset.")
        }
        .onChange(of: tv.id) { _, _ in text = ""; renaming = false }
        .onChange(of: tv.connected) { _, connected in if !connected { text = "" } }
    }

    private func available(_ command: WebOSTVCommand) -> Bool {
        remoteAvailable && !tv.busy && !tv.unsupportedCommands.contains(command.uri)
    }

    private func commandButton(_ icon: String, _ label: String, _ command: WebOSTVCommand) -> some View {
        iconButton(icon, label: label, action: .command(command)).disabled(!available(command))
    }

    private func navigationButton(_ icon: String, _ title: String, _ action: TelevisionAction) -> some View {
        Button { send(action) } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: buttonSize)
        }.buttonStyle(TelevisionRemoteButtonStyle()).help(title)
    }

    private var extraControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tv.apps.isEmpty {
                Menu("Apps") {
                    ForEach(tv.apps) { app in
                        Button(app.name) { send(.command(.launch(app.id))) }
                            .disabled(!available(.launch(app.id)))
                    }
                }.disabled(!remoteAvailable || tv.busy)
            }
            if tv.services.contains("com.webos.service.ime") {
                DisclosureGroup("Keyboard") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Select a text field on the TV first.").font(.caption).foregroundStyle(.secondary)
                        TextField("Text for TV", text: $text).textFieldStyle(.roundedBorder)
                            .onSubmit(sendText)
                        HStack {
                            Button("Send text", action: sendText).disabled(text.isEmpty || text.utf8.count > 4096 || !available(.text(text)))
                            commandButton("delete.left", "Delete character", .deleteCharacter)
                            commandButton("return", "Enter", .enter)
                        }
                    }
                }.disabled(!remoteAvailable || tv.busy)
            }

        }
    }

    private func sendText() {
        guard !text.isEmpty, text.utf8.count <= 4096, available(.text(text)) else { return }
        send(.command(.text(text)))
        text = ""
    }

    private var liveApp: TelevisionInput? {
        tv.apps.first { $0.id == "com.webos.app.livetv" || $0.name.lowercased() == "live tv" }
    }
    private var isLiveTV: Bool {
        tv.foregroundApp == "com.webos.app.livetv" || (liveApp != nil && tv.foregroundApp == liveApp?.id)
    }

    private func rocker(_ label: String, value: String, up: TelevisionAction, down: TelevisionAction) -> some View {
        VStack(spacing: 0) {
            iconButton(label == "Channel" ? "chevron.up" : "plus", label: label + " up", action: up)
            Text(verbatim: value).font(.system(.subheadline, design: .rounded).weight(.bold)).monospacedDigit()
                .padding(.vertical, 5)
            iconButton(label == "Channel" ? "chevron.down" : "minus", label: label + " down", action: down)
        }.padding(3).background(.white.opacity(0.06), in: Capsule())
    }

    private func powerButton(on: Bool) -> some View {
        let label = on ? "Power on" : "Power off"
        return Button { send(.power(on)) } label: {
            HStack(spacing: 4) {
                Image(systemName: "power").accessibilityHidden(true)
                Text(on ? "Turn on" : "Turn off")
            }.font(.subheadline.weight(.medium))
                .padding(.horizontal, 8).frame(minHeight: buttonSize)
        }
        .buttonStyle(TelevisionRemoteButtonStyle(selected: tv.power == on))
        .disabled(tv.busy || (on ? tv.power == true || (!tv.canWake && !tv.connected) : !remoteAvailable))
        .accessibilityLabel(label).help(label)
    }

    private var sourceMenu: some View {
        let current = isLiveTV ? "Live TV" : tv.sources.first(where: { $0.id == tv.selectedSourceID })?.name
        return Menu {
            Button {
                if let liveApp { send(.command(.launch(liveApp.id))) }
            } label: { Label("Live TV", systemImage: isLiveTV ? "checkmark" : "tv") }
            .disabled(liveApp == nil || !available(.launch(liveApp?.id ?? "")))
            ForEach(tv.sources) { input in
                Button {
                    send(.source(input.id))
                } label: {
                    if input.id == tv.selectedSourceID {
                        Label(input.name, systemImage: "checkmark")
                    } else {
                        Text(input.name)
                    }
                }
            }
            if !tv.sources.isEmpty { Divider() }
            Button("Refresh inputs") { send(.refreshSources) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.connected.to.line.below")
                Text("Source")
                if let current {
                    Text(current).font(.caption).lineLimit(1).frame(maxWidth: 72).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.subheadline.weight(.medium))
                .padding(.horizontal, 10).frame(minHeight: buttonSize)
                .deviceSurface(selected: false, radius: 6)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize().disabled(!remoteAvailable).panelPointer()
        .accessibilityLabel("Source").accessibilityValue(current ?? "").help(current.map { "Source: " + $0 } ?? "Select TV input")
    }

    private var directionalPad: some View {
        VStack(spacing: 3) {
            iconButton("chevron.up", label: "Up", action: .up)
            HStack(spacing: 3) {
                iconButton("chevron.left", label: "Left", action: .left)
                Button { send(.ok) } label: {
                    Text("OK").font(.system(size: 13, weight: .bold)).frame(width: buttonSize, height: buttonSize)
                }.buttonStyle(TelevisionRemoteButtonStyle()).accessibilityLabel("OK").help("OK")
                iconButton("chevron.right", label: "Right", action: .right)
            }
            iconButton("chevron.down", label: "Down", action: .down)
        }.padding(4).background(.black.opacity(0.38), in: Circle()).disabled(!remoteAvailable || tv.busy)
    }

    private func iconButton(_ icon: String, label: String, action: TelevisionAction) -> some View {
        Button { send(action) } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .frame(width: buttonSize, height: buttonSize)
        }.buttonStyle(TelevisionRemoteButtonStyle()).accessibilityLabel(label).help(label)
    }
}

private struct TelevisionRemoteButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .deviceSurface(selected: selected || configuration.isPressed, radius: 6)
            .contentShape(Rectangle()).panelPointer()
            .opacity(enabled || selected ? 1 : 0.45)
    }
}
