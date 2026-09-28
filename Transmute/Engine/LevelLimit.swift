//
//  LevelLimit.swift
//  Transmute
//
//  A ceiling for the synth's peak - the author's spec (2026-09-26): a max level in
//  Settings, in 0.5 dB steps, and a button that lowers every pad whose
//  peak is above it; the batch window can apply the same to every file.
//
//  Lowering, never raising: a pad under the ceiling stays as it is. And it
//  is done with Level (`gainDB`), not by scaling the samples on the way
//  out: the synth multiplies its whole output by the gain last (fade
//  included), so its peak moves dB for dB with Level, and the panel shows
//  what the file holds.
//
//  The peak is measured where it is heard and where it is written - at the
//  analysis rate the window's Peak shows, and at the rate the file is
//  exported at - and the higher of the two decides, so neither the readout
//  nor the file ends up above the ceiling. The two differ by a fraction of
//  a dB on a click whose peak falls between samples.
//

import Foundation

nonisolated enum LevelLimit {
    static let defaultDB = -1.5
    static let range = -12.0...0.0
    static let step = 0.5

    /// `db` on the 0.5 dB grid, inside `range`.
    static func snapped(_ db: Double) -> Double {
        guard db.isFinite else { return defaultDB }
        return min(max((db / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    /// The highest sample of `params` rendered at `sampleRate`, in dBFS.
    static func peakDB(_ params: DrumParams, sampleRate: Double) -> Double {
        let peak = DrumSynth.renderAudio(params, sampleRate: sampleRate).peak
        return 20 * log10(max(Double(peak), 1e-9))
    }

    /// `params` with Level lowered so that its peak at every rate in
    /// `rates` is at most `maxDB`; nil when it already is.
    static func limited(_ params: DrumParams, maxDB: Double, rates: [Double]) -> DrumParams? {
        let peak = rates.map { peakDB(params, sampleRate: $0) }.max() ?? -.infinity
        // A thousandth of a dB is Float rounding, not an overshoot.
        guard peak > maxDB + 0.001 else { return nil }
        var lowered = params
        lowered.gainDB -= peak - maxDB
        return lowered
    }
}
