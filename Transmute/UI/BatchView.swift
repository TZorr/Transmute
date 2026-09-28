//
//  BatchView.swift
//  Transmute
//
//  The Batch Convert window (File › Batch Convert…): the settings for the
//  whole batch on top - model, prefix, format and depth, max level - the
//  files below, each with the name it will be written as and how far it
//  got. The whole list is the drop target, empty or not. Where the files
//  go is asked when Convert is pressed (BatchModel.askForFolder).
//
//  Format and depth are the main window's export boxes' own (one setting,
//  two places), so a batch and Export Kit write the same kind of file.
//

import SwiftUI

struct BatchView: View {
    @Bindable var app: AppModel
    @Bindable var batch: BatchModel
    @State private var targeted = false

    init(app: AppModel) {
        self.app = app
        self.batch = app.batch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            settings
            list
            footer
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 440)
    }

    // MARK: - Settings

    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Model").gridColumnAlignment(.trailing)
                HStack(spacing: 16) {
                    Menu {
                        Picker("Model", selection: $batch.modelChoice) {
                            Text("Automatic").tag(DrumModel?.none)
                            ForEach(DrumModel.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Text(batch.modelChoice?.title ?? "Automatic")
                    }
                    .fixedSize()
                    .help("The voice every file is rebuilt with. Automatic lets each sample's analysis choose; a model chosen here analyses and fits every file as that drum - Clap: all of them as claps.")
                    HStack(spacing: 6) {
                        Text("Prefix")
                        TextField(BatchConvert.defaultPrefix, text: $batch.prefix)
                            .frame(width: 200)
                    }
                    .help("Files are named \"<prefix> <number>\", numbered in the list's order - by name, as the Finder sorts.")
                }
                .disabled(batch.running)
            }
            GridRow {
                Text("Format")
                HStack(spacing: 16) {
                    formatMenus
                    Toggle("Limit peaks to \(app.maxLevelLabel)", isOn: $batch.limitToMax)
                        .help("Lower a file's Level until its peak is at the max level, if it is above it - never raise it. The max level is set in Settings.")
                }
                .disabled(batch.running)
            }
        }
        .font(.callout)
    }

    private var formatMenus: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Format", selection: $app.exportFormat) {
                    ForEach(OutputFormat.allCases) { Text($0.menuTitle).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(app.exportFormat.menuTitle)
            }
            .fixedSize()
            Menu {
                Picker("Bit depth", selection: $app.exportQuality) {
                    ForEach(app.exportFormat.qualityOptions) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(app.exportQuality.label)
            }
            .fixedSize()
        }
        .help("Mono, at each source's own rate - the main window's export format and depth.")
    }

    // MARK: - Files

    private var list: some View {
        Group {
            if batch.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 28))
                    Text("Drop audio files or folders here, or use Add Files…")
                    Text("They are sorted by name and converted in that order.")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(batch.items.enumerated()), id: \.element.id) { position, item in
                        row(item, position: position)
                            .contextMenu {
                                Button("Remove from List") { batch.remove(item.id) }
                                    .disabled(batch.running)
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(targeted ? 0.08 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor.opacity(targeted ? 0.8 : 0), lineWidth: 2))
        .dropDestination(for: URL.self) { urls, _ in
            batch.add(urls)
            return !batch.running
        } isTargeted: { targeted = $0 && !batch.running }
    }

    private func row(_ item: BatchModel.Item, position: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(position + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(batch.fileName(at: position)).lineLimit(1)
                Text(item.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            status(item.status)
        }
        .font(.callout)
        .help(item.url.path(percentEncoded: false))
    }

    @ViewBuilder
    private func status(_ status: BatchModel.Status) -> some View {
        switch status {
        case .waiting:
            EmptyView()
        case .queued:
            Text("Waiting").foregroundStyle(.secondary)
        case .converting(let fraction):
            ProgressView(value: fraction).frame(width: 120)
        case .done(let detail):
            Text(detail).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        case .failed(let error):
            Text(error).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail).help(error)
        case .stopped:
            Text("Stopped").foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(batch.items.isEmpty ? "No files" : "\(batch.items.count) file\(batch.items.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            Button("Add Files…") { batch.chooseFiles() }
                .disabled(batch.running)
                .help("Add audio files or folders - the same as dropping them on the list")
            Button("Clear List") { batch.removeAll() }
                .disabled(batch.running || batch.items.isEmpty)
            Spacer()
            if let message = batch.message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if batch.running {
                Button("Stop") { batch.stop() }
            }
            Button("Convert") { batch.convert() }
                .keyboardShortcut(.defaultAction)
                .disabled(!batch.canConvert)
                .help("Choose the folder the files are written to - or make a new one there - then convert every file in the list")
        }
        .font(.callout)
    }
}
