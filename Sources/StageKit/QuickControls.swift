import SwiftUI
import AppKit

enum QuickTab: String, CaseIterable, Identifiable {
    case draw = "Draw", cursor = "Cursor", timer = "Timer", general = "General"
    var id: String { rawValue }
}

/// The everyday interface is a native status-item popover. The larger window
/// remains available for less frequent configuration and the full shortcut list.
struct QuickControlsView: View {
    static let size = NSSize(width: 370, height: 650)
    @ObservedObject var app: AppCoordinator
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                WorkbenchHeader(title: "Annotate", subtitle: app.isDrawing ? "\(app.tool.title) active" : "Ready to present", symbol: "pencil.tip.crop.circle.fill")
                Spacer()
                Menu {
                    Button("All Settings…") { app.showControls(tab: "Drawing") }
                    Button("Keyboard Shortcuts…") { app.showControls(tab: "Shortcuts") }
                    if !app.embedded { Divider(); Button("Quit Workbench") { app.quitApp() } }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("More options")
            }
            Picker("Quick controls", selection: $app.quickTab) {
                ForEach(QuickTab.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
                .onChange(of: app.quickTab) { app.finishRecording() }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let message = app.notice ?? settings.notice {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "info.circle")
                            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button { app.notice = nil; settings.notice = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).help("Dismiss notice")
                        }.foregroundStyle(.secondary)
                    }
                    if !app.shortcutFailures.isEmpty {
                        Button("Resolve \(app.shortcutFailures.count) shortcut conflicts…") { app.showControls(tab: "Shortcuts") }
                            .font(.system(size: 11)).foregroundStyle(.orange).buttonStyle(.link)
                    }
                    switch app.quickTab {
                    case .draw: drawing
                    case .cursor: cursor
                    case .timer: timer
                    case .general: general
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
            }.id(app.quickTab)
            Divider()
            Button { app.showDemoScenes() } label: {
                HStack {
                    Label("Demo scenes", systemImage: "iphone.and.landscape")
                    Spacer()
                    Text(settings.value.shortcut(for: .scenes).label).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain).help("Saved customer backdrops and phone layouts")
            HStack {
                Button("All Settings…") { app.showControls(tab: "Drawing") }.buttonStyle(.link)
                Spacer()
                if app.isDrawing || !app.boards.isEmpty {
                    Button("Return to demo") { app.hideQuickControls(); app.escape() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("\(settings.value.shortcut(for: .controls).label) to open")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.font(.system(size: 11))
        }
        .padding(14).frame(width: Self.size.width, height: Self.size.height)
        .font(.system(size: 12)).controlSize(.small)
        .background(Workbench.background).tint(Workbench.accent).workbenchTheme()
        .onExitCommand { app.hideQuickControls() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workbench drawing controls")
    }

    private var drawing: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Activation", systemImage: "hand.draw")
                Spacer()
                Picker("Drawing activation", selection: $settings.value.activation) {
                    ForEach(ActivationMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 135)
            }
            HStack(spacing: 9) {
                Label("Auto-fade", systemImage: "sparkles")
                Spacer(minLength: 8)
                Slider(value: $settings.value.fadeDelay, in: 0.5...15, step: 0.5)
                    .frame(width: 88).accessibilityLabel("Fade delay")
                Text("\(settings.value.fadeDelay, specifier: "%.1f") s")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 33, alignment: .trailing)
                Toggle("Auto-fade", isOn: $settings.value.autoFade).labelsHidden().toggleStyle(.switch)
            }
            HStack(spacing: 14) {
                numericControl("Line width", symbol: "lineweight", value: $settings.value.lineWidth, range: 1...20)
                Divider().frame(height: 23)
                numericControl("Text size", symbol: "textformat.size", value: $settings.value.fontSize, range: 12...96, step: 2)
            }
            if app.tool == .highlighter {
                HStack {
                    Text("Highlighter width").foregroundStyle(.secondary)
                    Slider(value: $settings.value.highlighterWidth, in: 8...60, step: 1).accessibilityLabel("Highlighter width")
                    Text("\(Int(settings.value.highlighterWidth)) pt").monospacedDigit().frame(width: 35)
                }
            }
            Divider()
            HStack(spacing: 9) {
                ForEach(Array(InkColor.presets.enumerated()), id: \.offset) { index, color in
                    Button { settings.value.color = color } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: color.nsColor))
                            RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.14))
                            if settings.value.color == color {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(color == .white || color == .amber || color == .mint ? Color.black : Color.white)
                            }
                        }.frame(width: 29, height: 25)
                    }.buttonStyle(.plain).accessibilityLabel("Colour \(index + 1)")
                        .help("Colour \(index + 1) · \(settings.value.shortcut(for: Action(rawValue: "color\(index + 1)")!).label)")
                }
                Spacer(minLength: 0)
                ColorPicker("Custom ink colour", selection: colorBinding(\Preferences.color), supportsOpacity: false)
                    .labelsHidden().help("Custom ink colour")
            }
            HStack {
                Text("INK COLOUR").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(colorHex(settings.value.color)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(spacing: 1) {
                ForEach(DrawingTool.allCases) { tool in
                    HStack(spacing: 8) {
                        Button { app.startDrawing(tool, latched: true) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: tool.symbol).frame(width: 19)
                                    .foregroundStyle(app.tool == tool ? Workbench.accent : .secondary)
                                Text(tool == .pen ? "Freehand" : tool.title)
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, minHeight: 25, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Start \(tool.title)")
                        shortcutButton(Action(rawValue: tool.rawValue)!)
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                quickAction(.undo, title: "Undo", symbol: "arrow.uturn.backward")
                quickAction(.redo, title: "Redo", symbol: "arrow.uturn.forward")
                quickAction(.clear, title: "Clear", symbol: "trash")
            }
            HStack(spacing: 8) {
                quickAction(.whiteboard, title: "Whiteboard", symbol: "rectangle")
                quickAction(.blackboard, title: "Blackboard", symbol: "rectangle.fill")
            }
            BoardExportButtons(app: app)
            ScreenshotHandoffButton(app: app)
            Text("Use a region or display capture to include visible ink. A single-window capture may omit Workbench’s separate annotation layer. Shortcut: Shift-Command-5.")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cursor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Cursor highlight", systemImage: "cursorarrow.rays").fontWeight(.medium)
                Spacer()
                Toggle("Cursor highlight", isOn: Binding(get: { app.pointerEnabled }, set: { value in
                    if value != app.pointerEnabled { app.perform(.pointer) }
                })).labelsHidden().toggleStyle(.switch)
            }
            Picker("Style", selection: $settings.value.pointerStyle) {
                ForEach(PointerStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            sliderControl("Radius", value: Binding(get: { settings.value.pointerAppearance.radius }, set: { value in settings.setPointer { $0.radius = value } }), range: settings.value.pointerStyle == .spotlight ? 40...240 : 4...80, suffix: "pt")
            sliderControl("Opacity", value: Binding(get: { settings.value.pointerAppearance.opacity * 100 }, set: { value in settings.setPointer { $0.opacity = value / 100 } }), range: 5...100, suffix: "%")
            if settings.value.pointerStyle != .spotlight {
                ColorPicker("Colour", selection: Binding(get: { Color(nsColor: settings.value.pointerAppearance.color.nsColor) }, set: { color in settings.setPointer { $0.color = InkColor(NSColor(color)) } }), supportsOpacity: false)
            }
            Divider()
            Picker("Show highlight", selection: $settings.value.pointerVisibility) {
                ForEach(PointerVisibility.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Ripple on click", isOn: $settings.value.clickRipple)
            if settings.value.pointerVisibility == .moving {
                sliderControl("Idle delay", value: $settings.value.idleDelay, range: 0.5...5, suffix: "s")
            }
            HStack { Text("Shortcut").foregroundStyle(.secondary); Spacer(); shortcutButton(.pointer) }
            Text("Each style keeps its own settings. Highlights hide while you draw.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            Button("macOS Zoom settings…") { app.openZoomSettings() }.buttonStyle(.link)
        }
    }

    private var timer: some View {
        VStack(spacing: 15) {
            VStack(spacing: 4) {
                Text(app.timerText).font(.system(size: 48, weight: .light, design: .rounded)).monospacedDigit()
                Text(app.timerFinished ? "Time is up" : app.timerRunning ? "Counting down" : app.timerSessionStarted ? "Paused" : "Ready for a break")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 9)
            HStack {
                Text("Duration")
                Spacer()
                TextField("Duration in minutes", value: $settings.value.timerMinutes, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 55)
                Text("min").foregroundStyle(.secondary)
                Stepper("Duration", value: $settings.value.timerMinutes, in: 1...180).labelsHidden().fixedSize()
            }
            HStack {
                ForEach([1.0, 3, 5, 10, 15], id: \.self) { value in
                    Button("\(Int(value)) min") { settings.value.timerMinutes = value }.frame(maxWidth: .infinity)
                }
            }
            TextField("Break message", text: $settings.value.timerMessage).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button { app.hideQuickControls(); app.startTimer() } label: { Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                Button(app.timerRunning ? "Pause" : "Resume") { app.pauseResumeTimer() }
                    .disabled(!app.timerSessionStarted || app.timerFinished)
                Button("Reset") { app.resetTimer() }
            }
            Divider()
            HStack {
                ColorPicker("Text", selection: colorBinding(\Preferences.timerColor), supportsOpacity: false)
                Spacer()
                ColorPicker("Background", selection: colorBinding(\Preferences.timerBackground), supportsOpacity: false)
            }
            sliderControl("Opacity", value: Binding(get: { settings.value.timerOpacity * 100 }, set: { settings.value.timerOpacity = $0 / 100 }), range: 20...100, suffix: "%")
            Toggle("Chime when time is up", isOn: $settings.value.timerChime)
            HStack { Text("Show / hide timer").foregroundStyle(.secondary); Spacer(); shortcutButton(.timer) }
            Text("Closing the timer leaves its countdown running. Show it again anytime.")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !app.embedded {
                WorkbenchAppearancePicker()
                Toggle("Launch at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            }
            Text("Workbench stays in the menu bar when you close its controls. Hold Command and drag its icon to reposition it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            Toggle("Pressure-sensitive pen", isOn: $settings.value.penPressure)
            Picker("Drawing indicator", selection: $settings.value.indicator) {
                ForEach(IndicatorStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Show the floating drawing palette", isOn: $settings.value.showDrawingPalette)
            Divider()
            Picker("Board palette", selection: $settings.value.boardPalette) {
                ForEach(PaletteMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Separate saved board drawings", isOn: $settings.value.separateBoards).disabled(!app.boards.isEmpty)
            Text("Board drawings save automatically on this Mac. Screen annotations remain temporary.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            HStack { Text("Open quick controls").foregroundStyle(.secondary); Spacer(); shortcutButton(.controls) }
            Text("Share your entire display during a call so the audience can see your annotations.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Workbench \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · Native to macOS").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func quickAction(_ action: Action, title: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Button { app.perform(action) } label: {
                Label(title, systemImage: symbol).frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).help(action.title)
            shortcutButton(action)
        }.frame(maxWidth: .infinity)
    }

    private func shortcutButton(_ action: Action) -> some View {
        Button { app.beginRecording(action) } label: {
            Text(app.recordingAction == action ? "Press keys…" : settings.value.shortcut(for: action).label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(app.recordingAction == action ? Workbench.accent : .secondary)
                .frame(minWidth: 57).padding(.horizontal, 7).padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityLabel("Shortcut for \(action.title)")
            .help("Click to record · Escape cancels · Delete disables")
    }
    private func numericControl(_ title: String, symbol: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary).help(title)
            TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 43)
            Stepper(title, value: value, in: range, step: step).labelsHidden().fixedSize()
        }.frame(maxWidth: .infinity).accessibilityElement(children: .contain).accessibilityLabel(title)
    }
    private func sliderControl(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 55, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(title)
            Text("\(value.wrappedValue, specifier: "%.0f") \(suffix)").monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
        }
    }
    private func colorBinding(_ key: WritableKeyPath<Preferences, InkColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: settings.value[keyPath: key].nsColor) }, set: { settings.value[keyPath: key] = InkColor(NSColor($0)) })
    }
    private func colorHex(_ color: InkColor) -> String {
        String(format: "#%02X%02X%02X", Int(color.r * 255), Int(color.g * 255), Int(color.b * 255))
    }
}
