//
//  TransmuteApp.swift
//  Transmute
//
//  A recorded drum hit in, a synthesised one out: Transmute measures a
//  kick or a tom - its pitch sweep, its decay, its click, its noise - and
//  rebuilds it from a small synth voice, which can then be edited and
//  exported as a clean, noise-free sample.
//
//  Native all the way down: Accelerate for the analysis, a pure Swift
//  function for the synth, AVAudioEngine only to listen. No SuperCollider
//  or any other server - the fit renders the drum a couple of thousand
//  times per sample, which only a function in the same process can afford
//  (see DrumSynth).
//
//  One window: sixteen pads, each its own drum, playable by click or MIDI;
//  the panel edits the selected one. A second, Batch Convert, turns a
//  list of samples into synth files without the pads. The commands below mirror the
//  window's controls, so everything can be done from the keyboard too.
//

import SwiftUI

@main
struct TransmuteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Transmute", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Kit") { model.newKit() }
                    .keyboardShortcut("n")
                Button("Open Kit…") { model.openKit() }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Button("Save Kit…") { model.saveKit() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("Open Sample…") { model.chooseSample() }
                    .keyboardShortcut("o")
                Button("Open Parameters…") { model.openParams() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Save Parameters…") { model.saveParams() }
                    .keyboardShortcut("s")
                    .disabled(!model.pad.hasSynth)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Export \(model.exportFormat.menuTitle) · \(model.exportQuality.label)…") { model.export() }
                    .keyboardShortcut("e")
                    .disabled(!model.canExport)
                Button("Export Kit…") { model.exportKit() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(!model.canExportKit)
                Button("Export Kitbox Kit…") { model.exportKitboxKit() }
                    .keyboardShortcut("e", modifiers: [.command, .option, .shift])
                    .disabled(!model.canExportKit)
                Divider()
                BatchMenuItem()
            }
            CommandMenu("Drum") {
                Button("Play Original") { model.player.play(.original) }
                    .keyboardShortcut("1")
                    .disabled(model.pad.original == nil)
                Button("Play Synth") { model.player.play(.synth) }
                    .keyboardShortcut("2")
                    .disabled(!model.pad.hasSynth)
                Button("Play Again") { model.player.replay() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!model.pad.hasSynth)
                Divider()
                Button("Fit Again") { model.pad.refit() }
                    .keyboardShortcut("r")
                    .disabled(!model.pad.canFit)
                Button("Reset to Fit") { model.pad.resetToFit() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.pad.canReset)
                Divider()
                // The keys themselves are caught by AppModel's Tab monitor:
                // a menu key equivalent of plain Tab never fires (the window
                // takes Tab first). The shortcuts here only label the items.
                Button("Next Pad") { model.selectPad(offset: 1) }
                    .keyboardShortcut(.tab, modifiers: [])
                Button("Previous Pad") { model.selectPad(offset: -1) }
                    .keyboardShortcut(.tab, modifiers: [.shift])
                Divider()
                Button("Clear Pad") { model.pad.clear() }
                    .disabled(model.pad.isEmpty)
                Button("Clear All Pads") { model.clearAllPads() }
                    .disabled(!model.hasAnyDrum)
                Button("Reset All…") { model.resetAll() }
                Divider()
                Button("Limit Peaks to \(model.maxLevelLabel)") { model.limitPeaks() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(!model.hasAnyDrum)
            }
        }

        Window("Batch Convert", id: BatchMenuItem.windowID) {
            BatchView(app: model)
        }
        .defaultSize(width: 760, height: 560)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// File › Batch Convert…: a view, for the environment's openWindow. Its
/// window id also serves the main window's Batch Convert… button.
struct BatchMenuItem: View {
    static let windowID = "batch"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Batch Convert…") { openWindow(id: Self.windowID) }
            .keyboardShortcut("b", modifiers: [.command, .shift])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
