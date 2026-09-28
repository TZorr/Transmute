//
//  Fitter.swift
//  Transmute
//
//  From the Analyzer's first guess to the parameters that sound most like
//  the original: render, compare, adjust, a thousand times over.
//
//  The Analyzer measures each parameter on its own, and each measurement
//  is disturbed by the layers it is not about - the click sits on top of
//  the attack, the noise under the tail. The fit judges them together, by
//  the one question that matters: how close is the whole render to the
//  whole original (see Comparison)? It is analysis by synthesis, and it is
//  why the synth must be a pure function that renders in a millisecond.
//
//  In stages, because fourteen parameters at once is where Nelder–Mead
//  wanders:
//  1. The body alone - pitch, envelope, level - with click and noise held
//     at their measured values; then a quick try of each drive on it.
//  2. The click's tone and decay on a small grid. The Analyzer does guess
//     those, but from the first 5 ms, where the click shares the residual
//     with the noise and the body's leftovers - a 3 kHz click came out as
//     200 Hz - and the comparison changes so little between click tones
//     that the simplex cannot walk a factor of fifteen on its own.
//  3. Everything together, from there.
//  4. Drive, by trying a handful of values - the only parameter the
//     Analyzer does not guess (see there) - each with a fit of the body of
//     its own. Saturation flattens the peaks, so a body fitted without it
//     has already bent its decay and shape to stand in for it, and a drive
//     tried on that body loses to none: a kick with drive 1.2 came back as
//     0.4 with a longer, rounder decay (2.62 dB against 2.02 for the
//     truth). Tried after stage 3, not before: with click and noise still
//     at their rough first values, their error swamped the difference a
//     drive makes, and 80 renders per trial were too few to re-fit the
//     body (measured: 200 are enough, 400 gain nothing more).
//  5. Everything again from the best point, with a fresh, smaller simplex:
//     a simplex that has collapsed along one axis cannot recover on its
//     own.
//  6. The attack noise (see AttackNoise): what the original's first 50 ms
//     have that this voice lacks, measured, then level and the parameters
//     it trades against fitted briefly - twice, because the voice moves
//     once the noise is there. Kept only if the match gets better: on a
//     drum the voice can already make, the measured remainder is the
//     noise layers' own random fluctuation, and it is dropped.
//  The start phase is not fitted: the comparison is of levels, which a
//  phase hardly changes. It is measured again at the end against the
//  fitted pitch, the way the Analyzer measured it (least squares against
//  sine and cosine).
//
//  A snare fits the same stages with its own parameters added: the second
//  mode's level and decay with the body (they share the low end), its
//  ratio and the wires' width and shape with everything, the wires' shape
//  again with the attack noise (see `keys`).
//
//  A hi-hat and a modal drum have no sweep, no pitch track and no drive:
//  they fit in their own stages (see `fitDirect`) - everything, the click
//  on its grid, a hat's band on its grid, everything again, the attack
//  noise. Frequencies stay where the analysis measured them - a hat's
//  metal tone and mix, a modal drum's modes: the comparison, whose bands
//  at 8 kHz are 800 Hz wide, cannot tell one partial from another, and a
//  tone 0.07 % off already scores like another noise (1.2 dB on a
//  synthetic hat) - so the fit would only wander. A hat fits its level
//  (`gainDB`) in place of its noise's. A modal drum's modes 2-6 keep the
//  level and decay the analysis gave them too: fitted, they turned into
//  short loud bursts standing in for the attack (the 808 cowbell's 1777 Hz
//  mode from 0.53 and 20 ms to 1.52 and 13), and in semitone bands six of
//  the eight recorded drums came out closer with them held (808 cowbell
//  2.65 → 2.01 dB, Drumulator clave 5.58 → 4.49; the 808 rim 4.12 → 5.42
//  the exception). Its attack noise stays: without it all eight were
//  further off (8000 cowbell 2.94 → 4.78).
//
//  The grids run in parallel, one candidate per core (2026-09-26, the author's
//  request after the fits of different pads had): the quick drive look,
//  the click's tone × decay, the drive trials with their bodies and the
//  band's tone × width. Each candidate is independent - a Comparison only
//  reads its targets and vDSP's FFT setups may be shared - and the best is
//  still picked in the order the loops had, first on a tie, so a fit comes
//  out bit for bit as it did one candidate at a time. The simplex searches
//  themselves stay sequential: every step depends on the last.
//
//  The search runs in log units for everything that is a frequency or a
//  time, so a step means the same ratio at 50 Hz and at 5 kHz, and levels
//  and drive run linear. Values are clamped to the slider ranges
//  (ParamSpec), so the fit can never produce a value a slider cannot show.
//

import Foundation
import Synchronization

nonisolated struct FitReport: Sendable {
    var params: DrumParams
    var score: MatchScore
    /// The Analyzer's guess, scored the same way - how much the fit won.
    var initialScore: MatchScore
    var evaluations: Int
    var seconds: Double
}

nonisolated enum Fitter {
    static let bodyKeys = ["delay", "fundamental", "pitchStart", "pitchDecay", "ampAttack", "ampDecay", "ampShape", "gainDB"]
    static let allKeys = bodyKeys + ["drive", "transient", "clickTone", "clickDecay", "noise", "noiseTone", "noiseDecay"]
    /// The most drive the fit may use. The author's verdict on the first
    /// recorded kicks (2026-09-25): drive "sounds too hard". Uncapped, the fit had
    /// taken them to 2.6-8, flattening the first cycle into a square to
    /// buy decibels of match. First capped at 1.0, then on request at
    /// 0.5 - tanh(0.5·x)/tanh(0.5), where a half-amplitude sample comes out
    /// at 0.54 instead of 0.50. Measured on the three kicks at 0.5: envelope
    /// over 5-60 ms 1.1 / 1.6 / 5.4 dB (free: 0.9 / 1.0 / 4.7), peak within
    /// ±1.7 dB. The slider still goes to 8 by hand; Fit Again brings it
    /// back under the cap.
    static let maxDrive = 0.5
    static let driveTrials = [0.0, 0.25, 0.5]
    static let clickToneTrials = [300.0, 700, 1500, 3000, 6000, 12000]
    static let clickDecayTrials = [0.0005, 0.0015, 0.004]
    static let wireToneTrials = [0.5, 0.71, 1, 1.41, 2]
    static let wireWidthTrials = [1.0, 2, 3, 4.5, 6.5]
    static let wireLevelBudget = 12

    /// Evaluation budget per stage; the progress callback counts against
    /// their sum.
    static let bodyBudget = 400
    static let driveBudget = 200
    static let snareDriveBudget = 300
    static let fullBudget = 1000
    static let restartBudget = 600
    static let attackBudget = 400
    static let attackKeys = ["attackLevelDB", "gainDB", "delay", "ampDecay", "ampShape", "drive",
                             "transient", "noise", "noiseTone", "noiseDecay"]

    enum Stage { case body, all, attack, drive }

    /// The parameters a stage searches, for `model`.
    static func keys(_ stage: Stage, _ model: DrumModel) -> [String] {
        let snare = model == .snare
        switch stage {
        case .body: return bodyKeys + (snare ? ["mode2Level", "mode2Decay"] : [])
        case .all: return keys(.body, model) + allKeys.dropFirst(bodyKeys.count)
                + (snare ? ["mode2Ratio", "noiseWidth", "noiseShape"] : [])
        case .attack: return attackKeys + (snare ? ["noiseShape"] : [])
        // The body a drive is tried with. On a snare with the click's and
        // the wires' levels too: they are relative to the body's peak, so
        // a body that moves its level moves them, and the wires are loud
        // enough for that to decide the trial - held, the synthetic
        // snare's drive-0 trial could not raise its level and lost to 0.5
        // (0.33 dB against 0.28; with the two levels and 300 renders,
        // 0.18). Its second mode stays out: it is added after the drive.
        case .drive: return bodyKeys + (snare ? ["transient", "noise"] : [])
        }
    }

    /// Fits `analysis`, from `start` (default: the Analyzer's guess). The
    /// app passes the parameters as they stand for "Fit Again", so a
    /// hand-made change can steer the fit.
    ///
    /// The master envelope is taken off for the fit and put back on the
    /// result as it was: it is the user's cut, not part of the sound being
    /// matched, and left on it would have the fit lengthen every decay to
    /// make up for it. The report's scores are those of the voice without it.
    static func fit(_ analysis: Analysis, from start: DrumParams? = nil,
                    progress: @escaping (Double) -> Void = { _ in }) throws -> FitReport {
        guard let start, start.envelopeOn else {
            return try fitVoice(analysis, from: start, progress: progress)
        }
        var bare = start
        bare.envelopeOn = false
        var report = try fitVoice(analysis, from: bare, progress: progress)
        report.params.envelopeOn = true
        return report
    }

    private static func fitVoice(_ analysis: Analysis, from start: DrumParams?,
                                 progress: @escaping (Double) -> Void) throws -> FitReport {
        let model = (start ?? analysis.initial).model
        if model == .hat {
            return try fitDirect(analysis, from: start, keys: hatKeys, attackKeys: hatAttackKeys, bandLevel: "gainDB",
                                 progress: progress)
        }
        if model == .clap {
            return try fitDirect(analysis, from: start, keys: clapKeys, attackKeys: clapAttackKeys, bandLevel: "gainDB",
                                 progress: progress)
        }
        if model == .modal {
            return try fitDirect(analysis, from: start, keys: modalKeys, attackKeys: modalAttackKeys,
                                 bandLevel: nil, progress: progress)
        }
        let started = Date()
        let comparison = Comparison(target: analysis.hit, pitchTrack: analysis.pitchTrack)
        let wireGrid = (start ?? analysis.initial).isSnare
            ? wireToneTrials.count * wireWidthTrials.count * (wireLevelBudget + 1) + 1 : 0
        let driveTrialBudget0 = (start ?? analysis.initial).isSnare ? snareDriveBudget : driveBudget
        let total = Double(bodyBudget + driveTrials.count * (driveTrialBudget0 + 2) + clickToneTrials.count * clickDecayTrials.count
                           + fullBudget + wireGrid + restartBudget + 2 * (attackBudget + 1))
        let meter = FitMeter(total: total, progress: progress)
        func score(_ p: DrumParams) -> Double {
            meter.count()
            return comparison.score(p).total
        }
        var cancelled: Bool { meter.cancelled }

        let initial = analysis.initial
        // `length` is carried along untouched: the comparison always
        // renders the original's length, so the fit cannot see it.
        var best = start ?? initial
        let bodyKeys = keys(.body, best.model), allKeys = keys(.all, best.model)
        let attackKeys = keys(.attack, best.model)
        let driveKeys = keys(.drive, best.model)
        let driveTrialBudget = best.isSnare ? snareDriveBudget : driveBudget

        // 1. Body.
        best = search(bodyKeys, from: best, budget: bodyBudget, stepScale: 1, score: score, stop: { cancelled })
        if cancelled { throw CancellationError() }

        // 1b. A first, quick look at drive, on the body as fitted: enough
        // to catch a heavily driven kick (an 808 at drive 2 was found here
        // and lost when drive was left to stage 4 alone), too blunt for a
        // moderate one - stage 4 is for those.
        var bestValue = score(best)
        let plainBody = best
        let driven = driveTrials.filter { $0 != plainBody.drive }.map { drive -> DrumParams in
            var trial = plainBody
            trial.drive = drive
            return trial
        }
        (best, bestValue) = pick(best, bestValue, from: driven, values: parallel(driven.count) { score(driven[$0]) })

        // 2. Click.
        if best.transient > 0.01 {
            (best, bestValue) = clickGrid(best, bestValue, score: score)
        }

        // 3. Everything.
        best = search(allKeys, from: best, budget: fullBudget, stepScale: 1, score: score, stop: { cancelled })
        if cancelled { throw CancellationError() }

        // 3b. A snare's wires, on a grid of tone and width, each with its
        // level searched on its own (a wider band spreads the same power
        // thinner). The simplex narrowed the 909's wires where they
        // needed to widen: a band's edges move the comparison in cells
        // that are all noise, and its steps drown in their fluctuation.
        if best.isSnare && best.noise > 0.01 {
            best = bandGrid(best, level: "noise", score: score, stop: { cancelled })
            if cancelled { throw CancellationError() }
        }

        // 4. Drive, each trial with its own body.
        bestValue = score(best)
        let fitted = best
        let trialDrives = driveTrials.filter { abs($0 - fitted.drive) > 0.2 }
        let bodies = parallel(trialDrives.count) { i -> (DrumParams, Double) in
            var trial = fitted
            trial.drive = trialDrives[i]
            trial = search(driveKeys, from: trial, budget: driveTrialBudget, stepScale: 1, score: score, stop: { cancelled })
            return (trial, score(trial))
        }
        (best, bestValue) = pick(best, bestValue, from: bodies.map(\.0), values: bodies.map(\.1))
        if cancelled { throw CancellationError() }

        // 5. Everything again.
        best = search(allKeys, from: best, budget: restartBudget, stepScale: 0.3, score: score, stop: { cancelled })
        if cancelled { throw CancellationError() }

        // 6. Attack noise.
        best = try attackStage(best, keys: attackKeys, analysis: analysis, comparison: comparison, score: score,
                               stop: { cancelled })

        // The phase, against the fitted sweep.
        let cutoff = Analyzer.bodyCutoff(best.model, hz: best.fundamental)
        let body = Filters.lowPass(analysis.hit.array.map(Double.init), cutoff: cutoff, sampleRate: comparison.sampleRate)
        best.startPhase = Analyzer.startPhase(best, body: body, sampleRate: comparison.sampleRate)

        progress(1)
        return FitReport(params: best, score: comparison.score(best), initialScore: comparison.score(initial),
                         evaluations: meter.evaluations, seconds: Date().timeIntervalSince(started))
    }

    /// Tone × width of a band on a grid - the noise's, or with `tail` a
    /// clap's tail's - each with `level` searched on its own; the best, or
    /// `start` if none beats it.
    private static func bandGrid(_ start: DrumParams, level: String, tail: Bool = false,
                                 score: (DrumParams) -> Double, stop: () -> Bool) -> DrumParams {
        let tone: WritableKeyPath<DrumParams, Double> = tail ? \.clapTailTone : \.noiseTone
        let widthPath: WritableKeyPath<DrumParams, Double> = tail ? \.clapTailWidth : \.noiseWidth
        let startValue = score(start)
        let cells = wireToneTrials.flatMap { factor in wireWidthTrials.map { (factor, $0) } }
        let fitted = parallel(cells.count) { i -> (DrumParams, Double) in
            var trial = start
            trial[keyPath: tone] = min(max(start[keyPath: tone] * cells[i].0, 100), 16_000)
            trial[keyPath: widthPath] = cells[i].1
            trial = search([level], from: trial, budget: wireLevelBudget, stepScale: 1, score: score, stop: stop)
            return (trial, score(trial))
        }
        return pick(start, startValue, from: fitted.map(\.0), values: fitted.map(\.1)).0
    }

    /// The click's tone × decay, every cell scored at once.
    private static func clickGrid(_ start: DrumParams, _ startValue: Double,
                                  score: (DrumParams) -> Double) -> (DrumParams, Double) {
        let cells = clickToneTrials.flatMap { tone in clickDecayTrials.map { decay -> DrumParams in
            var trial = start
            trial.clickTone = tone
            trial.clickDecay = decay
            return trial
        } }
        return pick(start, startValue, from: cells, values: parallel(cells.count) { score(cells[$0]) })
    }

    /// The best of `candidates` if it beats `start`, taken in order with a
    /// strict "better than" - the first on a tie, as the loops were.
    private static func pick(_ start: DrumParams, _ startValue: Double, from candidates: [DrumParams],
                             values: [Double]) -> (DrumParams, Double) {
        var best = start, bestValue = startValue
        for (candidate, value) in zip(candidates, values) where value < bestValue {
            best = candidate
            bestValue = value
        }
        return (best, bestValue)
    }

    /// `work` for 0 ..< count at once, one per core, the results in order.
    /// Each writes only its own slot.
    static func parallel<T>(_ count: Int, _ work: (Int) -> T) -> [T] {
        guard count > 1 else { return (0..<count).map(work) }
        let slots = UnsafeMutableBufferPointer<T?>.allocate(capacity: count)
        slots.initialize(repeating: nil)
        defer {
            slots.deinitialize()
            slots.deallocate()
        }
        DispatchQueue.concurrentPerform(iterations: count) { slots[$0] = work($0) }
        return slots.map { $0! }
    }

    /// The attack noise (see AttackNoise): measured twice, each time with
    /// `keys` fitted briefly after, and kept only if it improves the match
    /// by 0.05 dB.
    private static func attackStage(_ start: DrumParams, keys: [String], analysis: Analysis, comparison: Comparison,
                                    score: (DrumParams) -> Double, stop: () -> Bool) throws -> DrumParams {
        let bestValue = score(start)
        var voice = start
        voice.attack = nil
        let original = analysis.hit.array.map(Double.init)
        let floorRatio = pow(10, analysis.noiseFloorDB / 20)
        var withAttack = voice
        for _ in 0..<2 {
            var plain = withAttack
            plain.attack = nil
            let synth = DrumSynth.render(plain, sampleRate: comparison.sampleRate, frames: comparison.frameCount)
            withAttack.attack = AttackNoise.measure(original: original, synth: synth.map(Double.init),
                                                    gain: pow(10, plain.gainDB / 20), floorRatio: floorRatio,
                                                    sampleRate: comparison.sampleRate)
            withAttack.attackLevelDB = 0
            withAttack = search(keys, from: withAttack, budget: attackBudget, stepScale: 1, score: score, stop: stop)
            if stop() { throw CancellationError() }
        }
        return score(withAttack) < bestValue - 0.05 ? withAttack : start
    }

    // MARK: - Hi-hat

    static let hatKeys = ["gainDB", "delay", "ampAttack", "transient", "clickTone", "clickDecay",
                          "noiseTone", "noiseWidth", "noiseDecay", "noiseShape"]
    static let hatAttackKeys = ["attackLevelDB", "gainDB", "delay", "transient", "noiseDecay", "noiseShape"]

    /// A clap's burst count is a whole number and stays as counted.
    static let clapKeys = ["gainDB", "delay", "clapSpacing", "clapBurstDecay", "noise", "noiseTone", "noiseWidth",
                           "noiseDecay", "noiseShape", "clapTailTone", "clapTailWidth",
                           "transient", "clickTone", "clickDecay"]
    static let clapAttackKeys = ["attackLevelDB", "gainDB", "clapBurstDecay", "noise", "noiseDecay", "noiseShape"]

    static let modalKeys = ["gainDB", "delay", "ampAttack", "ampDecay", "ampShape",
                            "transient", "clickTone", "clickDecay", "noise", "noiseTone", "noiseDecay"]
    static let modalAttackKeys = ["attackLevelDB", "gainDB", "delay", "ampDecay", "ampShape",
                                  "transient", "noise", "noiseTone", "noiseDecay"]

    /// A drum without a swept body: `keys` searched, the click on its
    /// grid, the band on its grid with `bandLevel` (a hat's), `keys` again,
    /// the attack noise.
    private static func fitDirect(_ analysis: Analysis, from start: DrumParams?, keys: [String],
                                  attackKeys: [String], bandLevel: String?,
                                  progress: @escaping (Double) -> Void) throws -> FitReport {
        let started = Date()
        let comparison = Comparison(target: analysis.hit, pitchTrack: analysis.pitchTrack)
        let oneGrid = wireToneTrials.count * wireWidthTrials.count * (wireLevelBudget + 1) + 1
        let bandGridBudget = (bandLevel == nil ? 0 : oneGrid) + ((start ?? analysis.initial).isClap ? oneGrid : 0)
        let total = Double(fullBudget + clickToneTrials.count * clickDecayTrials.count + bandGridBudget
                           + restartBudget + 2 * (attackBudget + 1) + 2)
        let meter = FitMeter(total: total, progress: progress)
        func score(_ p: DrumParams) -> Double {
            meter.count()
            return comparison.score(p).total
        }
        var cancelled: Bool { meter.cancelled }
        let initial = analysis.initial
        var best = start ?? initial

        best = search(keys, from: best, budget: fullBudget, stepScale: 1, score: score, stop: { cancelled })
        if cancelled { throw CancellationError() }

        if best.transient > 0.01 {
            best = clickGrid(best, score(best), score: score).0
        }

        if let bandLevel {
            best = bandGrid(best, level: bandLevel, score: score, stop: { cancelled })
            if cancelled { throw CancellationError() }
        }
        // A clap's tail has a band of its own, as far from a simplex step
        // (the synthetic clap's settled at 670 Hz for 1 kHz).
        if best.isClap && best.noise > 0.01 {
            best = bandGrid(best, level: "noise", tail: true, score: score, stop: { cancelled })
            if cancelled { throw CancellationError() }
        }

        best = search(keys, from: best, budget: restartBudget, stepScale: 0.3, score: score, stop: { cancelled })
        if cancelled { throw CancellationError() }

        if !attackKeys.isEmpty {
            best = try attackStage(best, keys: attackKeys, analysis: analysis, comparison: comparison, score: score,
                                   stop: { cancelled })
        }

        progress(1)
        return FitReport(params: best, score: comparison.score(best), initialScore: comparison.score(initial),
                         evaluations: meter.evaluations, seconds: Date().timeIntervalSince(started))
    }

    /// Nelder–Mead over the parameters named in `keys`, the rest held.
    static func search(_ keys: [String], from start: DrumParams, budget: Int, stepScale: Double,
                       score: (DrumParams) -> Double, stop: () -> Bool) -> DrumParams {
        let specs = keys.map(ParamSpec.spec)
        func encode(_ p: DrumParams) -> [Double] {
            specs.map { $0.logarithmic ? log(p[keyPath: $0.keyPath]) : p[keyPath: $0.keyPath] }
        }
        func decode(_ x: [Double]) -> DrumParams {
            var p = start
            for (i, spec) in specs.enumerated() {
                let value = spec.logarithmic ? exp(x[i]) : x[i]
                let upper = spec.id == "drive" ? min(spec.range.upperBound, maxDrive) : spec.range.upperBound
                p[keyPath: spec.keyPath] = min(max(value, spec.range.lowerBound), upper)
            }
            return p
        }
        let steps = specs.map { spec -> Double in
            stepScale * (spec.logarithmic ? 0.2 : step(for: spec.id))
        }
        let result = NelderMead.minimize({ score(decode($0)) }, start: encode(start), steps: steps,
                                         maxEvaluations: budget, tolerance: 1e-4, shouldStop: stop)
        return decode(result.point)
    }

    /// First steps for the linear parameters, in their own units.
    private static func step(for id: String) -> Double {
        switch id {
        case "gainDB": return 1
        case "delay": return 0.001
        case "drive": return 0.5
        case "transient": return 0.15
        case "noise": return 0.04
        default: return 0.1
        }
    }
}

/// A fit's evaluation count and cancellation, safe to touch from the
/// grids' threads. Progress every 20 evaluations, as before; cancellation
/// is only ever set, and only seen from a thread inside the fit's task -
/// the grid workers are not, and never clear it.
nonisolated final class FitMeter: @unchecked Sendable {
    private let total: Double
    private let progress: (Double) -> Void
    private let used = Atomic<Int>(0)
    private let stopped = Atomic<Bool>(false)

    init(total: Double, progress: @escaping (Double) -> Void) {
        self.total = total
        self.progress = progress
    }

    var evaluations: Int { used.load(ordering: .relaxed) }
    var cancelled: Bool { stopped.load(ordering: .relaxed) }

    func count() {
        let n = used.add(1, ordering: .relaxed).newValue
        if n % 20 == 0 {
            progress(min(Double(n) / total, 1))
            if Task.isCancelled { stopped.store(true, ordering: .relaxed) }
        }
    }
}
