//
//  Analyzer.swift
//  Transmute
//
//  A recorded drum hit in, a first guess at its DrumParams out - measured
//  straight off the waveform, one parameter at a time. The Fitter then
//  improves the guess by listening; this file's job is to start it close
//  enough that it cannot wander off into the wrong drum.
//
//  In order:
//  1. Onset and end. The hit starts at the zero crossing just before the
//     signal first rises above the noise, and ends where it sinks into the
//     noise floor - which on a vinyl sample is crackle and hiss, not
//     silence. Everything after this works on that trimmed hit.
//  2. Where the pitch settles: the strongest peak of the tail's spectrum,
//     interpolated between bins.
//  3. The pitch sweep, from zero crossings. Not from an STFT: at 58 Hz one
//     period is 17 ms, a 2048-point window 43 ms, and the whole sweep may
//     be over in 70. Each pair of same-direction crossings of the low-passed
//     body is one period, so every cycle yields a measurement at its own
//     time. A curve f₁ + (f₀ − f₁)·e^(−t/τ) is fitted through them: a grid
//     over τ, and for each τ the two frequencies by weighted least squares.
//  4. The envelope's decay. The body's analytic envelope is fitted with
//     A·exp(−(t/τ)^k): a grid over the shape k, and for each k the level A
//     and the rate by least squares on the log envelope.
//  5. The start phase, by least squares against a sine and a cosine body
//     with the measured pitch and envelope.
//  6. Click and noise, from what is left: the original minus the body just
//     measured. Its first 5 ms are the click, the rest (high-passed above
//     the body) the noise, with the recording's own noise floor subtracted
//     first - otherwise the hiss of the record would be modelled as a very
//     long noise decay.
//
//  Drive is not guessed here: the Fitter tries a few values by ear, which
//  is more reliable than reading harmonics that the record itself may have
//  added.
//
//  Which model (DrumParams.model) is measured is the caller's choice, or,
//  without one, suggested from the hit: a snare is a hit whose first
//  200 ms have more than −17.5 dB of their energy above 2 kHz (see
//  `suggestModel`). A snare changes three steps:
//  - 3: the body is low-passed at 1.25 times the tail frequency instead of
//    six times - the second head mode (1.5-2.8 times the first on the four
//    snares measured) and the wires would otherwise cut the zero crossings
//    (the 909 came out at 27 Hz with the kick's filter),
//  - 6: the second mode is found in the residual's spectrum between 1.2
//    and 4 times the body's pitch, its level and decay from its band's
//    envelope,
//  - 6: the wires are measured above the second mode: their level, decay
//    and shape with the same fit as the body's envelope, their band from
//    where the power lies.
//  A clap - four or more evenly spaced bursts above 1 kHz - has no body and
//  no pitch (see `analyzeClap`): its bursts are timed and measured off the
//  envelope, its tail fitted like the wires, its band measured like theirs.
//  A modal drum - its strongest peak between 200 Hz and 5 kHz - skips steps
//  2-6 too (see `analyzeModal`): its modes are read off the spectrum, and
//  each one's level and decay off its own band.
//  A hi-hat - less than −12 dB of the first 200 ms below 1 kHz - skips
//  steps 2-6 (see `analyzeHat`): no body, no pitch; its envelope and band
//  like the wires', and its metal from the fine structure of its spectrum.
//

import Foundation
import Accelerate

/// One period measured from the zero crossings.
nonisolated struct PitchPoint: Sendable, Equatable {
    var time: Double       // s from the onset
    var hz: Double
    var weight: Double     // the body's envelope there
}

nonisolated struct Analysis: Sendable {
    /// The hit, onset to end, at the analysis rate.
    let hit: MonoAudio
    /// Seconds cut off the front of the file.
    let onsetSeconds: Double
    /// The body's measured pitch, for the fit and the pitch view.
    let pitchTrack: [PitchPoint]
    /// The recording's noise floor below the hit's peak, in dB (≤ 0).
    let noiseFloorDB: Double
    /// The measured first guess, of the model it was analysed as.
    let initial: DrumParams
    /// The model the hit itself suggests, whatever it was analysed as.
    let suggested: DrumModel
}

nonisolated enum AnalysisError: Error, LocalizedError {
    case silent
    case tooShort

    var errorDescription: String? {
        switch self {
        case .silent: "The file is silent."
        case .tooShort: "The hit is shorter than 20 ms - too short to measure a pitch."
        }
    }
}

nonisolated enum Analyzer {

    /// Analyses `audio` as `model`, or as the model it suggests.
    static func analyze(_ audio: MonoAudio, model: DrumModel? = nil) throws -> Analysis {
        let sr = audio.sampleRate
        guard audio.peak > 1e-5 else { throw AnalysisError.silent }
        // Rumble and DC off first: a vinyl sample often carries both, and
        // either shifts every zero crossing.
        let full = Filters.highPass(audio.array.map(Double.init), cutoff: 15, sampleRate: sr)

        // 1. Onset and end.
        let (onset, end, floorRatio) = bounds(full, sampleRate: sr)
        let y = Array(full[onset..<end])
        guard y.count >= Int(0.02 * sr) else { throw AnalysisError.tooShort }

        let suggested = suggestModel(y, sampleRate: sr)
        var p = DrumParams()
        p.model = model ?? suggested
        p.length = Double(y.count) / sr
        let hit = MonoAudio(Array(audio.array[onset..<end]), sampleRate: sr)
        if p.isHat || p.isModal || p.isClap {
            if p.isHat { analyzeHat(y, sampleRate: sr, into: &p) }
            else if p.isModal { analyzeModal(y, sampleRate: sr, into: &p) }
            else { analyzeClap(y, sampleRate: sr, into: &p) }
            return Analysis(hit: hit, onsetSeconds: Double(onset) / sr, pitchTrack: [],
                            noiseFloorDB: 20 * log10(max(floorRatio, 1e-6)), initial: p.clamped(), suggested: suggested)
        }
        p.transient = 0
        p.noise = 0

        // 2. Where the pitch settles.
        let tailHz = tailFrequency(y, sampleRate: sr)

        // 3. The sweep, on the low-passed body.
        let body = Filters.lowPass(y, cutoff: bodyCutoff(p.model, hz: tailHz), sampleRate: sr)
        let envelope = Filters.envelope(body)
        let track = pitchTrack(body, envelope: envelope, floorRatio: floorRatio, sampleRate: sr)
        let sweep = fitSweep(track, fallbackHz: tailHz)

        // 3b. Where the body really starts: the first time its envelope
        // reaches half its peak. On a synthesised hit that is the onset;
        // on three recorded acoustic kicks it was 3-4 ms later - the
        // head moves a little before the beater drives it, 20 dB down, and
        // the onset is found on that. A synth body started at the onset was
        // 4 ms early, and every fit bent level, decay and drive to hide it.
        // From here on the body's times count from this start; the
        // pre-swing before it is left to the attack noise (see Fitter).
        let envelopeTop = envelope.max() ?? 0
        let start = envelope.firstIndex { $0 >= 0.5 * envelopeTop } ?? 0
        p.delay = min(Double(start) / sr, 0.03)
        let d = Int((p.delay * sr).rounded())
        p.fundamental = sweep.end
        p.pitchStart = sweep.end + (sweep.start - sweep.end) * exp(-p.delay / sweep.tau)
        p.pitchDecay = sweep.tau

        // 4. Decay, shape, level.
        let shape = fitDecay(Array(envelope.dropFirst(d)), fromSeconds: max(1.5 / p.fundamental, 0.005),
                             floorRatio: floorRatio, sampleRate: sr)
        p.ampAttack = 0.0005
        p.ampDecay = shape.tau
        p.ampShape = shape.k
        p.gainDB = 20 * log10(max(shape.peak, 1e-6))
        p = p.clamped()

        // 5. Phase.
        p.startPhase = startPhase(p, body: body, sampleRate: sr)

        // 6. Click and noise, from the residual.
        var modelled = p
        modelled.transient = 0
        modelled.noise = 0
        modelled.mode2Level = 0
        let gain = pow(10, p.gainDB / 20)
        let voice = DrumSynth.body(modelled, sampleRate: sr, frames: y.count)
        let residual = Array((0..<y.count).map { y[$0] - gain * voice[$0] }.dropFirst(d))
        if p.isSnare {
            // Wires first: they sound from the start at full level, and the
            // click is only what rises above them (with the wires counted
            // as click, the synthetic snare's read 2.0 for 0.5, 5 ms long
            // for 1, and the fit bought drive to make up for it).
            measureMode2(residual, gain: gain, sampleRate: sr, into: &p)
            measureWires(residual, gain: gain, aboveHz: max(4.5 * p.fundamental, 600), sampleRate: sr, into: &p)
            measureClick(residual, gain: gain, over: 3 * p.noise * gain, sampleRate: sr, into: &p)
        } else {
            measureClick(residual, gain: gain, sampleRate: sr, into: &p)
            measureNoise(residual, gain: gain, aboveHz: max(3 * p.fundamental, 150), sampleRate: sr, into: &p)
        }

        // The hit as recorded, not as high-passed for measuring: it is what
        // the fit compares with and what the preview plays, and the filter's
        // own ringing is not part of the drum (with it, even the true
        // parameters scored 0.23 dB off on a clean 58 Hz kick).
        return Analysis(hit: hit, onsetSeconds: Double(onset) / sr, pitchTrack: track,
                        noiseFloorDB: 20 * log10(max(floorRatio, 1e-6)), initial: p.clamped(), suggested: suggested)
    }

    // MARK: - Model

    /// Snare when more than −17.5 dB of the first 200 ms' energy lies above
    /// 2 kHz. Measured on the trimmed hits: the author's three recorded kicks −28 to
    /// −39 dB, the four snares −3 to −15 (the Drumulator's the darkest),
    /// the harness's synthetic tom, with a loud 900 Hz shell, −20.
    static let snareThresholdDB = -17.5

    /// Hi-hat when less than −12 dB of the first 200 ms lies below 1 kHz,
    /// where every other drum has its body: the author's five hats −24 to −55 dB,
    /// the snares −0.1 to −3.0, the kicks about 0.
    static let hatThresholdDB = -12.0

    /// Where the strongest peak of the first 100 ms lies decides the rest:
    /// the author's kicks 57-72 Hz, snares 117-180, hats 7-16 kHz, and the modal
    /// drums - cowbells, claves, rims, a woodblock - 215 Hz to 3 kHz. A
    /// hat needs both: the claves have as little below 1 kHz (−35 and
    /// −42 dB) and were suggested as hats before the peak was asked. A tom
    /// tuned above 200 Hz would come out modal; the model can be chosen.
    static let modalRange = 200.0..<5000.0

    static func suggestModel(_ y: [Double], sampleRate sr: Double) -> DrumModel {
        let head = Array(y.prefix(Int(0.2 * sr)))
        var total = 0.0, high = 0.0, low = 0.0
        vDSP_svesqD(head, 1, &total, vDSP_Length(head.count))
        guard total > 0 else { return .kick }
        let dark = Filters.lowPass(head, cutoff: 1000, sampleRate: sr)
        vDSP_svesqD(dark, 1, &low, vDSP_Length(dark.count))
        if isClap(y, sampleRate: sr) { return .clap }
        let peak = strongestPeak(Array(y.prefix(Int(0.1 * sr))), sampleRate: sr)
        if 10 * log10(max(low / total, 1e-20)) < hatThresholdDB && peak >= modalRange.upperBound { return .hat }
        if modalRange.contains(peak) { return .modal }
        let bright = Filters.highPass(head, cutoff: 2000, sampleRate: sr)
        vDSP_svesqD(bright, 1, &high, vDSP_Length(bright.count))
        return 10 * log10(max(high / total, 1e-20)) > snareThresholdDB ? .snare : .kick
    }

    /// The frequency of the strongest spectral peak above 30 Hz.
    static func strongestPeak(_ x: [Double], sampleRate sr: Double) -> Double {
        let size = 1 << 15
        let m = spectrum(x, size: size)
        let binHz = sr / Double(size)
        let low = max(Int(30 / binHz), 1)
        guard m.count > low + 2 else { return 0 }
        let k = (low..<(m.count - 1)).max { m[$0] < m[$1] } ?? low
        return interpolatedPeak(m, k) * binHz
    }

    /// The low-pass that leaves the body alone: six times the tail on a
    /// kick (its sweep starts high, and nothing else is down there), 1.25
    /// times on a snare (the second mode and the wires are).
    static func bodyCutoff(_ model: DrumModel, hz: Double) -> Double {
        switch model {
        case .kick: min(max(6 * hz, 250), 2500)
        case .snare: min(max(1.25 * hz, 60), 2500)
        case .hat, .modal, .clap: min(max(6 * hz, 250), 2500)      // no swept body; never used for one
        }
    }

    // MARK: - 1. Bounds

    /// Onset frame, end frame, and the noise floor relative to the peak.
    static func bounds(_ x: [Double], sampleRate sr: Double) -> (Int, Int, Double) {
        let hop = max(Int(0.001 * sr), 1)
        let hops = max(x.count / hop, 1)
        var peaks = [Double](repeating: 0, count: hops)
        x.withUnsafeBufferPointer { buffer in
            for h in 0..<hops {
                let count = min(hop, x.count - h * hop)
                guard count > 0 else { continue }
                vDSP_maxmgvD(buffer.baseAddress! + h * hop, 1, &peaks[h], vDSP_Length(count))
            }
        }
        let top = peaks.max() ?? 0
        let peakHop = peaks.firstIndex(of: top) ?? 0

        // Where the hit begins, by energy per hop rather than by peak: a
        // crackle is a single loud sample, and 50 ms before a kick one was
        // taken for its onset. Over a 1 ms hop its RMS is a seventh of its
        // peak, while a kick's hops are loud all the way through.
        var rms = [Double](repeating: 0, count: hops)
        x.withUnsafeBufferPointer { buffer in
            for h in 0..<hops {
                let count = min(hop, x.count - h * hop)
                guard count > 0 else { continue }
                vDSP_rmsqvD(buffer.baseAddress! + h * hop, 1, &rms[h], vDSP_Length(count))
            }
        }
        let loudest = rms.max() ?? 0
        let firstLoud = rms.firstIndex { $0 >= 0.1 * loudest } ?? 0

        // The noise before it, if the file has any lead-in: σ from the
        // median, which the odd crackle does not move.
        let leadEnd = max(firstLoud * hop - Int(0.005 * sr), 0)
        let leadStart = max(leadEnd - Int(0.05 * sr), 0)
        var leadSigma = 0.0
        if leadEnd - leadStart > hop {
            let magnitudes = x[leadStart..<leadEnd].map(abs).sorted()
            leadSigma = 1.4826 * magnitudes[magnitudes.count / 2]
        }
        let threshold = max(4 * leadSigma, 0.01 * top)

        // Walk back from inside the rise for as long as the last 0.25 ms
        // still holds a sample above the threshold: the run the hit grew
        // from, and nothing that is not connected to it. At most 5 ms.
        let window = max(Int(0.00025 * sr), 1)
        let from = min(firstLoud * hop, x.count - 1)
        var onset = from
        while onset > window && from - onset < Int(0.005 * sr) {
            var loud = false
            for j in (onset - window)..<onset where abs(x[j]) >= threshold { loud = true; break }
            if !loud { break }
            onset -= 1
        }
        // Back to the zero crossing the rise started from, at most 1 ms.
        var back = onset
        while back > 0 && onset - back < hop && x[back - 1] * x[back] > 0 { back -= 1 }
        if back > 0 && onset - back < hop { onset = back }

        // The floor: what the file ends in, if it has stopped falling. A
        // sample cut while the drum still rings ends in the drum, and taking
        // that for noise cut 0.2 s off a 1.2 s kick; so the last fifth is
        // split in two, and if the second half is more than 1 dB quieter
        // the file is still decaying and there is no floor to trim to.
        let tailCount = min(max(hops / 5, 50), hops - peakHop)
        var floor = top * 1e-5
        if tailCount >= 4 {
            let tail = Array(peaks[(hops - tailCount)...])
            func meanDB(_ values: ArraySlice<Double>) -> Double {
                values.map { 20 * log10(max($0, 1e-12)) }.reduce(0, +) / Double(values.count)
            }
            let falling = meanDB(tail[0..<(tailCount / 2)]) - meanDB(tail[(tailCount / 2)...])
            if falling < 1 { floor = max(floor, tail.sorted()[tailCount / 2]) }
        }
        let level = max(2 * floor, top * 1e-3)
        var lastHop = peakHop
        for h in stride(from: hops - 1, through: peakHop, by: -1) where peaks[h] > level {
            lastHop = h
            break
        }
        let end = min((lastHop + 1) * hop + Int(0.01 * sr), x.count)
        return (onset, max(end, min(onset + 1, x.count)), floor / max(top, 1e-12))
    }

    // MARK: - 2. Tail

    /// The strongest frequency between 20 Hz and 1 kHz in the part of the
    /// hit after the attack, to a fraction of a bin.
    static func tailFrequency(_ y: [Double], sampleRate sr: Double) -> Double {
        let n = y.count
        let peakIndex = y.indices.max { abs(y[$0]) < abs(y[$1]) } ?? 0
        var start = min(peakIndex + Int(0.02 * sr), n - 1)
        if n - start < Int(0.05 * sr) { start = min(peakIndex, n - 1) }
        let segment = Array(y[start...])
        var size = 1 << 16
        while size < 4 * segment.count { size <<= 1 }
        let magnitudes = spectrum(segment, size: size)
        let binHz = sr / Double(size)
        let low = max(Int(20 / binHz), 1), high = min(Int(1000 / binHz), magnitudes.count - 2)
        guard high > low else { return 55 }
        var best = low
        for k in low...high where magnitudes[k] > magnitudes[best] { best = k }
        return interpolatedPeak(magnitudes, best) * binHz
    }

    /// Hann-windowed magnitude spectrum, `size / 2` bins (bin 0 left 0).
    static func spectrum(_ segment: [Double], size: Int) -> [Double] {
        let fft = RealFFT(size: size)
        let half = size / 2
        let n = min(segment.count, size)
        var input = [Float](repeating: 0, count: size)
        for i in 0..<n {
            let w = n > 1 ? 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)) : 1
            input[i] = Float(segment[i] * w)
        }
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        input.withUnsafeBufferPointer { fft.forward($0.baseAddress!, real: &real, imag: &imag) }
        var magnitudes = [Double](repeating: 0, count: half)
        for k in 1..<half {
            magnitudes[k] = Double((real[k] * real[k] + imag[k] * imag[k]).squareRoot())
        }
        return magnitudes
    }

    /// Parabolic interpolation on log magnitudes around bin `k`, in bins.
    static func interpolatedPeak(_ m: [Double], _ k: Int) -> Double {
        guard k > 0, k + 1 < m.count else { return Double(k) }
        let a = log(max(m[k - 1], 1e-20)), b = log(max(m[k], 1e-20)), c = log(max(m[k + 1], 1e-20))
        let denominator = a - 2 * b + c
        guard abs(denominator) > 1e-12 else { return Double(k) }
        return Double(k) + 0.5 * (a - c) / denominator
    }

    // MARK: - 3. Sweep

    /// One point per period: upward crossings to upward crossings, and
    /// downward to downward, so a waveform that is not symmetric (a kick's
    /// first half-cycle usually is not) still measures whole periods.
    static func pitchTrack(_ body: [Double], envelope: [Double], floorRatio: Double,
                           sampleRate sr: Double) -> [PitchPoint] {
        var up: [Double] = [], down: [Double] = []
        for i in 1..<body.count {
            let a = body[i - 1], b = body[i]
            if a < 0 && b >= 0 { up.append((Double(i - 1) + a / (a - b)) / sr) }
            if a > 0 && b <= 0 { down.append((Double(i - 1) + a / (a - b)) / sr) }
        }
        let top = envelope.max() ?? 0
        // A period is trusted 12 dB above the recording's floor (where the
        // crossings belong to the noise) and no deeper than 50 dB under
        // the peak.
        let gate = top * max(4 * floorRatio, 0.003)
        var points: [PitchPoint] = []
        for crossings in [up, down] where crossings.count > 1 {
            for j in 1..<crossings.count {
                let period = crossings[j] - crossings[j - 1]
                guard period > 0 else { continue }
                let t = 0.5 * (crossings[j] + crossings[j - 1])
                let index = min(Int(t * sr), envelope.count - 1)
                let hz = 1 / period
                guard hz > 15, hz < 5000, envelope[index] > gate else { continue }
                points.append(PitchPoint(time: t, hz: hz, weight: envelope[index] / max(top, 1e-12)))
            }
        }
        points.sort { $0.time < $1.time }
        // A period cut in two by a noise crossing reads as an octave up;
        // anything more than 30 % away from its neighbours' median goes.
        guard points.count > 4 else { return points }
        return points.indices.compactMap { i in
            let lo = max(0, i - 3), hi = min(points.count - 1, i + 3)
            let median = points[lo...hi].map(\.hz).sorted()[(hi - lo) / 2]
            return abs(points[i].hz / median - 1) < 0.3 ? points[i] : nil
        }
    }

    struct Sweep { var start: Double; var end: Double; var tau: Double }

    /// f(t) = end + (start − end)·e^(−t/τ) through the track, weighted by
    /// the envelope: a grid over τ, least squares for the two frequencies,
    /// then a golden-section search around the best grid point.
    static func fitSweep(_ track: [PitchPoint], fallbackHz: Double) -> Sweep {
        guard track.count >= 4 else {
            return Sweep(start: fallbackHz * 2.5, end: fallbackHz, tau: 0.03)
        }
        func solve(_ tau: Double) -> (Double, Sweep) {
            var sw = 0.0, sg = 0.0, sgg = 0.0, sf = 0.0, sgf = 0.0
            for point in track {
                let g = exp(-point.time / tau), w = point.weight
                sw += w; sg += w * g; sgg += w * g * g; sf += w * point.hz; sgf += w * g * point.hz
            }
            let det = sw * sgg - sg * sg
            guard abs(det) > 1e-12 else {
                let mean = sf / max(sw, 1e-12)
                return (.infinity, Sweep(start: mean, end: mean, tau: tau))
            }
            let end = (sgg * sf - sg * sgf) / det
            let delta = (sw * sgf - sg * sf) / det
            var error = 0.0
            for point in track {
                let r = point.hz - end - delta * exp(-point.time / tau)
                error += point.weight * r * r
            }
            return (error, Sweep(start: end + delta, end: end, tau: tau))
        }
        let grid = (0..<80).map { 0.001 * pow(1000, Double($0) / 79) }   // 1 ms … 1 s
        var bestIndex = 0
        var bestError = Double.infinity
        for (i, tau) in grid.enumerated() {
            let (error, _) = solve(tau)
            if error < bestError { bestError = error; bestIndex = i }
        }
        var a = log(grid[max(bestIndex - 1, 0)]), b = log(grid[min(bestIndex + 1, grid.count - 1)])
        let ratio = (5.0.squareRoot() - 1) / 2
        for _ in 0..<40 {
            let c = b - ratio * (b - a), d = a + ratio * (b - a)
            if solve(exp(c)).0 < solve(exp(d)).0 { b = d } else { a = c }
        }
        var sweep = solve(exp(0.5 * (a + b))).1
        // A sweep with too few early points can extrapolate to nonsense;
        // keep it inside what the synth can play.
        sweep.end = min(max(sweep.end, 20), 1000)
        sweep.start = min(max(sweep.start, 20), 4000)
        return sweep
    }

    // MARK: - 4. Envelope

    struct Shape { var tau: Double; var k: Double; var peak: Double }

    /// ln e(t) = ln A − (t/τ)^k, fitted from 1.5 periods after the onset
    /// down to 60 dB or the floor: a grid over k, and for each k the level
    /// and the rate by least squares.
    ///
    /// Not anchored to the envelope's own peak. At the start of a sweep the
    /// analytic envelope is off by ±10 % for a few milliseconds (measured:
    /// +0.75 dB at 3 ms on a clean 58 Hz kick), and dividing the whole
    /// curve by that one wrong value bent the fitted shape from 1.0 to 0.72.
    /// Fitting the level as a free parameter over the reliable part lets
    /// the early error fall out. The attack is left to the Fitter for the
    /// same reason: the one region that would show it is the one the
    /// envelope gets wrong.
    static func fitDecay(_ envelope: [Double], fromSeconds start: Double, floorRatio: Double,
                         sampleRate sr: Double) -> Shape {
        let top = envelope.max() ?? 0
        let hop = max(Int(0.001 * sr), 1)
        let lowest = top * max(3 * floorRatio, 1e-3)
        // Nor the last 20 ms: a file's end is a cut or a fade, and the
        // analytic envelope rings at the edge (it bent a clean kick's shape
        // to 1.04 and its level by 0.4 dB).
        let stop = envelope.count - Int(0.02 * sr)
        var ts: [Double] = [], ls: [Double] = []
        var i = min(Int(start * sr), max(envelope.count - 1, 0))
        while i < stop {
            let e = envelope[i]
            if e < lowest { break }
            ts.append(Double(i) / sr)
            ls.append(log(e))
            i += hop
        }
        guard ts.count >= 5, let last = ts.last else {
            return Shape(tau: max(Double(envelope.count) / sr / 3, 0.005), k: 1, peak: top)
        }
        func solve(_ k: Double) -> (error: Double, shape: Shape) {
            // ls ≈ a − c·t^k: linear in a and c.
            var n = 0.0, su = 0.0, suu = 0.0, sl = 0.0, sul = 0.0
            for j in ts.indices {
                let u = pow(ts[j], k)
                n += 1; su += u; suu += u * u; sl += ls[j]; sul += u * ls[j]
            }
            let det = n * suu - su * su
            guard abs(det) > 1e-30 else { return (.infinity, Shape(tau: 1, k: k, peak: top)) }
            let a = (suu * sl - su * sul) / det
            let c = -(n * sul - su * sl) / det
            guard c > 0 else { return (.infinity, Shape(tau: 1, k: k, peak: top)) }
            var error = 0.0
            for j in ts.indices {
                let r = ls[j] - a + c * pow(ts[j], k)
                error += r * r
            }
            return (error, Shape(tau: pow(c, -1 / k), k: k, peak: exp(a)))
        }
        var best = solve(1)
        for step in 0...60 {
            let k = 0.4 * pow(10, Double(step) / 60)       // 0.4 … 4
            let candidate = solve(k)
            if candidate.error < best.error { best = candidate }
        }
        // A decay seen over only a few dB says little about its shape.
        if (ls[0] - ls[ls.count - 1]) * 20 / log(10) < 6 {
            var plain = solve(1).shape
            plain.tau = max(plain.tau, last)
            return plain
        }
        return best.shape
    }

    // MARK: - 5. Phase

    /// The phase that lines the model's sine up with the body, over its
    /// first three periods (or 30 ms): later on, a small pitch error has
    /// turned into a large phase error and would only blur the answer.
    static func startPhase(_ p: DrumParams, body: [Double], sampleRate sr: Double) -> Double {
        var q = p
        q.drive = 0
        q.startPhase = 0
        let n = min(body.count, max(Int(3 / p.fundamental * sr), Int(0.03 * sr)))
        let s = DrumSynth.body(q, sampleRate: sr, frames: n)
        q.startPhase = 90
        let c = DrumSynth.body(q, sampleRate: sr, frames: n)
        var ss = 0.0, cc = 0.0, sc = 0.0, sb = 0.0, cb = 0.0
        for i in 0..<n {
            ss += s[i] * s[i]; cc += c[i] * c[i]; sc += s[i] * c[i]
            sb += s[i] * body[i]; cb += c[i] * body[i]
        }
        let det = ss * cc - sc * sc
        guard abs(det) > 1e-12 else { return 0 }
        let alpha = (cc * sb - sc * cb) / det      // A·cos φ
        let beta = (ss * cb - sc * sb) / det       // A·sin φ
        return atan2(beta, alpha) * 180 / .pi
    }

    // MARK: - 6. Residual

    /// The click: the residual's first 5 ms. `floor` is the peak of what
    /// else sounds there from the start (a snare's wires, about three times
    /// their RMS): the click's level is what rises above it, and its decay
    /// ends where it has fallen back to it.
    static func measureClick(_ residual: [Double], gain: Double, over floor: Double = 0, sampleRate sr: Double,
                             into p: inout DrumParams) {
        let n = min(residual.count, Int(0.005 * sr))
        guard n > 8, gain > 0 else { return }
        let head = Array(residual[0..<n])
        let top = head.map(abs).max() ?? 0
        p.transient = min(max(top - floor, 0) / gain, 2)
        guard top > floor else { return }

        // Tone: white noise high-passed at f spreads its power evenly from
        // f to Nyquist, so its centre in log frequency is √(f·Nyquist).
        let centre = logCentroid(spectrum(head, size: 1024), binHz: sr / 1024)
        if centre > 0 { p.clickTone = centre * centre / (0.5 * sr) }

        // Decay: from the burst's peak to where its 0.25 ms peaks fall
        // below 1/e of it.
        let hop = max(Int(0.00025 * sr), 1)
        let peakIndex = head.indices.max { abs(head[$0]) < abs(head[$1]) } ?? 0
        let span = Array(residual[peakIndex..<min(residual.count, peakIndex + Int(0.02 * sr))])
        var i = 0
        while i + hop <= span.count {
            let local = span[i..<(i + hop)].map(abs).max() ?? 0
            if local < floor + (top - floor) / M_E { break }
            i += hop
        }
        p.clickDecay = max(Double(i) / sr, 0.0002)
    }

    static func measureNoise(_ residual: [Double], gain: Double, aboveHz: Double, sampleRate sr: Double,
                             into p: inout DrumParams) {
        let skip = Int(0.005 * sr)
        guard residual.count > skip + Int(0.02 * sr), gain > 0 else { return }
        let high = Filters.highPass(residual, cutoff: aboveHz, sampleRate: sr)
        let window = max(Int(0.005 * sr), 1)
        var times: [Double] = [], powers: [Double] = []
        var i = skip
        while i + window <= high.count {
            var ms = 0.0
            high.withUnsafeBufferPointer { vDSP_measqvD($0.baseAddress! + i, 1, &ms, vDSP_Length(window)) }
            times.append((Double(i) + 0.5 * Double(window)) / sr)
            powers.append(ms)
            i += window
        }
        guard powers.count >= 4 else { return }
        // The record's own hiss: the quieter tenth of the windows. The fit
        // runs from the strongest window for as long as the noise stays
        // twice above it and within 40 dB of its start - one unbroken run,
        // because scattered windows near the floor are the floor's own
        // fluctuation, and they flattened the slope (measured: 0.11 read
        // as 1.0).
        let floor = powers.sorted()[powers.count / 10]
        let first = powers.indices.max { powers[$0] < powers[$1] } ?? 0
        let lowest = max(2 * floor, powers[first] * 1e-4)
        var xs: [Double] = [], ys: [Double] = []
        for j in first..<powers.count {
            guard powers[j] > lowest else { break }
            xs.append(times[j])
            ys.append(0.5 * log(powers[j] - floor))
        }
        guard xs.count >= 3 else { return }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for j in xs.indices { sxy += (xs[j] - mx) * (ys[j] - my); sxx += (xs[j] - mx) * (xs[j] - mx) }
        let slope = sxx > 0 ? sxy / sxx : -20
        guard slope < 0 else { return }
        p.noiseDecay = -1 / slope
        p.noise = min(exp(my - slope * mx) / gain, 1)

        // Tone: a band-pass is symmetric in log frequency, so its centre
        // is the log centroid (a linear centroid read 2.5 kHz as 4.2).
        let segment = Array(high[skip..<min(high.count, skip + Int(0.05 * sr))])
        let centre = logCentroid(spectrum(segment, size: 4096), binHz: sr / 4096)
        if centre > 0 { p.noiseTone = centre }
    }

    /// A snare's second mode: the strongest peak of the residual's first
    /// 40 ms between 1.2 and 4 times the body's pitch there, and, from its
    /// band's envelope (two band-passes at Q 4, zero-phase), its level and
    /// decay - a straight line through the log envelope from its peak
    /// down 30 dB, extrapolated back to the start.
    static func measureMode2(_ residual: [Double], gain: Double, sampleRate sr: Double, into p: inout DrumParams) {
        let n = min(residual.count, Int(0.04 * sr))
        guard n > Int(0.01 * sr), gain > 0 else { return }
        let size = 16_384
        let magnitudes = spectrum(Array(residual[0..<n]), size: size)
        let binHz = sr / Double(size)
        // The body's pitch there by its median: a fitted sweep can start
        // with a chirp of a few milliseconds that would drag a mean up.
        let pitch = stride(from: 0.0, to: Double(n) / sr, by: 0.001).map { p.pitch(at: p.delay + $0) }.sorted()
        let body = pitch[pitch.count / 2]
        let low = max(Int(1.2 * body / binHz), 1), high = min(Int(4 * body / binHz), magnitudes.count - 2)
        guard high > low + 2 else { return }
        // A peak, not the range's edge: next to the body the residual's
        // spectrum still falls from the body's leftovers, and its highest
        // point there is the edge (the 909 read 1.17).
        var best: Int?
        for k in (low + 1)..<high where magnitudes[k] > magnitudes[k - 1] && magnitudes[k] >= magnitudes[k + 1] {
            if best == nil || magnitudes[k] > magnitudes[best!] { best = k }
        }
        guard let best else { return }
        let hz = interpolatedPeak(magnitudes, best) * binHz
        p.mode2Ratio = hz / body

        let q = 4.0
        let band = Filters.zeroPhase(residual, [Biquad(.bandPass, frequency: hz, q: q, sampleRate: sr),
                                                Biquad(.bandPass, frequency: hz, q: q, sampleRate: sr)])
        let envelope = Filters.envelope(band)
        let search = min(envelope.count, Int(0.03 * sr))
        let peakIndex = (0..<search).max { envelope[$0] < envelope[$1] } ?? 0
        let top = envelope[peakIndex]
        guard top > 0 else { return }
        let hop = max(Int(0.001 * sr), 1)
        var xs: [Double] = [], ys: [Double] = []
        var i = peakIndex
        while i < min(envelope.count, peakIndex + Int(0.15 * sr)) && envelope[i] > top * 0.03 {
            xs.append(Double(i) / sr)
            ys.append(log(envelope[i]))
            i += hop
        }
        guard xs.count >= 3 else { return }
        let (slope, intercept) = line(xs, ys)
        guard slope < 0 else { return }
        p.mode2Decay = -1 / slope
        p.mode2Level = min(exp(intercept) / gain, 2)
    }

    /// Snare wires: the residual above the second mode, its RMS over 5 ms,
    /// fitted with A·exp(−(t/τ)^k) like the body's envelope (level, decay,
    /// shape), from 5 ms on - the click is before. Then the band: where
    /// the power's first and last tenth end, which for white noise between
    /// two corners sit a tenth of the way in from each (solved back for
    /// the corners); tone their geometric centre, width their distance in
    /// octaves. Not the log centroid the shell uses: that suits one
    /// band-pass, and on a band octaves wide it leans to the top, where
    /// most of the bins are.
    static func measureWires(_ residual: [Double], gain: Double, aboveHz: Double, sampleRate sr: Double,
                             into p: inout DrumParams) {
        let window = max(Int(0.005 * sr), 1)
        guard residual.count > 4 * window, gain > 0 else { return }
        let high = Filters.highPass(residual, cutoff: aboveHz, sampleRate: sr)
        var sums = [Double](repeating: 0, count: high.count + 1)
        for i in high.indices { sums[i + 1] = sums[i] + high[i] * high[i] }
        let envelope = high.indices.map { i -> Double in
            let lo = max(i - window / 2, 0), hi = min(i + window / 2, high.count)
            return ((sums[hi] - sums[lo]) / Double(max(hi - lo, 1))).squareRoot()
        }
        let top = envelope.max() ?? 0
        guard top > 0 else { return }
        let floor = stride(from: 0, to: envelope.count, by: window).map { envelope[$0] }.sorted()
        let floorRatio = floor[floor.count / 10] / top
        let shape = fitDecay(envelope, fromSeconds: 0.005, floorRatio: floorRatio, sampleRate: sr)
        p.noise = min(shape.peak / gain, 1)
        p.noiseDecay = shape.tau
        p.noiseShape = shape.k

        let skip = min(Int(0.005 * sr), high.count - 1)
        let segment = Array(high[skip..<min(high.count, skip + Int(0.05 * sr))])
        if let band = measureBand(segment, aboveHz: aboveHz, sampleRate: sr) {
            p.noiseTone = band.tone
            p.noiseWidth = band.width
        }
    }

    /// The band noise lies in, as tone (geometric centre) and width
    /// (octaves) of the wires' high- and low-pass: where the power's first
    /// and last tenth end, solved back for the corners (see measureWires).
    static func measureBand(_ segment: [Double], aboveHz: Double,
                            sampleRate sr: Double) -> (tone: Double, width: Double)? {
        let magnitudes = spectrum(segment, size: 4096)
        let binHz = sr / 4096
        let power = magnitudes.map { $0 * $0 }
        let total = power.reduce(0, +)
        guard total > 0 else { return nil }
        var running = 0.0
        var f10 = 0.0, f90 = 0.0
        for k in power.indices {
            running += power[k]
            if f10 == 0 && running >= 0.1 * total { f10 = Double(k) * binHz }
            if running >= 0.9 * total { f90 = Double(k) * binHz; break }
        }
        let a = max((9 * f10 - f90) / 8, 0.7 * aboveHz, 20)
        let b = min(max((9 * f90 - f10) / 8, 1.5 * a), 0.45 * sr)
        return ((a * b).squareRoot(), log2(b / a))
    }

    // MARK: - Clap

    /// The bursts of the first 60 ms: peaks of the RMS over 1 ms (every
    /// 0.25 ms) of the hit above 1 kHz, each at least 8 dB over the trough
    /// since the last and within 12 dB of the loudest; their times (s) and
    /// RMS. Above 1 kHz because a body's own half-periods are peaks too:
    /// with the full band a 57 Hz kick "burst" every 9 ms.
    static func bursts(_ y: [Double], sampleRate sr: Double) -> [(time: Double, rms: Double)] {
        let x = Filters.highPass(Array(y.prefix(Int(0.07 * sr))), cutoff: 1000, sampleRate: sr)
        let w = max(Int(0.001 * sr), 1), hop = max(Int(0.00025 * sr), 1)
        let n = min(x.count, Int(0.06 * sr))
        guard n > w else { return [] }
        let levels = stride(from: 0, to: n - w, by: hop).map { i -> Double in
            var ms = 0.0
            x.withUnsafeBufferPointer { vDSP_measqvD($0.baseAddress! + i, 1, &ms, vDSP_Length(w)) }
            return 10 * log10(ms + 1e-20)
        }
        let top = levels.max() ?? 0
        var out: [(time: Double, rms: Double)] = []
        var armed = true, candidate = -Double.infinity, index = 0, trough = Double.infinity
        for (i, v) in levels.enumerated() {
            if armed {
                if v > candidate { candidate = v; index = i }
                if candidate - v >= 8 || i == levels.count - 1 {
                    if candidate > top - 12 { out.append((Double(index * hop) / sr, pow(10, candidate / 20))) }
                    armed = false
                    trough = v
                }
            } else {
                trough = min(trough, v)
                if v - trough >= 8 { armed = true; candidate = v; index = i }
            }
        }
        return out
    }

    /// Four or more bursts in a row, 6-16 ms apart, each gap within 20 % of
    /// their median. Measured: the 808, 909 and "smooth" claps 4 bursts at
    /// 9.8-13.3 ms; no other drum here - the 626 snare, the Linn cowbell
    /// and the lofi kick have several dips above 1 kHz too, but at 3-7 ms
    /// and uneven. The Linn clap, a real one with ragged hands, does not
    /// pass (two clean bursts); it can be chosen.
    static func isClap(_ y: [Double], sampleRate sr: Double) -> Bool {
        let times = bursts(y, sampleRate: sr).map(\.time)
        guard times.count >= 4 else { return false }
        for start in 0...(times.count - 4) {
            let gaps = (start..<(start + 3)).map { times[$0 + 1] - times[$0] }
            let median = gaps.sorted()[1]
            if gaps.allSatisfy({ (0.006...0.016).contains($0) && abs($0 / median - 1) <= 0.2 }) { return true }
        }
        return false
    }

    /// A clap, from the trimmed hit:
    /// - bursts (see `bursts`): their count, their median spacing, the
    ///   first one's time as the delay, their RMS as the level;
    /// - each burst's decay: a line through the log RMS from its peak to
    ///   the next burst's trough, the median of them;
    /// - the tail: the RMS over 5 ms from the last burst on, fitted with
    ///   A·exp(−(t/τ)^k) from three burst decays after it, A relative to a
    ///   burst's level;
    /// - the bursts' band like the wires', up to 10 ms after the last one;
    ///   the tail's over 150 ms from there.
    static func analyzeClap(_ y: [Double], sampleRate sr: Double, into p: inout DrumParams) {
        var found = bursts(y, sampleRate: sr)
        if found.isEmpty { found = [(0, (y.map { $0 * $0 }.reduce(0, +) / Double(max(y.count, 1))).squareRoot())] }
        let times = found.map(\.time)
        p.clapBursts = Double(found.count)
        if times.count > 1 {
            let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
            p.clapSpacing = gaps[gaps.count / 2]
        }
        p.delay = max(times[0] - 0.0005, 0)
        let level = found.map(\.rms).reduce(0, +) / Double(found.count)
        p.gainDB = 20 * log10(max(level, 1e-6))
        p.transient = 0

        // Burst decays, on the same 1 ms RMS (every 0.25 ms), full band.
        let w = max(Int(0.001 * sr), 1), hop = max(Int(0.00025 * sr), 1)
        func rms(at i: Int) -> Double {
            let lo = max(i, 0), hi = min(i + w, y.count)
            guard hi > lo else { return 1e-10 }
            var ms = 0.0
            y.withUnsafeBufferPointer { vDSP_measqvD($0.baseAddress! + lo, 1, &ms, vDSP_Length(hi - lo)) }
            return max(ms.squareRoot(), 1e-10)
        }
        var decays: [Double] = []
        for j in 0..<max(times.count - 1, 0) {
            let a = Int(times[j] * sr), b = Int(times[j + 1] * sr)
            let points = stride(from: a, to: b, by: hop).map { (Double($0) / sr, log(rms(at: $0))) }
            guard let low = points.indices.min(by: { points[$0].1 < points[$1].1 }), low >= 3 else { continue }
            let (slope, _) = line(points[0...low].map(\.0), points[0...low].map(\.1))
            if slope < 0 { decays.append(-1 / slope) }
        }
        if !decays.isEmpty { p.clapBurstDecay = decays.sorted()[decays.count / 2] }

        // The tail, from the last burst on.
        let last = Int(times[times.count - 1] * sr)
        let window = max(Int(0.005 * sr), 1)
        let rest = Array(y.dropFirst(last))
        var sums = [Double](repeating: 0, count: rest.count + 1)
        for i in rest.indices { sums[i + 1] = sums[i] + rest[i] * rest[i] }
        let envelope = rest.indices.map { i -> Double in
            let lo = max(i - window / 2, 0), hi = min(i + window / 2, rest.count)
            return ((sums[hi] - sums[lo]) / Double(max(hi - lo, 1))).squareRoot()
        }
        if let top = envelope.max(), top > 0 {
            let floor = stride(from: 0, to: envelope.count, by: window).map { envelope[$0] }.sorted()
            let shape = fitDecay(envelope, fromSeconds: max(3 * p.clapBurstDecay, 0.005),
                                 floorRatio: floor[floor.count / 10] / top, sampleRate: sr)
            p.noise = min(shape.peak / max(level, 1e-9), 1.5)
            p.noiseDecay = shape.tau
            p.noiseShape = shape.k
        }
        if let band = measureBand(Array(y.prefix(min(y.count, last + Int(0.01 * sr)))), aboveHz: 100, sampleRate: sr) {
            p.noiseTone = band.tone
            p.noiseWidth = band.width
        }
        let tailFrom = min(last + Int(0.01 * sr), y.count - 1)
        if let band = measureBand(Array(y[tailFrom..<min(y.count, tailFrom + Int(0.15 * sr))]), aboveHz: 100,
                                  sampleRate: sr) {
            p.clapTailTone = band.tone
            p.clapTailWidth = band.width
        }
    }

    // MARK: - Modal

    /// A modal drum, from the trimmed hit:
    /// - modes: the up to six strongest peaks of the first 60 ms' spectrum
    ///   (32768 points, each the highest within ±40 Hz, within 30 dB of the
    ///   strongest and 0.25-8 times its frequency); the strongest is mode 1;
    /// - each mode's level and decay: its band's envelope (two band-passes
    ///   at Q f/60, at least 4, zero-phase), a line through its log from
    ///   its peak down 30 dB, extrapolated back to the start;
    /// - click and noise from what the modes leave, as on a kick.
    static func analyzeModal(_ y: [Double], sampleRate sr: Double, into p: inout DrumParams) {
        p.delay = 0
        p.ampAttack = 0.0005
        p.ampShape = 1
        let head = Array(y.prefix(min(y.count, Int(0.06 * sr))))
        let size = 1 << 15
        let m = spectrum(head, size: size)
        let binHz = sr / Double(size)
        let span = max(Int(40 / binHz), 1)
        let top = m.max() ?? 0
        guard top > 0 else { return }
        var peaks: [Int] = []
        for k in stride(from: max(span, Int(60 / binHz)), to: min(m.count - span, Int(0.45 * sr / binHz)), by: 1)
        where m[k] > top * 0.0316 && m[(k - span)...(k + span)].max()! == m[k] {
            peaks.append(k)
        }
        peaks.sort { m[$0] > m[$1] }
        guard let first = peaks.first else { return }
        let tone = interpolatedPeak(m, first) * binHz
        let chosen = peaks.map { interpolatedPeak(m, $0) * binHz }.filter { (0.25...8).contains($0 / tone) }.prefix(6)

        func measure(_ hz: Double) -> (level: Double, decay: Double) {
            let q = max(hz / 60, 4)
            let band = Filters.zeroPhase(y, [Biquad(.bandPass, frequency: hz, q: q, sampleRate: sr),
                                            Biquad(.bandPass, frequency: hz, q: q, sampleRate: sr)])
            let envelope = Filters.envelope(band)
            let search = min(envelope.count, Int(0.03 * sr))
            let peakIndex = (0..<search).max { envelope[$0] < envelope[$1] } ?? 0
            let top = envelope[peakIndex]
            guard top > 0 else { return (0, 0.02) }
            let hop = max(Int(0.001 * sr), 1)
            var xs: [Double] = [], ys: [Double] = []
            var i = peakIndex
            while i < min(envelope.count - Int(0.01 * sr), peakIndex + Int(0.4 * sr)) && envelope[i] > top * 0.0316 {
                xs.append(Double(i) / sr)
                ys.append(log(envelope[i]))
                i += hop
            }
            guard xs.count >= 3 else { return (top, 0.005) }
            let (slope, intercept) = line(xs, ys)
            return slope < 0 ? (exp(intercept), -1 / slope) : (top, 1)
        }
        let one = measure(tone)
        guard one.level > 0 else { return }
        p.modalTone = tone
        p.gainDB = 20 * log10(one.level)
        p.ampDecay = one.decay
        for k in DrumParams.modalModes {
            p[keyPath: DrumParams.modalKeyPaths(k).level] = 0
        }
        for (index, hz) in chosen.dropFirst().enumerated() {
            let paths = DrumParams.modalKeyPaths(index + 2)
            let mode = measure(hz)
            p[keyPath: paths.ratio] = hz / tone
            p[keyPath: paths.level] = min(mode.level / one.level, 2)
            p[keyPath: paths.decay] = mode.decay
        }
        p = p.clamped()

        var modes = p
        modes.transient = 0
        modes.noise = 0
        let gain = pow(10, p.gainDB / 20)
        let voice = DrumSynth.body(modes, sampleRate: sr, frames: y.count)
        let residual = (0..<y.count).map { y[$0] - gain * voice[$0] }
        p.transient = 0
        p.noise = 0
        measureClick(residual, gain: gain, sampleRate: sr, into: &p)
        measureNoise(residual, gain: gain, aboveHz: 150, sampleRate: sr, into: &p)
    }

    // MARK: - Hi-hat

    /// A hi-hat, from the trimmed hit:
    /// - envelope: RMS over 2 ms; a rise if its peak comes later than 3 ms
    ///   (the half-open acoustic hat swells for 30 ms), then the wires'
    ///   A·exp(−(t/τ)^k) from the peak on. A, the RMS there, is the level
    ///   (`gainDB`) the mix is relative to;
    /// - band: where the first 50 ms' power lies (measureBand);
    /// - metal: its tone and its share of the mix (measureMetal), noise
    ///   and metal then √(1 − m) and √m;
    /// - click: what rises above the rest's peaks, three times its RMS.
    static func analyzeHat(_ y: [Double], sampleRate sr: Double, into p: inout DrumParams) {
        p.delay = 0
        let window = max(Int(0.002 * sr), 1)
        var sums = [Double](repeating: 0, count: y.count + 1)
        for i in y.indices { sums[i + 1] = sums[i] + y[i] * y[i] }
        let envelope = y.indices.map { i -> Double in
            let lo = max(i - window / 2, 0), hi = min(i + window / 2, y.count)
            return ((sums[hi] - sums[lo]) / Double(max(hi - lo, 1))).squareRoot()
        }
        let peakIndex = envelope.indices.max { envelope[$0] < envelope[$1] } ?? 0
        let rise = peakIndex > Int(0.003 * sr) ? peakIndex : 0
        p.ampAttack = rise > 0 ? Double(rise) / sr : 0.0005
        let top = envelope[peakIndex]
        guard top > 0 else { return }
        let floor = stride(from: 0, to: envelope.count, by: window).map { envelope[$0] }.sorted()
        let shape = fitDecay(Array(envelope.dropFirst(rise)), fromSeconds: 0.001,
                             floorRatio: floor[floor.count / 10] / top, sampleRate: sr)
        p.noiseDecay = shape.tau
        p.noiseShape = shape.k
        p.gainDB = 20 * log10(max(shape.peak, 1e-6))

        if let band = measureBand(Array(y.prefix(Int(0.05 * sr))), aboveHz: 200, sampleRate: sr) {
            p.noiseTone = band.tone
            p.noiseWidth = band.width
        }
        let share = measureMetal(y, p, sampleRate: sr)
        p.metalTone = share.tone
        p.noise = (1 - share.metal).squareRoot()
        p.metal = share.metal.squareRoot()
        let gain = pow(10, p.gainDB / 20)
        measureClick(y, gain: gain, over: 3 * gain, sampleRate: sr, into: &p)
    }

    /// The spectrum's fine structure: log magnitude minus its own average
    /// over ±300 Hz - peaks where partials are, noise's random ±5 dB
    /// elsewhere - and that average, in dB.
    static func fineStructure(_ x: [Double], size: Int, sampleRate sr: Double) -> (fine: [Double], level: [Double]) {
        let magnitudes = spectrum(x, size: size)
        let levels = magnitudes.map { 20 * log10($0 + 1e-12) }
        let span = max(Int(300 / (sr / Double(size))), 1)
        var sums = [Double](repeating: 0, count: levels.count + 1)
        for i in levels.indices { sums[i + 1] = sums[i] + levels[i] }
        let smooth = levels.indices.map { i -> Double in
            let lo = max(i - span, 0), hi = min(i + span + 1, levels.count)
            return (sums[hi] - sums[lo]) / Double(hi - lo)
        }
        return (zip(levels, smooth).map { $0 - $1 }, smooth)
    }

    /// Which metal tone, and how much of the hat is metal (0…1).
    ///
    /// Tone: rendered metal - six squares through the measured band, under
    /// the measured envelope - for tones from 100 Hz to 1 kHz, and the one
    /// whose fine structure correlates best with the original's, over the
    /// bins within 20 dB of its loudest: first on a coarse grid with both
    /// structures blurred over ±50 Hz (a step of 1.2 % moves an 8 kHz
    /// partial 90 Hz), then finely around the best. The comparison the fit
    /// uses cannot do this: its narrowest bands at 8 kHz are 800 Hz wide
    /// and hold a dozen partials each.
    ///
    /// Share: how peaked the fine structure is (its spread in dB), matched
    /// against the synth's own mix of noise and that metal at eleven
    /// shares - calibrated on the voice itself, not on a formula.
    static func measureMetal(_ y: [Double], _ p: DrumParams, sampleRate sr: Double) -> (tone: Double, metal: Double) {
        let n = min(y.count, 4096)
        guard n >= 1024 else { return (p.metalTone, 0.5) }
        let size = 8192
        let binHz = sr / Double(size)
        let target = fineStructure(Array(y.prefix(n)), size: size, sampleRate: sr)
        let loudest = target.level.max() ?? 0
        let bins = target.level.indices.filter {
            target.level[$0] > loudest - 20 && Double($0) * binHz > 500 && Double($0) * binHz < 0.45 * sr
        }
        guard bins.count > 16 else { return (p.metalTone, 0.5) }
        let envelope = DrumSynth.hatEnvelope(p, sampleRate: sr, frames: n)
        func shaped(_ source: [Double]) -> [Double] {
            let band = DrumSynth.bandPass(source, p, sampleRate: sr)
            return (0..<n).map { band[$0] * envelope[$0] }
        }
        func blurred(_ x: [Double], _ radius: Int) -> [Double] {
            guard radius > 0 else { return x }
            var sums = [Double](repeating: 0, count: x.count + 1)
            for i in x.indices { sums[i + 1] = sums[i] + x[i] }
            return x.indices.map { i in
                let lo = max(i - radius, 0), hi = min(i + radius + 1, x.count)
                return (sums[hi] - sums[lo]) / Double(hi - lo)
            }
        }
        func correlation(_ a: [Double], _ b: [Double]) -> Double {
            let xs = bins.map { a[$0] }, ys = bins.map { b[$0] }
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for j in xs.indices {
                sxy += (xs[j] - mx) * (ys[j] - my); sxx += (xs[j] - mx) * (xs[j] - mx); syy += (ys[j] - my) * (ys[j] - my)
            }
            return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
        }
        func metalFine(_ tone: Double) -> [Double] {
            fineStructure(shaped(DrumSynth.metalSource(tone: tone, sampleRate: sr, frames: n)), size: size, sampleRate: sr).fine
        }
        let coarseRadius = Int(50 / binHz)
        let coarseTarget = blurred(target.fine, coarseRadius)
        var bestTone = p.metalTone, bestValue = -Double.infinity
        for step in 0..<200 {
            let tone = 100 * pow(10, Double(step) / 199)
            let value = correlation(coarseTarget, blurred(metalFine(tone), coarseRadius))
            if value > bestValue { bestValue = value; bestTone = tone }
        }
        let fineTarget = blurred(target.fine, 1)
        let centre = bestTone
        bestValue = -Double.infinity
        for step in 0...60 {
            let tone = centre * pow(1.012, Double(step - 30) / 30)
            let value = correlation(fineTarget, blurred(metalFine(tone), 1))
            if value > bestValue { bestValue = value; bestTone = tone }
        }

        func spread(_ fine: [Double]) -> Double {
            let xs = bins.map { fine[$0] }
            let mean = xs.reduce(0, +) / Double(xs.count)
            return (xs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(xs.count)).squareRoot()
        }
        let wanted = spread(target.fine)
        var random = Xorshift(seed: 0x5E11_0004)
        let noise = shaped((0..<n).map { _ in random.next() })
        let metal = shaped(DrumSynth.metalSource(tone: bestTone, sampleRate: sr, frames: n))
        var bestShare = 0.5, bestGap = Double.infinity
        for step in 0...10 {
            let m = Double(step) / 10
            let a = (1 - m).squareRoot(), b = m.squareRoot()
            let mix = (0..<n).map { a * noise[$0] + b * metal[$0] }
            let gap = abs(spread(fineStructure(mix, size: size, sampleRate: sr).fine) - wanted)
            if gap < bestGap { bestGap = gap; bestShare = m }
        }
        return (bestTone, bestShare)
    }

    /// Least-squares line y = slope·x + intercept.
    static func line(_ xs: [Double], _ ys: [Double]) -> (slope: Double, intercept: Double) {
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for j in xs.indices { sxy += (xs[j] - mx) * (ys[j] - my); sxx += (xs[j] - mx) * (xs[j] - mx) }
        let slope = sxx > 0 ? sxy / sxx : 0
        return (slope, my - slope * mx)
    }

    /// The power-weighted mean of log frequency, as a frequency.
    static func logCentroid(_ magnitudes: [Double], binHz: Double) -> Double {
        var power = 0.0, moment = 0.0
        for k in 1..<magnitudes.count {
            let e = magnitudes[k] * magnitudes[k]
            power += e; moment += e * log(Double(k) * binHz)
        }
        return power > 0 ? exp(moment / power) : 0
    }
}
