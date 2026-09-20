import SwiftUI
import AppKit

private let inkBackground = Workbench.background
private let inkSurface = Workbench.surface
private let inkAccent = Workbench.accent

struct ControlCenter: View {
    @ObservedObject var app: AppCoordinator
    @ObservedObject var settings: SettingsStore
    @State private var choosingPersonas = false
    private let tabs: [(String, String)] = [("Present", "play.rectangle"), ("Drawing", "pencil.tip"), ("Pointer", "cursorarrow.rays"), ("Boards", "rectangle.on.rectangle"), ("Break timer", "timer"), ("Shortcuts", "command")]
    var body: some View {
        HStack(spacing: 0) {
            if !app.embedded {
            VStack(alignment: .leading, spacing: 28) {
                WorkbenchHeader(title: "Annotate", subtitle: "Make the point.", symbol: "pencil.tip.crop.circle.fill").padding(.top, 12)
                VStack(spacing: 5) {
                    ForEach(tabs, id: \.0) { title, symbol in
                        Button { app.finishRecording(); app.selectedTab = title } label: {
                            HStack(spacing: 12) {
                                Image(systemName: symbol).frame(width: 18)
                                Text(title).font(.system(size: 13, weight: app.selectedTab == title ? .semibold : .regular))
                                Spacer()
                            }.foregroundStyle(app.selectedTab == title ? inkAccent : Color.secondary)
                                .padding(.horizontal, 13).padding(.vertical, 11)
                                .background(app.selectedTab == title ? inkAccent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).accessibilityLabel(title)
                    }
                }
                Spacer()
                if !app.embedded { WorkbenchAppearancePicker().font(.caption) }
                VStack(alignment: .leading, spacing: 8) {
                    if !app.embedded {
                        Toggle("Launch at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                            .toggleStyle(.checkbox).font(.system(size: 11)).padding(.bottom, 14)
                    }
                    Label("Made for the live demo", systemImage: "sparkle").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text("Native to your Mac.\nYour screen stays yours.").font(.system(size: 11)).foregroundStyle(.tertiary).lineSpacing(3)
                    HStack {
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        Spacer()
                        if !app.embedded { Button("Quit") { app.quitApp() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }.padding(.top, 12)
                }
            }.padding(20).frame(width: 190).background(Workbench.surface.opacity(0.65))
            Rectangle().fill(Workbench.border).frame(width: 1)
            }
            VStack(spacing: 0) {
                if app.embedded {
                    Picker("Annotation controls", selection: $app.selectedTab) {
                        ForEach(tabs.filter { $0.0 != "Shortcuts" }, id: \.0) { title, _ in
                            Text(title == "Present" ? "Overview" : title).tag(title)
                        }
                    }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 28).padding(.top, 18)
                        .onChange(of: app.selectedTab) { _, value in
                            app.finishRecording()
                            if value == "Shortcuts" { app.selectedTab = "Drawing"; app.onOpenShortcuts?() }
                        }
                }
                HStack {
                    Text(app.embedded && app.selectedTab == "Present" ? "Drawing & presentation" : app.selectedTab).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button { choosingPersonas = true } label: { Label("Persona…", systemImage: "person.crop.rectangle") }
                    HStack(spacing: 6) {
                        Circle().fill(inkAccent).frame(width: 6, height: 6)
                        Text("Ready on \(app.displayCount) \(app.displayCount == 1 ? "display" : "displays")")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 28).padding(.vertical, 17)
                Divider().overlay(Color.white.opacity(0.03))
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let message = app.notice ?? settings.notice {
                            HStack(alignment: .top) {
                                Image(systemName: "info.circle").foregroundStyle(inkAccent)
                                Text(message).font(.system(size: 12)).textSelection(.enabled)
                                Spacer()
                                Button { app.notice = nil; settings.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                            }.padding(12).background(inkAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                        }
                        if !app.shortcutFailures.isEmpty {
                            Button {
                                if app.embedded { app.onOpenShortcuts?() }
                                else { app.selectedTab = "Shortcuts" }
                            } label: {
                                Label("\(app.shortcutFailures.count) shortcut conflicts need a different key combination", systemImage: "exclamationmark.triangle")
                            }.foregroundStyle(.orange).font(.system(size: 12))
                        }
                        switch app.selectedTab {
                        case "Drawing": drawing
                        case "Pointer": pointer
                        case "Boards": boardSettings
                        case "Break timer": timerSettings
                        case "Shortcuts": shortcuts
                        default: present
                        }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }.id(app.selectedTab)
            }
        }.background(inkBackground).tint(inkAccent).workbenchTheme()
            .sheet(isPresented: $choosingPersonas) { PersonaLibraryView(library: app.demoScenes.personas) }
    }
    private var present: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Make the point.\nKeep the flow.").font(.system(size: 29, weight: .semibold)).tracking(-1)
                    Text("Draw attention to what matters,\nright over your live demo.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                }
                Spacer(minLength: 10)
                DemoIllustration().frame(width: 213, height: 132).padding(.top, 4).accessibilityHidden(true)
            }.padding(.bottom, 3)
            HStack(spacing: 10) {
                startButton(.pen, title: "Draw on screen")
                startButton(.arrow, title: "Point it out")
                startButton(.highlighter, title: "Highlight")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Your two essential shortcuts", systemImage: "keyboard").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(settings.value.activation.rawValue.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(inkAccent)
                }
                shortcutHint(settings.value.activation == .hold ? "Hold to draw. Release to continue." : "Press to draw. Press again to continue.", action: .pen)
                Divider()
                shortcutHint("Clear the ink and return to your demo.", action: .clear)
                Text("Escape returns to your demo. Share your entire display in Zoom, Teams or Meet so your audience sees the ink.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.surface()
            HStack(spacing: 10) {
                utilityButton("Cursor", detail: app.pointerEnabled ? "Highlight is on" : "Help them follow", symbol: "cursorarrow.rays", active: app.pointerEnabled) { app.perform(.pointer) }
                utilityButton("Whiteboard", detail: "Explain an idea", symbol: "rectangle") { app.perform(.whiteboard) }
                utilityButton("Break timer", detail: "Keep the room on time", symbol: "timer") { app.perform(.timer) }
            }
        }
    }
    private func startButton(_ tool: DrawingTool, title: String) -> some View {
        Button { settings.value.onboardingComplete = true; app.startDrawing(tool, latched: true) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Image(systemName: tool.symbol).font(.system(size: 20)); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 10)).opacity(0.6) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }.foregroundStyle(tool == .pen ? inkBackground : Color.primary)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(tool == .pen ? inkAccent : inkSurface, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
    private func utilityButton(_ title: String, detail: String, symbol: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack { Image(systemName: symbol).foregroundStyle(active ? inkAccent : .secondary); Spacer(); if active { Circle().fill(inkAccent).frame(width: 5, height: 5) } }
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(inkSurface, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
    private func shortcutHint(_ title: String, action: Action) -> some View {
        HStack { Text(title).font(.system(size: 12)).foregroundStyle(.secondary); Spacer(); Keycap(text: settings.value.shortcut(for: action).label) }
    }
    private var drawing: some View {
        VStack(alignment: .leading, spacing: 22) {
            pageIntro("Ink that keeps up.", "Tune the tools once, then stay with your audience.")
            VStack(spacing: 18) {
                Picker("Activation", selection: $settings.value.activation) { ForEach(ActivationMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Text(settings.value.activation == .hold ? "Hold a tool shortcut while drawing. Release it to interact with your app again. Text and boards stay open until you exit." : "Press a tool shortcut once to start, and again to stop. Ideal for longer explanations, a tablet or Stream Deck.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }.surface()
            VStack(spacing: 20) {
                HStack {
                    Text("Ink colour"); Spacer(); swatches
                    ColorPicker("Custom", selection: colorBinding(\Preferences.color), supportsOpacity: false)
                        .labelsHidden().accessibilityLabel("Custom ink colour")
                        .accessibilityValue(settings.value.color.accessibilityDescription).help("Custom ink colour")
                }
                sliderRow("Line width", value: $settings.value.lineWidth, range: 1...20, suffix: "pt")
                sliderRow("Highlighter", value: $settings.value.highlighterWidth, range: 8...60, suffix: "pt")
                sliderRow("Text size", value: $settings.value.fontSize, range: 12...96, suffix: "pt")
                Divider()
                Toggle("Pressure-sensitive pen", isOn: $settings.value.penPressure)
                Picker("Drawing indicator", selection: $settings.value.indicator) { ForEach(IndicatorStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Toggle("Show the palette while drawing", isOn: $settings.value.showDrawingPalette)
            }.font(.system(size: 12)).surface()
            VStack(spacing: 16) {
                Toggle("Auto-fade screen annotations", isOn: $settings.value.autoFade)
                if settings.value.autoFade { sliderRow("Visible for", value: $settings.value.fadeDelay, range: 0.5...30, suffix: "sec") }
                Text("Board drawings are retained. Hold Shift for straight angles, squares and circles. For text, type at the pointer, click to place, then Enter to finish; Shift-Enter adds a line.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 12)).surface()
            HStack(spacing: 8) {
                ForEach(DrawingTool.allCases) { tool in
                    Button { app.startDrawing(tool, latched: true) } label: { Image(systemName: tool.symbol).frame(maxWidth: .infinity).frame(height: 28) }
                        .help(tool.title).accessibilityLabel("Use \(tool.title)")
                }
            }
        }
    }
    private var pointer: some View {
        VStack(alignment: .leading, spacing: 22) {
            pageIntro("Let eyes follow ideas.", "A clear pointer helps your audience stay oriented.")
            HStack(spacing: 10) {
                ForEach(PointerStyle.allCases, id: \.self) { style in
                    Button { settings.value.pointerStyle = style } label: {
                        VStack(spacing: 12) {
                            PointerPreview(style: style).frame(height: 55)
                            Text(style.rawValue).font(.system(size: 11, weight: .medium))
                        }.padding(.vertical, 16).frame(maxWidth: .infinity)
                            .background(settings.value.pointerStyle == style ? inkAccent.opacity(0.1) : inkSurface, in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(settings.value.pointerStyle == style ? inkAccent.opacity(0.65) : .clear))
                    }.buttonStyle(.plain)
                }
            }
            VStack(spacing: 20) {
                sliderRow("Radius", value: Binding(get: { settings.value.pointerAppearance.radius }, set: { newValue in settings.setPointer { $0.radius = newValue } }), range: settings.value.pointerStyle == .spotlight ? 40...240 : 4...80, suffix: "pt")
                sliderRow("Opacity", value: Binding(get: { settings.value.pointerAppearance.opacity * 100 }, set: { newValue in settings.setPointer { $0.opacity = newValue / 100 } }), range: 5...100, suffix: "%")
                if settings.value.pointerStyle != .spotlight {
                    ColorPicker("Colour", selection: Binding(get: { Color(nsColor: settings.value.pointerAppearance.color.nsColor) }, set: { color in settings.setPointer { $0.color = InkColor(NSColor(color)) } }), supportsOpacity: false)
                }
                Divider()
                Picker("Visibility", selection: $settings.value.pointerVisibility) { ForEach(PointerVisibility.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Toggle("Ripple on click", isOn: $settings.value.clickRipple)
                Text("Each style remembers its own settings. Pointer effects hide automatically while drawing.").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 12)).surface()
            HStack {
                Button { app.perform(.pointer) } label: { Label(app.pointerEnabled ? "Turn pointer off" : "Turn pointer on", systemImage: "cursorarrow.rays") }.buttonStyle(.borderedProminent).controlSize(.large)
                Spacer(); Keycap(text: settings.value.shortcut(for: .pointer).label)
            }
            Button("Open macOS Zoom settings…") { app.openZoomSettings() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var boardSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            pageIntro("Room for an explanation.", "Open a canvas on the display under your pointer.")
            HStack(spacing: 14) {
                boardCard(.white, title: "Whiteboard", action: .whiteboard)
                boardCard(.black, title: "Blackboard", action: .blackboard)
            }
            BoardExportButtons(app: app)
            ScreenshotHandoffButton(app: app)
            Text("Board image includes only the board and ink. Use a region or display capture to include visible screen annotations; a single-window capture may omit Workbench’s separate layer. The palette and pointer hide during selection. Shortcut: Shift-Command-5.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Keep board drawings separate from the screen", isOn: $settings.value.separateBoards).disabled(!app.boards.isEmpty)
                Text(settings.value.separateBoards ? "Your board is saved automatically on this Mac. White and black backgrounds use the same saved canvas for each display." : "The board uses your current screen annotations. Shared screen ink is temporary and is not saved when you quit.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Divider()
                Picker("Board palette", selection: $settings.value.boardPalette) { ForEach(PaletteMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Text("With Auto-hide, move the mouse to reveal the palette again. Escape closes the board and returns to your presentation.").font(.system(size: 11)).foregroundStyle(.secondary)
            }.font(.system(size: 12)).surface()
            VStack(alignment: .leading, spacing: 8) {
                Label("Drawing with an iPad or tablet", systemImage: "ipad.and.arrow.forward").font(.system(size: 12, weight: .semibold))
                Text("Connect your iPad with Sidecar, or use a Mac-compatible pen tablet. Choose Toggle activation for drawing without holding a keyboard shortcut. Pressure input is supported where the device supplies it.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            }.surface()
        }
    }
    private func boardCard(_ style: BoardStyle, title: String, action: Action) -> some View {
        Button { app.perform(action) } label: {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(style == .white ? Color(red: 0.95, green: 0.96, blue: 0.98) : Color(red: 0.04, green: 0.05, blue: 0.08))
                    Image(systemName: "scribble.variable").font(.system(size: 54, weight: .light)).foregroundStyle(style == .white ? Color(nsColor: InkColor.coral.nsColor) : inkAccent)
                }.frame(height: 105)
                HStack { Text(title).font(.system(size: 13, weight: .semibold)); Spacer(); Keycap(text: settings.value.shortcut(for: action).label) }
            }.padding(14).background(inkSurface, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
    private var timerSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            pageIntro("Give the room a moment.", "A calm, visible countdown for breaks between sessions.")
            VStack(spacing: 9) {
                Text(settings.value.timerMessage.isEmpty ? "Back in a moment" : settings.value.timerMessage).font(.system(size: 15)).foregroundStyle(Color(nsColor: settings.value.timerColor.nsColor).opacity(0.7))
                Text(app.timerText).font(.system(size: 68, weight: .light, design: .rounded)).monospacedDigit().foregroundStyle(Color(nsColor: settings.value.timerColor.nsColor))
            }.frame(maxWidth: .infinity).padding(26).background(Color(nsColor: settings.value.timerBackground.nsColor), in: RoundedRectangle(cornerRadius: 14))
            VStack(spacing: 18) {
                HStack { Text("Duration"); Spacer(); TextField("Minutes", value: $settings.value.timerMinutes, format: .number).frame(width: 60).textFieldStyle(.roundedBorder); Text("minutes").foregroundStyle(.secondary) }
                HStack { ForEach([1.0, 3, 5, 10, 15], id: \.self) { value in Button("\(Int(value)) min") { settings.value.timerMinutes = value }.frame(maxWidth: .infinity) } }
                TextField("Message", text: $settings.value.timerMessage).textFieldStyle(.roundedBorder)
                HStack { ColorPicker("Text", selection: colorBinding(\Preferences.timerColor), supportsOpacity: false); Spacer(); ColorPicker("Background", selection: colorBinding(\Preferences.timerBackground), supportsOpacity: false) }
                sliderRow("Window opacity", value: Binding(get: { settings.value.timerOpacity * 100 }, set: { settings.value.timerOpacity = $0 / 100 }), range: 20...100, suffix: "%")
                Toggle("Play a chime when time is up", isOn: $settings.value.timerChime)
            }.font(.system(size: 12)).surface()
            HStack {
                Button { app.startTimer() } label: { Label("Start break", systemImage: "play.fill") }.buttonStyle(.borderedProminent).controlSize(.large)
                Button(app.timerRunning ? "Pause" : "Resume") { app.pauseResumeTimer() }.controlSize(.large)
                Button("Reset") { app.resetTimer() }.controlSize(.large)
                Spacer(); Keycap(text: settings.value.shortcut(for: .timer).label)
            }
            Text("Drag or resize the timer window. Closing it leaves the countdown running; show it again anytime.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageIntro("Keep your hands in the flow.", "Click a shortcut, then press your preferred combination.")
            Text("Use Control, Option or Command with a key. Escape cancels recording; Delete disables a shortcut. Stream Deck can send these same hotkeys.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Action.allCases) { action in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(action.title).font(.system(size: 12))
                            Spacer()
                            Button { app.beginRecording(action) } label: {
                                Keycap(text: app.recordingAction == action ? "Press keys…" : settings.value.shortcut(for: action).label)
                            }.buttonStyle(.plain).accessibilityLabel("Shortcut for \(action.title)")
                        }
                        if let error = app.shortcutFailures[action] { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
                    }.padding(.vertical, 10)
                    if action != Action.allCases.last { Divider() }
                }
            }.surface()
            Button("Restore default shortcuts") { app.restoreShortcuts() }
        }
    }
    private var swatches: some View {
        HStack(spacing: 8) {
            ForEach(Array(InkColor.presets.enumerated()), id: \.offset) { index, color in
                Button { settings.value.color = color } label: {
                    Circle().fill(Color(nsColor: color.nsColor)).frame(width: 18, height: 18)
                        .padding(3).overlay(Circle().stroke(settings.value.color == color ? .white : .clear, lineWidth: 1.5))
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(color.accessibilityDescription) ink colour")
                    .accessibilityValue(settings.value.color == color ? "Selected" : "Not selected")
                    .accessibilityAddTraits(settings.value.color == color ? .isSelected : [])
            }
        }
    }
    private func colorBinding(_ key: WritableKeyPath<Preferences, InkColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: settings.value[keyPath: key].nsColor) }, set: { settings.value[keyPath: key] = InkColor(NSColor($0)) })
    }
    private func pageIntro(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.7)
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: 16) {
            Text(title).frame(width: 105, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(value.wrappedValue, specifier: value.wrappedValue < 1 ? "%.1f" : "%.0f") \(suffix)")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }.font(.system(size: 12))
    }
}

private extension View {
    func surface() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading).background(inkSurface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.85)).padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.08)))
    }
}

struct DemoIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11).fill(inkSurface).overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.1)))
            VStack(spacing: 12) {
                HStack(spacing: 4) { ForEach(0..<3) { _ in Circle().fill(Color.white.opacity(0.18)).frame(width: 4, height: 4) }; Spacer(); Capsule().fill(Color.white.opacity(0.06)).frame(width: 96, height: 8); Spacer() }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 9) { ForEach(0..<4) { index in Capsule().fill(Color.white.opacity(index == 0 ? 0.2 : 0.07)).frame(width: index == 2 ? 26 : 36, height: 4) } }.frame(width: 40)
                    VStack(alignment: .leading, spacing: 10) {
                        Capsule().fill(Color.white.opacity(0.3)).frame(width: 58, height: 5)
                        HStack(alignment: .bottom, spacing: 7) { ForEach([24.0, 40, 34, 62, 52, 78], id: \.self) { h in RoundedRectangle(cornerRadius: 3).fill(inkAccent.opacity(h == 78 ? 0.65 : 0.16)).frame(width: 15, height: h) } }.frame(height: 78, alignment: .bottom)
                    }
                }
            }.padding(15)
            Ellipse().stroke(Color(nsColor: InkColor.coral.nsColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).frame(width: 42, height: 102).rotationEffect(.degrees(10)).offset(x: 79, y: 12)
            Image(systemName: "arrow.up.right").font(.system(size: 30, weight: .light)).foregroundStyle(Color(nsColor: InkColor.coral.nsColor)).rotationEffect(.degrees(-5)).offset(x: 28, y: 55)
        }.rotationEffect(.degrees(-3))
    }
}

struct PointerPreview: View {
    var style: PointerStyle
    var body: some View {
        ZStack {
            if style == .spotlight { RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.4)).frame(width: 70, height: 53) }
            Circle().fill(style == .ring ? Color.clear : (style == .laser ? Color(nsColor: InkColor.coral.nsColor) : inkAccent.opacity(style == .disc ? 0.28 : 0.14)))
                .frame(width: style == .laser ? 17 : 41, height: style == .laser ? 17 : 41)
                .overlay(Circle().stroke(style == .ring ? inkAccent : .clear, lineWidth: 2.5))
            Image(systemName: "cursorarrow").font(.system(size: 18)).foregroundStyle(.white).offset(x: 2, y: 2)
        }
    }
}

struct DrawingPalette: View {
    @ObservedObject var app: AppCoordinator
    @ObservedObject var settings: SettingsStore
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.trailing, 3)
            ForEach(DrawingTool.allCases) { tool in
                Button { app.startDrawing(tool, latched: true) } label: {
                    Image(systemName: tool.symbol).font(.system(size: 15)).frame(width: 30, height: 34)
                        .foregroundStyle(app.tool == tool ? inkAccent : .white.opacity(0.8))
                        .background(app.tool == tool ? inkAccent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).help(tool.title).accessibilityLabel(tool.title)
            }
            Divider().frame(height: 24).padding(.horizontal, 3)
            ForEach(Array(InkColor.presets.prefix(5).enumerated()), id: \.offset) { index, color in
                Button { settings.value.color = color } label: {
                    Circle().fill(Color(nsColor: color.nsColor)).frame(width: 15, height: 15).padding(3)
                        .overlay(Circle().stroke(settings.value.color == color ? .white : .clear))
                }.buttonStyle(.plain).help(color.accessibilityDescription)
                    .accessibilityLabel("\(color.accessibilityDescription) ink colour")
                    .accessibilityValue(settings.value.color == color ? "Selected" : "Not selected")
                    .accessibilityAddTraits(settings.value.color == color ? .isSelected : [])
            }
            Divider().frame(height: 24).padding(.horizontal, 3)
            Button { app.perform(.undo) } label: { Image(systemName: "arrow.uturn.backward").frame(width: 25, height: 32) }.help("Undo").accessibilityLabel("Undo")
            Button { app.clearCanvas() } label: { Image(systemName: "trash").frame(width: 25, height: 32) }.help("Clear canvas").accessibilityLabel("Clear canvas")
            Menu {
                Button("Copy board") { app.copyBoard() }
                Button("Save board PNG…") { app.saveBoardPNG() }
                Divider()
                Button("Open Screenshot…") { app.openScreenshot() }
            } label: {
                Image(systemName: "square.and.arrow.up").frame(width: 28, height: 32)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(!app.canExportBoard).help("Copy or save the open board")
                .accessibilityLabel("Board image")
            Button { app.escape() } label: { Text("Done").font(.system(size: 11, weight: .semibold)).foregroundStyle(inkAccent).padding(.horizontal, 8) }.help("Return to demo · Escape")
        }.buttonStyle(.plain).padding(.horizontal, 13).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.12)))
            .padding(4)
    }
}

struct BoardExportButtons: View {
    @ObservedObject var app: AppCoordinator
    var body: some View {
        HStack {
            Button { app.copyBoard() } label: { Label("Copy board", systemImage: "doc.on.doc") }
            Button { app.saveBoardPNG() } label: { Label("Save board PNG…", systemImage: "square.and.arrow.down") }
        }.disabled(!app.canExportBoard)
    }
}

struct ScreenshotHandoffButton: View {
    @ObservedObject var app: AppCoordinator
    var body: some View {
        Button { app.openScreenshot() } label: {
            Label("Open Screenshot…", systemImage: "camera.viewfinder")
        }
        .disabled(app.screenshotHandoffActive)
        .help("Open Apple Screenshot and keep visible Workbench annotations in place")
        .accessibilityHint("Hides Workbench controls and pauses annotation fading while Apple Screenshot is open")
    }
}

struct BreakTimerView: View {
    @ObservedObject var app: AppCoordinator
    @ObservedObject var settings: SettingsStore
    @State private var controlsVisible = false
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                Spacer(minLength: 8)
                TextField("Break message", text: $settings.value.timerMessage).textFieldStyle(.plain)
                    .multilineTextAlignment(.center).font(.system(size: max(14, geometry.size.width * 0.034), weight: .medium))
                    .foregroundStyle(Color(nsColor: settings.value.timerColor.nsColor).opacity(0.7))
                Text(app.timerFinished ? "00:00" : app.timerText)
                    .font(.system(size: min(geometry.size.width * 0.18, geometry.size.height * 0.35), weight: .ultraLight, design: .rounded))
                    .monospacedDigit().foregroundStyle(Color(nsColor: settings.value.timerColor.nsColor))
                    .accessibilityLabel("Time remaining \(app.timerText)")
                Capsule().fill(Color(nsColor: settings.value.timerColor.nsColor).opacity(0.12)).frame(height: 3)
                    .overlay(alignment: .leading) { GeometryReader { bar in Capsule().fill(inkAccent).frame(width: bar.size.width * app.timerProgress) } }.frame(maxWidth: 300)
                Text(app.timerFinished ? "Ready to continue" : app.timerRunning ? "" : "Paused")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color(nsColor: settings.value.timerColor.nsColor).opacity(0.65))
                Spacer(minLength: 8)
                HStack(spacing: 18) {
                    Button { if app.timerFinished { app.startTimer() } else { app.pauseResumeTimer() } } label: { Label(app.timerFinished ? "Restart" : app.timerRunning ? "Pause" : "Resume", systemImage: app.timerRunning ? "pause.fill" : "play.fill") }
                    Button("Reset") { app.resetTimer() }
                    Button("Hide") { app.hideTimer() }
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color(nsColor: settings.value.timerColor.nsColor).opacity(controlsVisible ? 0.8 : 0.3))
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: settings.value.timerBackground.nsColor))
                .onHover { controlsVisible = $0 }
        }
    }
}
