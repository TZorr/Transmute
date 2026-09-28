//
//  ExportBoxes.swift
//  Transmute
//
//  The export, as two boxes at the bottom right: format and bit depth -
//  DropMaster's boxes, with Transmute's five lossless formats.
//
//  The format box is a split button: its face does the thing ("Export
//  WAV / PCM"), its arrow picks another format. The depth box is a
//  pull-down Menu around an inline Picker, not a bare Picker: a bare one
//  is an NSPopUpButton, which opens with the selected item laid over the
//  button and can unfold upwards off the window.
//

import SwiftUI

struct ExportBoxes: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Format", selection: $model.exportFormat) {
                    ForEach(OutputFormat.allCases) { format in
                        Text(format.menuTitle).tag(format)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Export \(model.exportFormat.menuTitle)", systemImage: "square.and.arrow.up")
            } primaryAction: {
                model.export()
            }
            .fixedSize()
            .help(formatHelp)

            Menu {
                Picker("Bit depth", selection: $model.exportQuality) {
                    ForEach(model.exportFormat.qualityOptions) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(model.exportQuality.label)
            }
            .fixedSize()
            .help("Bit depth of the export")
        }
        .disabled(!model.canExport)
    }

    private var formatHelp: String {
        let exportRate = model.pad.exportRate
        let rate = exportRate.truncatingRemainder(dividingBy: 1000) == 0
            ? String(format: "%.0f kHz", exportRate / 1000) : String(format: "%.1f kHz", exportRate / 1000)
        return "Export the selected pad's synth as \(model.exportFormat.menuTitle), mono, \(rate) - the source's rate (⌘E); the arrow picks another format. Lossless formats only: a lossy codec puts silence in front of the hit."
    }
}
