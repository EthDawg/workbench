#!/usr/bin/env python3
"""Synthetic Swift fixtures. Does not compile, launch or modify the Mac app."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name('check-surfaces.py')
spec = importlib.util.spec_from_file_location('surfaces', SCRIPT)
check = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = check
spec.loader.exec_module(check)

PANEL = 'struct WorkbenchQuickPanel: View { var body: some View { %s } }'


class SurfaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.file = self.root / 'Sources/LocalVoice/WorkbenchQuickPanel.swift'
        self.file.parent.mkdir(parents=True)
        self.file.write_text(PANEL % 'Button("Read") { read() }')

    def write(self, relative, source):
        path = self.root / 'Sources' / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)
        return path

    def entries(self):
        return check.derive(self.root, require_roots=False)

    def labels(self):
        return [e['label'] for e in self.entries()]

    def registry(self, entries=None):
        return [{**e, 'kind': 'action', 'belongsTo': 'read'} for e in (self.entries() if entries is None else entries)]

    def errors(self, entries=None):
        return check.compare(self.entries(), self.registry() if entries is None else entries)

    def test_pass(self):
        self.assertEqual([], self.errors())

    def test_unregistered_footer_teaches_without_deciding(self):
        registered = self.registry()
        self.file.write_text(self.file.read_text().replace('Button("Read")', 'Button("Snap") { open("snap") }; Button("Read")'))
        failure = '\n'.join(self.errors(registered))
        self.assertIn('Unregistered entry on quick panel footer: "Snap".', failure)
        for phrase in ('docs/workbench.md#grammar', 'Quality', 'Option', "Ethan's decision", '--update'):
            self.assertIn(phrase, failure)

    def test_stale(self):
        registered = self.registry()
        self.file.write_text('struct WorkbenchQuickPanel: View {}')
        self.assertIn('Stale entry:', '\n'.join(self.errors(registered)))

    def test_unclassified(self):
        entry = self.registry()[0]
        entry['kind'] = 'unclassified'
        self.assertIn('Unclassified entry:', '\n'.join(self.errors([entry])))

    def test_collision(self):
        first = self.registry()[0]
        second = {**first, 'id': 'another', 'belongsTo': 'dictate'}
        self.assertIn('Label collision:', '\n'.join(check.compare([first, second], [first, second])))

    def test_explicit_alias_allows_collision(self):
        first = self.registry()[0]
        second = {**first, 'id': 'another', 'belongsTo': 'dictate', 'aliasOf': first['id'], 'note': 'Intentional shared action.'}
        self.assertEqual([], check.compare([first, second], [first, second]))

    def test_alias_is_not_a_blanket_label_allowlist(self):
        one = self.registry()[0]
        two = {**one, 'id': 'two', 'belongsTo': 'draw'}
        three = {**one, 'id': 'three', 'belongsTo': 'dictate', 'aliasOf': 'dictate', 'note': 'Existing alias.'}
        self.assertIn('Label collision:', '\n'.join(check.compare([one, two, three], [one, two, three])))

    def test_alias_needs_real_target_and_note(self):
        entry = {**self.registry()[0], 'aliasOf': 'missing'}
        errors = '\n'.join(self.errors([entry]))
        self.assertIn('Invalid aliasOf', errors)
        self.assertIn('needs a note', errors)

    def test_update_removes_stale_and_requires_classification(self):
        registered = self.registry()
        self.file.write_text(PANEL % 'Button("Snap") { snap() }')
        updated = check.reconcile(self.entries(), registered)
        self.assertEqual(1, len(updated))
        self.assertEqual('Snap', updated[0]['label'])
        self.assertEqual('unclassified', updated[0]['kind'])
        self.assertTrue(check.compare(self.entries(), updated))

    def test_update_preserves_reviewed_metadata_and_is_deterministic(self):
        registry = self.registry()
        registry[0].update(aliasOf='read', note='An intentional alternative.')
        self.assertEqual(registry, check.reconcile(self.entries(), registry))
        self.assertEqual(self.entries(), self.entries())

    def test_changed_label_with_stable_catalogue_id_is_unclassified(self):
        actual = self.entries()
        registry = self.registry(actual)
        actual[0] = {**actual[0], 'label': 'Read aloud'}
        self.assertIn('Changed entry', '\n'.join(check.compare(actual, registry)))
        self.assertEqual('unclassified', check.reconcile(actual, registry)[0]['kind'])

    def test_comments_strings_and_nested_interpolation(self):
        self.file.write_text(r'''
        // Button("Fake") {}
        /* Button("Also fake") {} /* nested */ */
        struct WorkbenchQuickPanel: View { var body: some View {
          Button("Say \"hello\"") {}
          Button("\(count) \(count == 1 ? "item" : "items")") {}
          let example = "Button(\"Not a control\")"
        } }
        ''')
        entries = self.entries()
        self.assertEqual(2, len(entries))
        self.assertEqual(['Say "hello"'], [e['label'] for e in entries if e['label']])
        dynamic = next(e for e in entries if e['label'] is None)
        self.assertIn('Runtime label', dynamic['note'])
        self.assertIn('count', dynamic['expression'])

    def test_all_swiftui_forms_and_native_menu(self):
        self.file.write_text(PANEL % '''
          Button("Start") {}
          Toggle("Detect", isOn: $enabled)
          Menu("Tools") { Button("Open") {} }
          Picker("Mode", selection: $mode) { Text("One").tag(1) }
          Button {} label: { Label("Capture", systemImage: "camera") }
          Button {} label: { Text("Stop") }
          Button(action: review) { Text("Review offer") }
          NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
          menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
          Text("A heading is not an entry")''')
        self.assertEqual({'Start', 'Detect', 'Tools', 'Open', 'Mode', 'One', 'Capture', 'Stop', 'Review offer', 'Preferences', 'Quit'},
                         set(self.labels()))

    def test_panel_areas_follow_structure_not_helper_names(self):
        self.file.write_text('''struct WorkbenchQuickPanel: View {
          var body: some View { Toggle("Floating Toolbar", isOn: $x); Text(notice); Button("Settings") {} }
          private func options(_ tool: WorkbenchControlTool) -> some View {
            switch tool { case .read: Button("Stop") {}; case .timer: NativeControlMenu(title: "Options") { menu() } }
          }
          private func key(_ tool: WorkbenchControlTool) -> some View { Button {} label: { Text(label) } }
        }''')
        before = {e['surface']: e['id'] for e in self.entries()}
        self.assertEqual({'quick panel header', 'quick panel status rows', 'quick panel footer', 'quick panel read options',
                          'quick panel timer options', 'quick panel row controls'}, set(before))
        self.file.write_text(self.file.read_text().replace('func options', 'func rowOptions'))
        self.assertEqual(before, {e['surface']: e['id'] for e in self.entries()})

    def test_a_fixed_row_inside_the_rows_loop_is_a_row(self):
        self.file.write_text(PANEL % '''
          ForEach(WorkbenchControlTool.allCases) { tool in
            if tool == .snapAndTalk { Button { open("snap") } label: { Text("Snap") } }
            Button { perform(tool) } label: { Text(tool.title) }
          }
          Button("Settings") { open("settings") }''')
        surfaces = {e['label']: e['surface'] for e in self.entries()}
        self.assertEqual('quick panel rows', surfaces['Snap'])
        self.assertEqual('quick panel footer', surfaces['Settings'])

    def test_shortcut_editor_is_not_an_entry_point(self):
        self.file.write_text('''struct WorkbenchQuickPanel: View {
          var body: some View { Button("Read") {} }
          private var shortcutEditor: some View { Button("Turn Off") {}; Button("Change") {} }
        }''')
        self.assertEqual(['Read'], self.labels())

    def test_duplicate_button_definition_is_visible(self):
        before = self.registry()
        self.file.write_text(self.file.read_text().replace('Button("Read") { read() }', 'Button("Read") { read() }; Button("Read") { anotherRead() }'))
        self.assertEqual(2, len(self.entries()))
        self.assertIn('Unregistered entry', '\n'.join(self.errors(before)))

    def test_reordering_whitespace_and_new_properties_do_not_churn_ids(self):
        before = self.entries()
        self.file.write_text('''struct WorkbenchQuickPanel: View {
          var model: Model
          var action: () -> Void
          var body: some View { /* comment */ Button ( "Read" ) { read() } }
        }''')
        self.assertEqual(before, self.entries())

    def test_runtime_label_change_is_visible(self):
        self.file.write_text(PANEL % 'Button(model.title) {}')
        before = self.registry()
        self.file.write_text(self.file.read_text().replace('model.title', 'model.otherTitle'))
        self.assertIn('Unregistered entry', '\n'.join(self.errors(before)))

    def test_extracting_a_helper_is_not_a_new_entry(self):
        before = self.entries()
        self.file.write_text('struct WorkbenchQuickPanel: View { var body: some View { footer }; private var footer: some View { Button("Read") { read() } } }')
        self.assertEqual(before, self.entries())

    def test_capability_pages_are_out_of_scope(self):
        before = self.registry()
        self.write('LocalVoice/SnapEditorView.swift', 'struct SnapEditorView: View { var body: some View { Button("Crop") {}; Button("Save") {} } }')
        self.write('LocalVoice/WorkbenchHome.swift', '''struct WorkbenchHome: View {
          var body: some View { SnapEditorView() }
          private var welcome: some View { card("Snap", "Capture.", "viewfinder", "") { page = "snap" } }
          private func card(_ title: String, _ detail: String, _ symbol: String, _ footnote: String, action: @escaping () -> Void) -> some View {
            Button(action: action) { Text(title) }
          }
        }''')
        self.assertEqual(['Read', 'Snap'], sorted(self.labels()))
        self.assertIn('Unregistered entry on window home: "Snap".', '\n'.join(self.errors(before)))

    def test_persistent_options_on_a_capability_page_are_entries(self):
        self.write('LocalVoice/Views.swift', '''struct ContentView: View {
          private var dictate: some View {
            Toggle("Keep clipboard", isOn: $model.preferences.restoreClipboard); Toggle("Show original", isOn: $showOriginal)
            Picker("Voice", selection: $model.voice) { Text("Alex").tag("Alex") }; Button("Copy text") { copy() }; dictateOptions
          }
          private var dictateOptions: some View { VoiceOptions(model: model); Button("Your dictionary") { page = "dictionary" } }
        }''')
        self.write('LocalVoice/QuickControls.swift', '''struct VoiceOptions: View {
          var body: some View { Picker("Activation", selection: $model.preferences.capture) { ForEach(CaptureMode.allCases, id: \\.self) { Text($0.rawValue).tag($0) } } }
        }''')
        self.write('LocalVoice/VoicePreferences.swift', 'enum CaptureMode: String, CaseIterable { case toggle = "Toggle", hold = "Press & hold" }')
        options = sorted(e['label'] for e in self.entries() if e['surface'] == 'dictate page options')
        self.assertEqual(['Activation', 'Keep clipboard', 'Your dictionary'], options)
        self.assertIn('Press & hold', self.labels())
        for transient in ('Show original', 'Voice', 'Alex', 'Copy text'):
            self.assertNotIn(transient, self.labels())
        before = self.registry()
        page = self.root / 'Sources/LocalVoice/Views.swift'
        page.write_text(page.read_text().replace('Button("Copy text")', 'Toggle("Sounds", isOn: $model.preferences.sounds); Button("Copy text")'))
        self.assertIn('Unregistered entry on dictate page options: "Sounds".', '\n'.join(self.errors(before)))

    def test_transient_controls_on_a_capability_page_stay_out(self):
        page = self.write('LocalVoice/Views.swift', 'struct ContentView: View { private var dictate: some View { Button("Copy text") { copy() } } }')
        before = self.registry()
        page.write_text(page.read_text().replace('Button("Copy text")', 'Toggle("Show original", isOn: $showOriginal); Stepper("Pace", value: $rate); Button("Copy text")'))
        self.assertEqual([], self.errors(before))

    def test_doors_on_a_capability_page_are_entries(self):
        page = self.write('LocalVoice/Views.swift', '''struct ContentView: View {
          private var dictate: some View {
            Button("Transcribe a meeting or call…") { model.page = "meeting"; model.onShowEditor?("meeting") }
            Button("Copy text") { model.copyTranscript() }; Button("Original…") { showOriginal = true }
            Button("Open Apple Shortcuts") { NSWorkspace.shared.open(url) }
            Button { model.page = "history" } label: { Label("History", systemImage: "clock") }
          }
        }''')
        self.write('LocalVoice/ReadbackView.swift', '''struct ReadbackView: View {
          var onOpenPacks: () -> Void = {}
          var body: some View { Button("Manage packs…", action: onOpenPacks); Button("Stop") { model.stop() } }
        }''')
        doors = sorted((e['surface'], e['label']) for e in self.entries() if e['surface'].endswith(' page'))
        self.assertEqual([('dictate page', 'History'), ('dictate page', 'Transcribe a meeting or call…'), ('snap & talk page', 'Manage packs…')], doors)
        before = self.registry()
        page.write_text(page.read_text().replace('Button("Copy text")', 'Button("Show in History") { model.page = "history" }; Button("Copy text")'))
        failure = '\n'.join(self.errors(before))
        self.assertIn('Unregistered entry on dictate page: "Show in History".', failure)
        self.assertIn('docs/workbench.md#grammar', failure)

    def test_history_routes_are_doors_and_bound_page_state_is_not(self):
        self.write('LocalVoice/CaptureHistoryView.swift', '''struct TranscriptHistoryRow: View {
          @Binding var details: Transcript?
          var body: some View {
            Button("Open") { model.openTranscript(item) }; Button("Details…") { details = item }
            Button("Show in History") { model.openHistory(HistoryDoor(filter: .transcripts)) }
          }
        }''')
        doors = sorted(e['label'] for e in self.entries() if e['surface'] == 'history page')
        self.assertEqual(['Open', 'Show in History'], doors)

    def test_page_local_actions_are_not_doors(self):
        page = self.write('LocalVoice/Views.swift', 'struct ContentView: View { private var dictate: some View { Button("Transcribe a meeting or call…") { model.page = "meeting" } } }')
        before = self.registry()
        page.write_text(page.read_text().replace('Button("Transcribe', 'Button("Copy text") { model.copyTranscript() }; Button("Transcribe'))
        self.assertEqual([], self.errors(before))

    def test_views_embedded_in_the_panel_are_status_rows(self):
        before = self.registry()
        self.file.write_text(PANEL % 'MeetingQuickStatus(model: meetings) { open("meeting") }; Button("Read") { read() }')
        self.write('LocalVoice/MeetingWorkspaceView.swift', '''
          struct MeetingQuickStatus: View { var body: some View { Button(isRecording ? "Meeting · recording" : "Meeting · processing") {}; Button("Stop") {} } }
          struct MeetingWorkspaceView: View { var body: some View { Button("Start") {} } }''')
        added = [e for e in self.entries() if e['surface'] == 'quick panel status rows']
        self.assertEqual({None, 'Stop'}, {e['label'] for e in added})
        self.assertNotIn('Start', self.labels())
        self.assertIn('Unregistered entry on quick panel status rows', '\n'.join(self.errors(before)))

    def test_settings_page_counts_its_controls_and_embedded_views(self):
        self.write('LocalVoice/WorkbenchHome.swift', '''struct WorkbenchHome: View {
          private var settings: some View {
            Text("Make yourself at home."); Label("Photo handoff", systemImage: "icloud")
            Toggle("Open Workbench at login", isOn: $x); Button("Your dictionary") {}; MeetingDetectionSettings(model: m)
          }
        }''')
        self.write('LocalVoice/MeetingWorkspaceView.swift', '''struct MeetingDetectionSettings: View {
          var body: some View { Toggle("Detect Meetings & Calls", isOn: $on); Button("Review") {} }
        }''')
        settings = [e['label'] for e in self.entries() if e['surface'] == 'settings page']
        self.assertEqual(['Detect Meetings & Calls', 'Open Workbench at login', 'Review', 'Your dictionary'], sorted(settings))

    def test_offers_are_found_by_name(self):
        self.write('LocalVoice/MeetingWorkspaceView.swift', '''final class MeetingOfferPanelController {
          init() { panel.contentView = NSHostingView(rootView: HStack { Button("Review") {}; Button("Not now") {} }) }
        }''')
        offers = {e['label'] for e in self.entries() if e['surface'] == 'proactive offer MeetingOfferPanelController'}
        self.assertEqual({'Review', 'Not now'}, offers)

    def test_choice_lists_are_recorded_once(self):
        self.write('StageKit/FloatingControlGeometry.swift', '''enum FloatingControlAnchor: String, CaseIterable {
          case top, bottom
          var title: String { switch self { case .top: return "Top centre"; case .bottom: return "Bottom centre" } }
        }''')
        self.write('StageKit/StageKitController.swift', '''final class StageKitController {
          func makeTimerMenu() -> NSMenu {
            menu.addSubmenu("Position", items: FloatingControlAnchor.allCases.map { anchor in StageMenuAction(anchor.title) { set(anchor) } })
            return menu
          }
          func makePersonaMenu() -> NSMenu {
            menu.addSubmenu("Position Artwork", items: FloatingControlAnchor.allCases.map { StageMenuAction($0.title) { set($0) } })
            return menu
          }
        }''')
        entries = self.entries()
        self.assertEqual(['choices.FloatingControlAnchor.bottom', 'choices.FloatingControlAnchor.top'],
                         sorted(e['id'] for e in entries if e['id'].startswith('choices.')))
        self.assertEqual({'Position', 'Position Artwork', 'Top centre', 'Bottom centre', 'Read'}, set(self.labels()))

    def test_runtime_lists_hints_and_helper_parameters_are_not_entries(self):
        self.write('StageKit/Persona.swift', '''final class PersonaLibrary {
          func makeControlsMenu() -> NSMenu {
            func action(_ title: String, _ operation: Op) -> NSMenuItem { StageMenuAction(title) { perform(operation) } }
            menu.addSubmenu("Choose Set", items: state.groups.map { action($0.label, .select($0.id)) })
            for scene in scenes { menu.addItem(StageMenuAction(scene.name) { start(scene) }) }
            menu.addItem(StageMenuAction("Prepare a persona in Workbench first.", enabled: false) {})
            let custom = NSMenuItem(title: "Custom \\(hex)", action: nil, keyEquivalent: ""); custom.isEnabled = false; menu.addItem(custom)
            let colours = NSMenuItem(title: "Ink Colour", action: nil, keyEquivalent: ""); colours.submenu = inks; menu.addItem(colours)
            menu.addItem(action("End Overlays", .end))
            return menu
          }
        }''')
        persona = sorted(e['label'] for e in self.entries() if e['surface'] == 'Persona menu')
        self.assertEqual(['Choose Set', 'End Overlays', 'Ink Colour'], persona)

    def test_enum_titles_worded_into_an_item_are_entries(self):
        self.write('StageKit/NativePresentationApps.swift', '''enum NativePresentationApp: String, CaseIterable {
          case quickTime, iPhoneMirroring
          var title: String { self == .quickTime ? "QuickTime Player" : "iPhone Mirroring" }
        }''')
        self.write('StageKit/DemoPresentation.swift', '''final class DemoPresentation {
          func makeControlsMenu() -> NSMenu {
            for app in NativePresentationApp.allCases { menu.addItem(StageMenuAction("End Preview & Open \\(app.title)") { open(app) }) }
            return menu
          }
        }''')
        self.assertIn('End Preview & Open QuickTime Player', self.labels())
        before = self.registry()
        owner = self.root / 'Sources/StageKit/NativePresentationApps.swift'
        owner.write_text(owner.read_text().replace('"QuickTime Player"', '"QuickTime"'))
        self.assertIn('Changed entry on Present menu: "End Preview & Open QuickTime".', '\n'.join(self.errors(before)))

    def test_numbers_in_a_literal_list_are_entries(self):
        timer = self.write('StageKit/StageKitController.swift', '''final class StageKitController {
          func makeTimerMenu() -> NSMenu {
            menu.addSubmenu("Duration", items: [1, 5].map { minutes in StageMenuAction("\\(minutes) min") { set(minutes) } })
            return menu
          }
        }''')
        self.assertEqual({'Duration', '1 min', '5 min', 'Read'}, set(self.labels()))
        before = self.registry()
        timer.write_text(timer.read_text().replace('[1, 5]', '[1, 5, 45]'))
        self.assertIn('Unregistered entry on Timer menu: "45 min".', '\n'.join(self.errors(before)))

    def test_navigation_on_home_settings_and_the_sidebar_is_an_entry(self):
        home = self.write('LocalVoice/WorkbenchHome.swift', '''struct WorkbenchHome: View {
          private let navItems: [(String, String, String)] = [("home", "Home", "house")]
          var body: some View {
            ForEach(navItems, id: \\.0) { page, title, symbol in Button { go(page) } label: { Label(title, systemImage: symbol) } }
            Button(updates.buttonTitle) { page = "settings" }
            switch page { case "snap": SnapWorkspaceView(); default: welcome }
          }
          private var welcome: some View { Button("Try the keyboard") { page = "shortcuts" }; Label("Free tools", systemImage: "checkmark") }
          private var settings: some View { Button("Your dictionary") { page = "dictionary" } }
        }''')
        self.write('LocalVoice/SnapWorkspaceView.swift', 'struct SnapWorkspaceView: View { var body: some View { Button("Crop") {} } }')
        surfaces = {(e['surface'], e['label']) for e in self.entries()}
        for entry in [('window sidebar', 'Home'), ('window sidebar', None), ('window home', 'Try the keyboard'),
                      ('settings page', 'Your dictionary')]:
            self.assertIn(entry, surfaces)
        self.assertNotIn('Crop', self.labels())
        self.assertNotIn('Free tools', self.labels())
        before = self.registry()
        home.write_text(home.read_text().replace('Button("Your dictionary")', 'Button("Packs") { page = "packs" }; Button("Your dictionary")')
                        .replace('Button(updates.buttonTitle)', 'Button("Guide") { openGuide() }; Button(updates.buttonTitle)'))
        errors = '\n'.join(self.errors(before))
        self.assertIn('Unregistered entry on settings page: "Packs".', errors)
        self.assertIn('Unregistered entry on window sidebar: "Guide".', errors)

    def test_capture_preview_buttons_on_home_are_entries_but_not_page_doors(self):
        self.write('LocalVoice/WorkbenchHome.swift', '''struct WorkbenchHome: View {
          var body: some View { switch page { case "snap": SnapWorkspaceView(); default: welcome } }
          private var welcome: some View {
            CapturePreviewButton("View \\(item.title)", item: { .snap(item) }) { HomeSnapThumbnail() }
            CapturePreviewButton("View latest Snap", item: { .snap(item) }) { HomeSnapThumbnail() }
          }
        }''')
        self.write('LocalVoice/SnapWorkspaceView.swift', '''struct SnapWorkspaceView: View {
          var body: some View { CapturePreviewButton("View card", item: { .snap(item) }) { SnapThumbnail() } }
        }''')
        home = [e for e in self.entries() if e['surface'] == 'window home']
        self.assertIn('View latest Snap', [e['label'] for e in home])
        self.assertTrue(any(e['label'] is None and 'item.title' in e.get('expression', '') for e in home))
        self.assertNotIn('View card', self.labels())

    def test_native_views_in_menus_are_followed(self):
        self.write('StageKit/Persona.swift', '''final class PersonaLibrary {
          func makeControlsMenu() -> NSMenu { let size = NSMenuItem(); size.view = PersonaSizeMenuView(width: 0.2) { set($0) }; menu.addItem(size); return menu }
        }''')
        self.write('StageKit/ActivityMenus.swift', '''final class PersonaSizeMenuView: NSView {
          init(width: Double, change: @escaping (Double) -> Void) { slider.setAccessibilityLabel("Persona Size"); label.setAccessibilityLabel(title) }
        }''')
        self.assertEqual([('Persona menu', 'Persona Size')], [(e['surface'], e['label']) for e in self.entries() if e['label'] != 'Read'])

    def test_fixed_actions_inside_a_list_of_content_are_entries(self):
        scenes = self.write('StageKit/DemoScenes.swift', '''final class DemoScenes {
          func makeControlsMenu() -> NSMenu {
            for scene in scenes { menu.addItem(StageMenuAction(scene.name) { start(scene) }) }
            return menu
          }
        }''')
        before = self.registry()
        scenes.write_text(scenes.read_text().replace('start(scene) }) }', 'start(scene) }); menu.addItem(StageMenuAction("Inspect source") { inspect(scene) }) }'))
        self.assertEqual({'Read', 'Inspect source'}, set(self.labels()))
        self.assertIn('Unregistered entry on Present menu: "Inspect source".', '\n'.join(self.errors(before)))

    def test_a_control_keeps_its_id_whether_its_label_is_an_argument_or_a_view(self):
        home = self.write('LocalVoice/WorkbenchHome.swift', '''struct WorkbenchHome: View {
          private var settings: some View { Toggle("Show floating toolbar", isOn: $visible) }
        }''')
        self.file.write_text(PANEL % 'Button("Stop") { stop() }')
        before = self.registry()
        home.write_text(home.read_text().replace('Toggle("Show floating toolbar", isOn: $visible)',
                                                 'Toggle(isOn: $visible) { Label("Show floating toolbar", systemImage: "rectangle") }'))
        self.file.write_text(PANEL % 'Button { stop() } label: { Text("Stop") }')
        self.assertEqual([], self.errors(before))
        home.write_text(home.read_text().replace('Toggle(isOn:', 'Toggle(isOn: $shown) { Label("Show timer", systemImage: "timer") }; Toggle(isOn:'))
        self.assertIn('Unregistered entry on settings page: "Show timer".', '\n'.join(self.errors(before)))

    def test_stale_entries_ask_for_confirmation(self):
        registered = self.registry()
        self.file.write_text('struct WorkbenchQuickPanel: View {}')
        self.assertIn('Confirm it is really gone', '\n'.join(self.errors(registered)))

    def test_new_enum_choice_and_catalogue_rename_are_visible(self):
        self.file.write_text(PANEL % '''
          Picker("Delivery", selection: $value) { ForEach(DeliveryMode.allCases, id: \\.self) { Text($0.rawValue).tag($0) } }''')
        owner = self.write('LocalVoice/VoicePreferences.swift', 'enum DeliveryMode: String, CaseIterable { case paste = "Paste" }')
        before = self.registry()
        owner.write_text('enum DeliveryMode: String, CaseIterable { case paste = "Paste automatically", copy = "Copy" }')
        errors = '\n'.join(self.errors(before))
        self.assertIn('Changed entry on choices DeliveryMode: "Paste automatically"', errors)
        self.assertIn('Unregistered entry on choices DeliveryMode: "Copy"', errors)

    def test_qualified_enum_does_not_match_unrelated_short_name(self):
        self.file.write_text(PANEL % '''
          Picker("Status", selection: $value) { ForEach(ImportReview.Status.allCases) { Text($0.title).tag($0) } }''')
        self.write('LocalVoice/MeetingModels.swift', 'enum Status: String, CaseIterable { case recording = "Recording" }')
        self.assertNotIn('Recording', self.labels())

    def test_registry_schema_and_duplicate_ids(self):
        entry = {**self.registry()[0], 'kind': 'mystery', 'belongsTo': 'workspace'}
        errors = '\n'.join(self.errors([entry, entry]))
        self.assertIn('Invalid kind', errors)
        self.assertIn('Invalid belongsTo', errors)
        self.assertIn('Duplicate registry id', errors)

    def test_raw_literal(self):
        self.file.write_text(PANEL % 'Button(#"Read"#) {}')
        self.assertEqual(['Read'], self.labels())

    def test_sidebar_tuples_and_quick_panel_rows(self):
        self.write('LocalVoice/WorkbenchHome.swift', '''struct WorkbenchHome: View {
          private let navItems: [(String, String, String)] = [("annotate", "Annotate", "pen")]
        }''')
        self.write('LocalVoice/WorkbenchControlTool.swift', '''enum WorkbenchControlTool: String, CaseIterable {
          case snap, read
          var title: String { switch self { case .snap: return "Snap & Talk"; case .read: return "Read" } }
        }''')
        self.file.write_text(PANEL % 'ForEach(WorkbenchControlTool.allCases) { tool in Button { perform(tool) } label: { Text(tool.title) } }')
        entries = {e['id']: e for e in self.entries()}
        self.assertEqual('annotate', entries['LocalVoice.WorkbenchHome.WorkbenchHome.sidebar.annotate']['page'])
        self.assertEqual(('Snap & Talk', 'snap'), (entries['quick-panel.row.snap']['label'], entries['quick-panel.row.snap']['case']))
        self.assertEqual(3, len(entries))  # No second entry for each row's Text(tool.title).

    def test_page_record_sections_are_doors_to_their_routes(self):
        home = self.write('LocalVoice/WorkbenchHome.swift', '''struct WorkbenchHome: View {
          static let navItems: [(id: String, title: String, symbol: String)] = [("settings", "Settings", "gear")]
          static let sections: [(id: String, page: String, title: String)] = [("settings", "settings", "General"), ("shortcuts", "settings", "Keyboard")]
          static let subpages: [(id: String, page: String, title: String)] = [("meeting", "dictate", "Transcribe meeting or call")]
        }''')
        entries = {e['id']: e for e in self.entries()}
        keyboard = entries['LocalVoice.WorkbenchHome.WorkbenchHome.section.shortcuts']
        self.assertEqual(('page sections', 'Keyboard', 'shortcuts'), (keyboard['surface'], keyboard['label'], keyboard['page']))
        self.assertEqual('General', entries['LocalVoice.WorkbenchHome.WorkbenchHome.section.settings']['label'])
        self.assertEqual('settings', entries['LocalVoice.WorkbenchHome.WorkbenchHome.sidebar.settings']['page'])
        self.assertNotIn('Transcribe meeting or call', self.labels(), 'a subpage has no control of its own')
        before = self.registry()
        home.write_text(home.read_text().replace('("shortcuts", "settings", "Keyboard")]', '("shortcuts", "settings", "Keyboard"), ("models", "settings", "Models")]'))
        self.assertIn('Unregistered entry on page sections: "Models".', '\n'.join(self.errors(before)))

    def test_menu_page_items_take_their_names_from_the_page_record(self):
        home = self.write('LocalVoice/WorkbenchHome.swift', '''struct WorkbenchHome: View {
          static let navItems: [(id: String, title: String, symbol: String)] = [("readback", "Snap & Talk", "x"), ("settings", "Settings", "y")]
          static let sections: [(id: String, page: String, title: String)] = [("settings", "settings", "General"), ("shortcuts", "settings", "Keyboard")]
          static let subpages: [(id: String, page: String, title: String)] = [("meeting", "dictate", "Transcribe meeting or call")]
        }''')
        self.write('LocalVoice/main.swift', '''class AppDelegate {
          func makeMainMenu() {
            appMenu.addItem(pageItem("settings", more: true, key: ",")); appMenu.addItem(pageItem("shortcuts", more: true))
            menu.addItem(pageItem("readback")); menu.addItem(pageItem("meeting", more: true))
          }
          private func pageItem(_ route: String, more: Bool = false, key: String = "") -> NSMenuItem {
            NSMenuItem(title: WorkbenchHome.name(of: route) + (more ? "…" : ""), action: #selector(openPage(_:)), keyEquivalent: key)
          }
        }''')
        items = {e['page']: e['label'] for e in self.entries() if e['surface'] == 'app menu bar'}
        self.assertEqual({'settings': 'Settings…', 'shortcuts': 'Keyboard…', 'readback': 'Snap & Talk',
                          'meeting': 'Transcribe meeting or call…'}, items)
        before = self.registry()
        home.write_text(home.read_text().replace('"Snap & Talk", "x"', '"Snap & Talk sessions", "x"'))
        self.assertIn('Changed entry on app menu bar: "Snap & Talk sessions".', '\n'.join(self.errors(before)))

    def test_a_menu_door_that_names_its_page_differently_is_drift(self):
        self.write('LocalVoice/WorkbenchHome.swift', '''struct WorkbenchHome: View {
          static let navItems: [(id: String, title: String, symbol: String)] = [("readback", "Snap & Talk", "x"), ("history", "History", "y"), ("settings", "Settings", "z")]
          static let sections: [(id: String, page: String, title: String)] = [("settings", "settings", "General"), ("shortcuts", "settings", "Keyboard")]
        }''')
        self.write('LocalVoice/main.swift', '''class AppDelegate {
          func makeMainMenu() {
            appMenu.addItem(withTitle: "Check for Updates…", action: #selector(showUpdates), keyEquivalent: "")
            appMenu.addItem(withTitle: "Keyboard shortcuts…", action: #selector(showShortcuts), keyEquivalent: "")
            appMenu.addItem(pageItem("settings", more: true, key: ","))
            menu.addItem(withTitle: "Snap & Talk sessions", action: #selector(showReadback), keyEquivalent: "")
            menu.addItem(withTitle: "History…", action: #selector(showHistory), keyEquivalent: "")
            menu.addItem(withTitle: "Draw menu", action: #selector(showAnnotationMenu), keyEquivalent: "")
            menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
          }
          private func pageItem(_ route: String, more: Bool = false, key: String = "") -> NSMenuItem {
            NSMenuItem(title: WorkbenchHome.name(of: route) + (more ? "…" : ""), action: #selector(openPage(_:)), keyEquivalent: key)
          }
          @objc func showUpdates() { showSettings(); checkForUpdates() }
          @objc func showSettings() { model.page = "settings"; showWindow() }
          @objc func showShortcuts() { navigate("shortcuts") }
          @objc func showReadback() { model.page = "readback"; showWindow() }
          @objc func showHistory() { model.openHistory(); showWindow() }
          @objc func showAnnotationMenu() { guard let button else { model.page = "annotate"; return }; show(button) }
        }''')
        pages = {e['label']: e.get('page') for e in self.entries() if e['surface'] == 'app menu bar'}
        self.assertEqual({'Check for Updates…': None, 'Keyboard shortcuts…': 'shortcuts', 'Settings…': 'settings',
                          'Snap & Talk sessions': 'readback', 'History…': 'history', 'Draw menu': None, 'Close Window': None}, pages)
        errors = '\n'.join(self.errors())
        self.assertIn('Menu name drift on app menu bar: "Snap & Talk sessions" opens Snap & Talk (readback)', errors)
        self.assertIn('Menu name drift on app menu bar: "Keyboard shortcuts…" opens Keyboard (shortcuts)', errors)
        self.assertEqual(2, errors.count('Menu name drift'), 'History… adds only the ellipsis; the others are actions')

    def test_a_subpage_door_is_named_from_the_record_too(self):
        self.write('LocalVoice/WorkbenchHome.swift', '''struct WorkbenchHome: View {
          static let navItems: [(id: String, title: String, symbol: String)] = [("dictate", "Dictate", "mic")]
          static let subpages: [(id: String, page: String, title: String)] = [("meeting", "dictate", "Transcribe meeting or call")]
        }''')
        main = self.write('LocalVoice/main.swift', '''class AppDelegate {
          func makeMainMenu() { menu.addItem(withTitle: "Transcribe a meeting or call…", action: #selector(showMeeting), keyEquivalent: "") }
          @objc func showMeeting() { model.page = "meeting"; showWindow() }
        }''')
        registry, names = self.registry(), check.Tree(self.root).page_names()
        self.assertEqual('Transcribe meeting or call', names['meeting'])
        self.assertIn('Menu name drift on app menu bar: "Transcribe a meeting or call…" opens Transcribe meeting or call (meeting)',
                      '\n'.join(check.compare(self.entries(), registry, names)))
        main.write_text(main.read_text().replace('"Transcribe a meeting or call…"', '"Transcribe meeting or call…"'))
        self.assertNotIn('Menu name drift', '\n'.join(check.compare(self.entries(), self.registry(), names)))

    def test_a_hand_written_item_cannot_open_a_page_through_open_page(self):
        self.write('LocalVoice/main.swift', '''class AppDelegate {
          func makeMainMenu() { menu.addItem(pageItem("history")); menu.addItem(withTitle: "Snap & Talk sessions", action: #selector(openPage(_:)), keyEquivalent: "") }
          private func pageItem(_ route: String, more: Bool = false, key: String = "") -> NSMenuItem {
            NSMenuItem(title: WorkbenchHome.name(of: route) + (more ? "…" : ""), action: #selector(openPage(_:)), keyEquivalent: key)
          }
        }''')
        with self.assertRaisesRegex(ValueError, 'opens a page through openPage by hand'):
            self.entries()

    def test_the_keyboard_section_is_the_catalogue_editor(self):
        self.write('LocalVoice/WorkbenchHome.swift', '''struct WorkbenchHome: View {
          private var settings: some View { KeyboardCoachView(model: keyboard); Toggle("Open Workbench at login", isOn: $x) }
        }''')
        self.write('LocalVoice/KeyboardCoach.swift', '''struct KeyboardCoachView: View {
          var body: some View { Button("Record shortcut") {}; Button("Practice") {} }
        }''')
        self.assertEqual(['Open Workbench at login'], [e['label'] for e in self.entries() if e['surface'] == 'settings page'])

    def test_voice_and_stage_shortcuts_have_stable_ids(self):
        self.write('LocalVoice/main.swift', '''class AppDelegate {
          func voiceShortcutEntries() -> [ShortcutEntry] { [(UInt32(1), "Dictate"), (UInt32(8), "New action")].map { id, title in entry(id, title) } }
        }''')
        self.write('StageKit/Settings.swift', '''enum Action: String, CaseIterable {
          case timer
          var title: String { switch self { case .timer: return "Break timer" } }
        }''')
        entries = {e['id']: e for e in self.entries()}
        self.assertEqual('New action', entries['shortcut.voice.8']['label'])
        self.assertEqual('Break timer', entries['shortcut.stage.timer']['label'])

    def test_missing_owner_is_an_error(self):
        with self.assertRaisesRegex(ValueError, 'Missing surface owner'):
            check.derive(self.root)

    def test_cli_root_uses_explicit_registry_and_update_exits_nonzero(self):
        owners = {}
        for relative, scope, *_ in check.ENTRY_POINTS + check.CATALOGUES:
            owners.setdefault(relative, []).append(scope)
        for relative, scopes in owners.items():
            if relative == 'LocalVoice/WorkbenchQuickPanel.swift':
                continue
            body = []
            for scope in {s for s in scopes if s}:
                parts = scope.split('.')
                kind = 'enum' if parts[0] in ('ToolbarMode', 'Action') else 'struct'
                inner = f'func {parts[1]}() {{}}' if len(parts) > 1 else ''
                body.append(f'{kind} {parts[0]} {{ {inner} }}')
            if relative.endswith('WorkbenchHome.swift'):
                body = ['struct WorkbenchHome { let navItems = []; var body: some View {}; private var welcome: some View {}; private var settings: some View {} }']
            self.write(relative, '\n'.join(body) + '\n')
        registry = self.root / 'registry.json'
        result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root), '--registry', str(registry), '--update'], capture_output=True, text=True)
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertEqual('unclassified', json.loads(registry.read_text())[0]['kind'])
        registry.write_text(json.dumps(self.registry()))
        result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root), '--registry', str(registry)], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('Surface registry OK', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
