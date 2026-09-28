//
//  DrumParams.swift
//  Transmute
//
//  Everything the synth needs to play one drum hit, and nothing else: the
//  answer the analysis looks for, the state the sliders edit, and what a
//  `.drumparams` file holds.
//
//  The voice is three layers (see DrumSynth):
//  - the body: one sine whose pitch falls from `pitchStart` to
//    `fundamental`, with an attack and a decay,
//  - the click: a short high-passed noise burst - the beater,
//  - the noise: band-passed noise with its own decay - the shell, the snare
//    wires of a tom next to it, the air.
//
//  Units are the ones a person reads: Hz, seconds, dB. Every decay is a
//  time constant - the time to fall to 1/e (−8.7 dB) - because that is the
//  one number an exponential really has; "decay to silence" depends on what
//  counts as silence. `ampShape` bends the body's decay: at 1 it is that
//  plain exponential, above 1 the drum holds first and then falls faster
//  (an 808's boom), below 1 it drops at once and lingers.
//
//  `transient` and `noise` are levels relative to the body's peak, so they
//  mean the same at any `gainDB`. `drive` saturates the body only (tanh):
//  saturation the analysis sees in the body's harmonics, and a noise layer
//  run through the same curve would change level with the drive.
//
//  On top of the three layers, a filter over the whole voice: off, or a
//  24 dB/oct low-pass or high-pass, or a band-pass, with its cutoff and Q.
//  Not something the analysis measures - the fit leaves it where it is -
//  but what the author reached for to finish a sound (in the author's
//  words: "with an extra filter it is almost complete").
//
//  And last, over everything - every layer, after the filter - a master
//  envelope (2026-09-26, the author's request): off, or full level for `envHold`
//  from the file's start, then down to exactly 0 over `envRelease` as
//  (1 − x)^`envCurve`. The layers each have their own decay, and on some
//  drums one of them - a noise band, a modal partial, a clap's tail - rings
//  on long after the rest; the envelope ends them all at one point, and
//  the file ends there too (`renderLength`). Not measured, not fitted: the
//  fit takes it off while it runs and puts it back (Fitter.fit), or Fit
//  Again would stretch the decays to make up for it.
//
//  Two models (`model`), chosen per drum:
//  - Kick / Tom: the three layers above, as they were built first.
//  - Snare: the same three, and two changes the recorded snares asked for
//    (2026-09-26, 626, 808, 909 and Drumulator snares, see Analyzer):
//    a second head mode - a sine at `mode2Ratio` times the body's pitch,
//    following its sweep, with its own level and a faster decay (on the
//    808, 10 ms against the body's 40) - and snare wires instead of the
//    shell: noise between a high- and a low-pass `noiseWidth` octaves
//    apart around `noiseTone`, broad where the shell's band is narrow,
//    and decaying with a shape (`noiseShape`), because the wires of the
//    909 and the 626 hold for 60-100 ms before they fall, which no plain
//    exponential does.
//  - Hi-Hat (2026-09-26, two 808 closed hats, an 808 open hat and two
//    acoustic ones): no body at all. Two layers through one band - the
//    wires' high- and low-pass - under one envelope, a rise over `ampAttack`
//    and then the wires' shaped decay: noise, and metal, six square waves
//    at the 808's ratios (205.3, 304.4, 369.6, 522.7, 540 and 800 Hz) with
//    `metalTone` the lowest. `gainDB` is then the start's RMS level, and
//    `noise` and `metal` the mix, their squares summing to 1 as analysed.
//  - Modal (2026-09-26, three cowbells, two claves, two rimshots and a
//    woodblock): no sweep - up to six damped sines. Mode 1 at `modalTone`,
//    its level the reference (`gainDB` its peak), its decay `ampDecay`;
//    modes 2-6 at their ratios of it, with their own level and decay.
//    `ampAttack` and `ampShape` apply to all six, so a shape under 1 gives
//    the 808 cowbell's fast drop and long ring. Click and the shell's noise
//    band as on a kick.
//  - Clap (2026-09-26, 808, 909, Linn and a "smooth" clap): no body - a
//    train of `clapBursts` noise bursts `clapSpacing` apart, each falling
//    with `clapBurstDecay`, then from the last one a tail at `noise` of
//    their level under the wires' shaped decay. The bursts through the
//    wires' band (`noiseTone`, `noiseWidth`), the tail through its own
//    (`clapTailTone`, `clapTailWidth`): the 909's tail is dark where its
//    bursts are broad, the "smooth" clap's brighter, and with one band the
//    fit settled on eight octaves at 770 Hz for the 909.
//    `gainDB` is a burst's RMS at its start.
//  The other models' parameters are kept, and ignored, on each.
//
//  Decoding is forgiving: a key missing from a file keeps its default, so a
//  file saved before a parameter existed still opens - a file from before
//  the snare model as a kick.
//

import Foundation

nonisolated enum FilterType: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, lowPass, bandPass, highPass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .lowPass: "Low-Pass"
        case .bandPass: "Band-Pass"
        case .highPass: "High-Pass"
        }
    }
}

/// Which voice the parameters play (see the file header).
nonisolated enum DrumModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case kick, snare, hat, modal, clap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kick: "Kick / Tom"
        case .snare: "Snare"
        case .hat: "Hi-Hat"
        case .modal: "Modal"
        case .clap: "Clap"
        }
    }
}

nonisolated struct DrumParams: Codable, Equatable, Sendable {
    var model: DrumModel = .kick
    var delay: Double = 0               // s of silence before the voice starts
    var fundamental: Double = 55        // Hz, where the pitch settles
    var pitchStart: Double = 160        // Hz at the start of the hit
    var pitchDecay: Double = 0.040      // s, time constant of the sweep
    var ampAttack: Double = 0.0005      // s, rise of the body
    var ampDecay: Double = 0.250        // s, time constant of the body
    var ampShape: Double = 1            // stretch of the decay, 1 = exponential
    var startPhase: Double = 0          // degrees, where the body's sine begins
    var drive: Double = 0               // tanh drive on the body, 0 = clean
    var transient: Double = 0.2         // click peak relative to the body's
    var clickTone: Double = 3000        // Hz, high-pass corner of the click
    var clickDecay: Double = 0.0015     // s
    var noise: Double = 0.05            // noise RMS at the start relative to the body's peak
    var noiseTone: Double = 2500        // Hz, centre of the noise band
    var noiseDecay: Double = 0.060      // s
    var gainDB: Double = -1             // dBFS of the body's peak
    var length: Double = 1.0            // s, the rendered length when not automatic
    /// Length follows the decay (see `renderLength`); off once the Length
    /// slider is moved by hand.
    var autoLength = true
    /// The measured attack noise (see AttackNoise), nil when there is none,
    /// and its level in dB.
    var attack: AttackTable? = nil
    var attackLevelDB: Double = 0
    var filterType: FilterType = .off
    var filterCutoff: Double = 2000     // Hz
    var filterQ: Double = 0.707
    /// The master envelope (see the file header).
    var envelopeOn = false
    var envHold: Double = 0.100         // s at full level, from the file's start
    var envRelease: Double = 0.300      // s from there down to 0
    var envCurve: Double = 3            // (1 − x)^curve; 1 = linear
    // Snare only.
    var mode2Level: Double = 0.3        // second mode's peak relative to the body's
    var mode2Ratio: Double = 1.7        // its pitch over the body's
    var mode2Decay: Double = 0.020      // s, its time constant
    var noiseWidth: Double = 3          // octaves between the wires' high- and low-pass
    var noiseShape: Double = 1          // stretch of the wires' decay, 1 = exponential
    // Hi-hat only.
    var metal: Double = 0.5             // metal RMS at the start relative to the reference level
    var metalTone: Double = 205.3       // Hz, the lowest of the six oscillators

    // Modal only: mode 1 at modalTone, modes 2-6 at their ratios of it.
    var modalTone: Double = 800         // Hz
    var modalRatio2: Double = 1.5
    var modalLevel2: Double = 0
    var modalDecay2: Double = 0.05
    var modalRatio3: Double = 2
    var modalLevel3: Double = 0
    var modalDecay3: Double = 0.05
    var modalRatio4: Double = 2.5
    var modalLevel4: Double = 0
    var modalDecay4: Double = 0.05
    var modalRatio5: Double = 3
    var modalLevel5: Double = 0
    var modalDecay5: Double = 0.05
    var modalRatio6: Double = 4
    var modalLevel6: Double = 0
    var modalDecay6: Double = 0.05

    var isSnare: Bool { model == .snare }
    var isHat: Bool { model == .hat }
    var isModal: Bool { model == .modal }
    var isClap: Bool { model == .clap }
    // Clap only.
    var clapBursts: Double = 4          // count, rounded when rendered
    var clapSpacing: Double = 0.010     // s between burst starts
    var clapBurstDecay: Double = 0.003  // s, each burst's time constant
    var clapTailTone: Double = 1200     // Hz, centre of the tail's band
    var clapTailWidth: Double = 3       // octaves

    /// The bursts as rendered: a whole number, at least one.
    var burstCount: Int { max(Int(clapBursts.rounded()), 1) }
    /// Where the last burst, and the tail, start after the delay.
    var tailStart: Double { Double(burstCount - 1) * clapSpacing }

    static let modalModes = 2...6
    static func modalKeyPaths(_ k: Int) -> (ratio: WritableKeyPath<DrumParams, Double>,
                                            level: WritableKeyPath<DrumParams, Double>,
                                            decay: WritableKeyPath<DrumParams, Double>) {
        switch k {
        case 2: (\.modalRatio2, \.modalLevel2, \.modalDecay2)
        case 3: (\.modalRatio3, \.modalLevel3, \.modalDecay3)
        case 4: (\.modalRatio4, \.modalLevel4, \.modalDecay4)
        case 5: (\.modalRatio5, \.modalLevel5, \.modalDecay5)
        default: (\.modalRatio6, \.modalLevel6, \.modalDecay6)
        }
    }

    /// Every sounding mode of a modal drum: frequency, level (mode 1 = 1),
    /// decay time constant.
    var modes: [(hz: Double, level: Double, decay: Double)] {
        var out = [(hz: modalTone, level: 1.0, decay: ampDecay)]
        for k in Self.modalModes {
            let paths = Self.modalKeyPaths(k)
            if self[keyPath: paths.level] > 0 {
                out.append((modalTone * self[keyPath: paths.ratio], self[keyPath: paths.level], self[keyPath: paths.decay]))
            }
        }
        return out
    }

    static let fileExtension = "drumparams"

    init() {}

    init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DrumParams()
        model = (try? c.decodeIfPresent(DrumModel.self, forKey: .model)) ?? d.model
        func value(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            try c.decodeIfPresent(Double.self, forKey: key) ?? fallback
        }
        delay = try value(.delay, d.delay)
        fundamental = try value(.fundamental, d.fundamental)
        pitchStart = try value(.pitchStart, d.pitchStart)
        pitchDecay = try value(.pitchDecay, d.pitchDecay)
        ampAttack = try value(.ampAttack, d.ampAttack)
        ampDecay = try value(.ampDecay, d.ampDecay)
        ampShape = try value(.ampShape, d.ampShape)
        startPhase = try value(.startPhase, d.startPhase)
        drive = try value(.drive, d.drive)
        transient = try value(.transient, d.transient)
        clickTone = try value(.clickTone, d.clickTone)
        clickDecay = try value(.clickDecay, d.clickDecay)
        noise = try value(.noise, d.noise)
        noiseTone = try value(.noiseTone, d.noiseTone)
        noiseDecay = try value(.noiseDecay, d.noiseDecay)
        gainDB = try value(.gainDB, d.gainDB)
        length = try value(.length, d.length)
        autoLength = try c.decodeIfPresent(Bool.self, forKey: .autoLength) ?? d.autoLength
        attack = try c.decodeIfPresent(AttackTable.self, forKey: .attack)
        attackLevelDB = try value(.attackLevelDB, d.attackLevelDB)
        filterType = (try? c.decodeIfPresent(FilterType.self, forKey: .filterType)) ?? d.filterType
        filterCutoff = try value(.filterCutoff, d.filterCutoff)
        filterQ = try value(.filterQ, d.filterQ)
        envelopeOn = try c.decodeIfPresent(Bool.self, forKey: .envelopeOn) ?? d.envelopeOn
        envHold = try value(.envHold, d.envHold)
        envRelease = try value(.envRelease, d.envRelease)
        envCurve = try value(.envCurve, d.envCurve)
        mode2Level = try value(.mode2Level, d.mode2Level)
        mode2Ratio = try value(.mode2Ratio, d.mode2Ratio)
        mode2Decay = try value(.mode2Decay, d.mode2Decay)
        noiseWidth = try value(.noiseWidth, d.noiseWidth)
        noiseShape = try value(.noiseShape, d.noiseShape)
        metal = try value(.metal, d.metal)
        metalTone = try value(.metalTone, d.metalTone)
        modalTone = try value(.modalTone, d.modalTone)
        clapBursts = try value(.clapBursts, d.clapBursts)
        clapSpacing = try value(.clapSpacing, d.clapSpacing)
        clapBurstDecay = try value(.clapBurstDecay, d.clapBurstDecay)
        clapTailTone = try value(.clapTailTone, d.clapTailTone)
        clapTailWidth = try value(.clapTailWidth, d.clapTailWidth)
        modalRatio2 = try value(.modalRatio2, d.modalRatio2)
        modalLevel2 = try value(.modalLevel2, d.modalLevel2)
        modalDecay2 = try value(.modalDecay2, d.modalDecay2)
        modalRatio3 = try value(.modalRatio3, d.modalRatio3)
        modalLevel3 = try value(.modalLevel3, d.modalLevel3)
        modalDecay3 = try value(.modalDecay3, d.modalDecay3)
        modalRatio4 = try value(.modalRatio4, d.modalRatio4)
        modalLevel4 = try value(.modalLevel4, d.modalLevel4)
        modalDecay4 = try value(.modalDecay4, d.modalDecay4)
        modalRatio5 = try value(.modalRatio5, d.modalRatio5)
        modalLevel5 = try value(.modalLevel5, d.modalLevel5)
        modalDecay5 = try value(.modalDecay5, d.modalDecay5)
        modalRatio6 = try value(.modalRatio6, d.modalRatio6)
        modalLevel6 = try value(.modalLevel6, d.modalLevel6)
        modalDecay6 = try value(.modalDecay6, d.modalDecay6)
        self = clamped()
    }

    /// Every parameter inside its range (see `ParamSpec.all`).
    func clamped() -> DrumParams {
        var p = self
        for spec in ParamSpec.all {
            p[keyPath: spec.keyPath] = min(max(p[keyPath: spec.keyPath], spec.range.lowerBound), spec.range.upperBound)
        }
        return p
    }

    // MARK: - The end

    /// The fade at the end: three periods of the fundamental, at least
    /// 30 ms (67 ms at 45 Hz). It was 5 ms - a quarter of a 45 Hz cycle -
    /// and wherever a decay was still sounding at the end, that cut came
    /// out as a click; a shorter Decay made it go away, which is how the
    /// author found it (2026-09-25).
    var fadeSeconds: Double { isHat || isModal || isClap ? 0.03 : max(0.03, 3 / fundamental) }

    /// When every layer has fallen 60 dB under the body's peak, in closed
    /// form from the parameters:
    /// - body: its envelope exp(−(u/τ)^k) reaches 10⁻³ at u = τ·(ln 1000)^(1/k),
    ///   the target lowered by drive's small-signal gain d/tanh d, which
    ///   lifts quiet parts;
    /// - click: peak-normalised under exp(−t/τ), so τ·ln(1000·level);
    /// - noise: RMS-normalised, with peaks about three times the RMS, so
    ///   τ·ln(3000·level) - on a snare τ·ln(3000·level)^(1/k), its shape;
    /// - a snare's second mode: τ·ln(1000·level) after the attack;
    /// - attack noise: its table's length.
    var tailSeconds: Double {
        if isHat { return hatTailSeconds }
        if isModal { return modalTailSeconds }
        if isClap { return clapTailSeconds }
        let driveGain = drive > 1e-4 ? drive / tanh(drive) : 1
        var tail = delay + ampAttack + ampDecay * pow(log(1000 * driveGain), 1 / ampShape)
        if transient > 0 { tail = max(tail, delay + clickDecay * max(log(1000 * transient), 0)) }
        if noise > 0 {
            let k = isSnare ? noiseShape : 1
            tail = max(tail, delay + noiseDecay * pow(max(log(3000 * noise), 0), 1 / k))
        }
        if isSnare && mode2Level > 0 {
            tail = max(tail, delay + ampAttack + mode2Decay * max(log(1000 * mode2Level), 0))
        }
        if let attack { tail = max(tail, attack.duration + attack.hop) }
        return tail
    }

    /// A hi-hat's: its noise and metal, RMS-normalised like the wires,
    /// after their rise, at τ·ln(3000·level)^(1/k) - "under the peak"
    /// meaning under the reference level here, there being no body; the
    /// click as on the other drums.
    private var hatTailSeconds: Double {
        var tail = delay + ampAttack
        let level = noise + metal
        if level > 0 { tail += noiseDecay * pow(max(log(3000 * level), 0), 1 / noiseShape) }
        if transient > 0 { tail = max(tail, delay + clickDecay * max(log(1000 * transient), 0)) }
        if let attack { tail = max(tail, attack.duration + attack.hop) }
        return tail
    }

    /// A modal drum's: each mode's exp(−(u/τ)^k) at 10⁻³ of mode 1's peak,
    /// after the rise; noise and click as on a kick.
    private var modalTailSeconds: Double {
        var tail = delay
        for mode in modes where mode.level > 0 {
            tail = max(tail, delay + ampAttack + mode.decay * pow(max(log(1000 * mode.level), 0), 1 / ampShape))
        }
        if transient > 0 { tail = max(tail, delay + clickDecay * max(log(1000 * transient), 0)) }
        if noise > 0 { tail = max(tail, delay + noiseDecay * max(log(3000 * noise), 0)) }
        if let attack { tail = max(tail, attack.duration + attack.hop) }
        return tail
    }

    /// A clap's: the last burst at 10⁻³ (peaks about three times the
    /// RMS, so τ·ln 3000), and the tail after it like the wires; the click.
    private var clapTailSeconds: Double {
        var tail = delay + tailStart + clapBurstDecay * log(3000)
        if noise > 0 { tail = max(tail, delay + tailStart + noiseDecay * pow(max(log(3000 * noise), 0), 1 / noiseShape)) }
        if transient > 0 { tail = max(tail, delay + clickDecay * max(log(1000 * transient), 0)) }
        if let attack { tail = max(tail, attack.duration + attack.hop) }
        return tail
    }

    /// Where the master envelope reaches 0.
    var envelopeEnd: Double { envHold + envRelease }

    /// What is rendered: automatic - the tail at −60 dB plus the fade, so
    /// the fade only ever meets silence - or `length` as set by hand; and
    /// never past where the master envelope, when on, has reached 0.
    /// Within the Length slider's range either way.
    var renderLength: Double {
        let range = ParamSpec.spec("length").range
        var seconds = autoLength ? tailSeconds + fadeSeconds : length
        if envelopeOn { seconds = min(seconds, envelopeEnd) }
        return min(max(seconds, range.lowerBound), range.upperBound)
    }

    /// The body's pitch at `t` seconds.
    func pitch(at t: Double) -> Double {
        fundamental + (pitchStart - fundamental) * exp(-max(t - delay, 0) / pitchDecay)
    }

    // MARK: - Files

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> DrumParams {
        try JSONDecoder().decode(DrumParams.self, from: Data(contentsOf: url))
    }
}

/// One row of the parameter panel: which field, its range, how to show it.
/// The fitter takes its bounds and its log/linear choice from the same
/// table, so a slider can always reach whatever the analysis found.
nonisolated struct ParamSpec: Identifiable, Sendable {
    enum Unit: Sendable { case hertz, seconds, degrees, ratio, decibels, amount, octaves, count }

    let id: String
    let title: String
    let keyPath: WritableKeyPath<DrumParams, Double> & Sendable
    let range: ClosedRange<Double>
    let unit: Unit
    /// Sliders move in log steps; the fitter searches in log space.
    let logarithmic: Bool
    /// The models that play it; nil for every one.
    var only: [DrumModel]? = nil

    func applies(to model: DrumModel) -> Bool { only?.contains(model) ?? true }

    func format(_ value: Double) -> String {
        switch unit {
        case .hertz: return value >= 1000 ? String(format: "%.2f kHz", value / 1000) : String(format: "%.1f Hz", value)
        case .seconds:
            return value < 0.01 ? String(format: "%.2f ms", value * 1000)
                : value < 1 ? String(format: "%.0f ms", value * 1000) : String(format: "%.2f s", value)
        case .degrees: return String(format: "%.0f°", value)
        case .ratio: return String(format: "%.2f", value)
        case .decibels: return String(format: "%.1f dB", value)
        case .amount: return String(format: "%.3f", value)
        case .octaves: return String(format: "%.1f oct", value)
        case .count: return String(format: "%.0f", value.rounded())
        }
    }

    static let all: [ParamSpec] = [
        ParamSpec(id: "delay", title: "Start delay", keyPath: \.delay, range: 0...0.03, unit: .seconds, logarithmic: false),
        ParamSpec(id: "fundamental", title: "Fundamental", keyPath: \.fundamental, range: 20...1000, unit: .hertz, logarithmic: true, only: [.kick, .snare]),
        ParamSpec(id: "pitchStart", title: "Pitch start", keyPath: \.pitchStart, range: 20...4000, unit: .hertz, logarithmic: true, only: [.kick, .snare]),
        ParamSpec(id: "pitchDecay", title: "Pitch decay", keyPath: \.pitchDecay, range: 0.001...1, unit: .seconds, logarithmic: true, only: [.kick, .snare]),
        ParamSpec(id: "ampAttack", title: "Attack", keyPath: \.ampAttack, range: 0.00005...0.05, unit: .seconds, logarithmic: true),
        ParamSpec(id: "ampDecay", title: "Decay", keyPath: \.ampDecay, range: 0.005...4, unit: .seconds, logarithmic: true, only: [.kick, .snare, .modal]),
        ParamSpec(id: "ampShape", title: "Decay shape", keyPath: \.ampShape, range: 0.4...4, unit: .ratio, logarithmic: true, only: [.kick, .snare, .modal]),
        ParamSpec(id: "startPhase", title: "Start phase", keyPath: \.startPhase, range: -180...180, unit: .degrees, logarithmic: false, only: [.kick, .snare]),
        ParamSpec(id: "drive", title: "Drive", keyPath: \.drive, range: 0...8, unit: .ratio, logarithmic: false, only: [.kick, .snare]),
        ParamSpec(id: "transient", title: "Click", keyPath: \.transient, range: 0...2, unit: .amount, logarithmic: false),
        ParamSpec(id: "clickTone", title: "Click tone", keyPath: \.clickTone, range: 200...16000, unit: .hertz, logarithmic: true),
        ParamSpec(id: "clickDecay", title: "Click decay", keyPath: \.clickDecay, range: 0.0002...0.02, unit: .seconds, logarithmic: true),
        ParamSpec(id: "noise", title: "Noise", keyPath: \.noise, range: 0...1, unit: .amount, logarithmic: false),
        ParamSpec(id: "noiseTone", title: "Noise tone", keyPath: \.noiseTone, range: 100...16000, unit: .hertz, logarithmic: true),
        ParamSpec(id: "noiseDecay", title: "Noise decay", keyPath: \.noiseDecay, range: 0.002...2, unit: .seconds, logarithmic: true),
        ParamSpec(id: "attackLevelDB", title: "Attack noise", keyPath: \.attackLevelDB, range: -40...12, unit: .decibels, logarithmic: false),
        ParamSpec(id: "gainDB", title: "Level", keyPath: \.gainDB, range: -60...6, unit: .decibels, logarithmic: false),
        ParamSpec(id: "length", title: "Length", keyPath: \.length, range: 0.05...10, unit: .seconds, logarithmic: true),
        ParamSpec(id: "filterCutoff", title: "Cutoff", keyPath: \.filterCutoff, range: 20...20000, unit: .hertz, logarithmic: true),
        ParamSpec(id: "filterQ", title: "Q", keyPath: \.filterQ, range: 0.5...12, unit: .ratio, logarithmic: true),
        ParamSpec(id: "envHold", title: "Hold", keyPath: \.envHold, range: 0.001...4, unit: .seconds, logarithmic: true),
        ParamSpec(id: "envRelease", title: "Release", keyPath: \.envRelease, range: 0.005...4, unit: .seconds, logarithmic: true),
        ParamSpec(id: "envCurve", title: "Curve", keyPath: \.envCurve, range: 0.25...8, unit: .ratio, logarithmic: true),
        ParamSpec(id: "mode2Level", title: "Mode 2", keyPath: \.mode2Level, range: 0...2, unit: .amount, logarithmic: false, only: [.snare]),
        ParamSpec(id: "mode2Ratio", title: "Mode 2 ratio", keyPath: \.mode2Ratio, range: 1.1...4, unit: .ratio, logarithmic: true, only: [.snare]),
        ParamSpec(id: "mode2Decay", title: "Mode 2 decay", keyPath: \.mode2Decay, range: 0.002...1, unit: .seconds, logarithmic: true, only: [.snare]),
        ParamSpec(id: "noiseWidth", title: "Noise width", keyPath: \.noiseWidth, range: 0.5...8, unit: .octaves, logarithmic: false, only: [.snare, .hat, .clap]),
        ParamSpec(id: "noiseShape", title: "Noise shape", keyPath: \.noiseShape, range: 0.4...4, unit: .ratio, logarithmic: true, only: [.snare, .hat, .clap]),
        ParamSpec(id: "metal", title: "Metal", keyPath: \.metal, range: 0...1.5, unit: .amount, logarithmic: false, only: [.hat]),
        ParamSpec(id: "metalTone", title: "Metal tone", keyPath: \.metalTone, range: 100...1000, unit: .hertz, logarithmic: true, only: [.hat]),
        ParamSpec(id: "clapBursts", title: "Bursts", keyPath: \.clapBursts, range: 1...8, unit: .count, logarithmic: false, only: [.clap]),
        ParamSpec(id: "clapSpacing", title: "Spacing", keyPath: \.clapSpacing, range: 0.003...0.03, unit: .seconds, logarithmic: true, only: [.clap]),
        ParamSpec(id: "clapBurstDecay", title: "Burst decay", keyPath: \.clapBurstDecay, range: 0.0005...0.03, unit: .seconds, logarithmic: true, only: [.clap]),
        ParamSpec(id: "clapTailTone", title: "Tail tone", keyPath: \.clapTailTone, range: 100...16000, unit: .hertz, logarithmic: true, only: [.clap]),
        ParamSpec(id: "clapTailWidth", title: "Tail width", keyPath: \.clapTailWidth, range: 0.5...8, unit: .octaves, logarithmic: false, only: [.clap]),
        ParamSpec(id: "modalTone", title: "Tone", keyPath: \.modalTone, range: 50...10000, unit: .hertz, logarithmic: true, only: [.modal]),
        ParamSpec(id: "modalRatio2", title: "Mode 2 ratio", keyPath: \.modalRatio2, range: 0.25...8, unit: .ratio, logarithmic: true, only: [.modal]),
        ParamSpec(id: "modalLevel2", title: "Mode 2", keyPath: \.modalLevel2, range: 0...2, unit: .amount, logarithmic: false, only: [.modal]),
        ParamSpec(id: "modalDecay2", title: "Mode 2 decay", keyPath: \.modalDecay2, range: 0.002...4, unit: .seconds, logarithmic: true, only: [.modal]),
        ParamSpec(id: "modalRatio3", title: "Mode 3 ratio", keyPath: \.modalRatio3, range: 0.25...8, unit: .ratio, logarithmic: true, only: [.modal]),
        ParamSpec(id: "modalLevel3", title: "Mode 3", keyPath: \.modalLevel3, range: 0...2, unit: .amount, logarithmic: false, only: [.modal]),
        ParamSpec(id: "modalDecay3", title: "Mode 3 decay", keyPath: \.modalDecay3, range: 0.002...4, unit: .seconds, logarithmic: true, only: [.modal]),
        ParamSpec(id: "modalRatio4", title: "Mode 4 ratio", keyPath: \.modalRatio4, range: 0.25...8, unit: .ratio, logarithmic: true, only: [.modal]),
        ParamSpec(id: "modalLevel4", title: "Mode 4", keyPath: \.modalLevel4, range: 0...2, unit: .amount, logarithmic: false, only: [.modal]),
        ParamSpec(id: "modalDecay4", title: "Mode 4 decay", keyPath: \.modalDecay4, range: 0.002...4, unit: .seconds, logarithmic: true, only: [.modal]),
        ParamSpec(id: "modalRatio5", title: "Mode 5 ratio", keyPath: \.modalRatio5, range: 0.25...8, unit: .ratio, logarithmic: true, only: [.modal]),
        ParamSpec(id: "modalLevel5", title: "Mode 5", keyPath: \.modalLevel5, range: 0...2, unit: .amount, logarithmic: false, only: [.modal]),
        ParamSpec(id: "modalDecay5", title: "Mode 5 decay", keyPath: \.modalDecay5, range: 0.002...4, unit: .seconds, logarithmic: true, only: [.modal]),
        ParamSpec(id: "modalRatio6", title: "Mode 6 ratio", keyPath: \.modalRatio6, range: 0.25...8, unit: .ratio, logarithmic: true, only: [.modal]),
        ParamSpec(id: "modalLevel6", title: "Mode 6", keyPath: \.modalLevel6, range: 0...2, unit: .amount, logarithmic: false, only: [.modal]),
        ParamSpec(id: "modalDecay6", title: "Mode 6 decay", keyPath: \.modalDecay6, range: 0.002...4, unit: .seconds, logarithmic: true, only: [.modal]),
    ]

    static func spec(_ id: String) -> ParamSpec { all.first { $0.id == id }! }
    static func find(_ id: String) -> ParamSpec? { all.first { $0.id == id } }

    /// Slider position 0…1 for a value, log or linear. The one mapping the
    /// sliders and MIDI CCs both use, so a knob at
    /// half-way is the slider at half-way.
    func position(of value: Double) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        let x = logarithmic ? log(value / lo) / log(hi / lo) : (value - lo) / (hi - lo)
        return min(max(x, 0), 1)
    }

    func value(at position: Double) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        let x = min(max(position, 0), 1)
        return logarithmic ? lo * pow(hi / lo, x) : lo + x * (hi - lo)
    }
}
