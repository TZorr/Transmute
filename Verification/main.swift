//
//  Verification/main.swift
//  Transmute
//
//  Self-checks for the engine, on signals where the right answer is known
//  in advance.
//
//  What is checked:
//  - the FFT round-trips and the Hilbert envelope follows a decay,
//  - the synth is deterministic, as long as asked, at its level, sweeping
//    exactly along its formula, and never jumps between samples,
//  - the snare voice: its second mode where its ratio puts it, its wires
//    holding with their shape, and its automatic length,
//  - the hi-hat voice: no body, its metal's partials at the 808's ratios,
//    its band's 24 dB/oct skirts, its length,
//  - the modal voice: its modes at their frequencies, from phase 0, each
//    decaying at its own rate,
//  - the clap voice: its bursts where their spacing puts them, its tail
//    through its own band, its length,
//  - the analysis plus fit find the parameters a drum was rendered with -
//    five kicks and toms, two of them under record hiss and crackle with a
//    lead-in, a snare, a hi-hat, a modal drum and a clap - and suggest the
//    model each was rendered with,
//  - on the author's recorded kicks, snares, hats, modal drums and claps, if the
//    folders are there, the fit
//    comes close to the original by measures it does not optimise, and the
//    analysis suggests the right model,
//  - every export format and depth reads back sample for sample within its
//    dither, at the rate it was rendered at, in one channel,
//  - the decoder folds stereo to mono by averaging, resamples, and refuses
//    a file too long to be one hit,
//  - a .drumparams file round-trips, opens with keys missing, and clamps,
//  - Export Kit names its files "<prefix> <pad number>" with the prefix
//    cleaned for the file system, skips nothing it was given, and every
//    file reads back at its pad's rate,
//  - the player starts every hit from its first sample and fades instead
//    of clicking when retriggered (its render block, driven by hand - no
//    audio device, no sound),
//  - the voice filter (off untouched; low-, high- and band-pass where they
//    should be), the slider mapping it shares with MIDI, the master
//    envelope (off untouched, the file ending on 0 where it ends, not
//    fitted), the .drumkit file, note and CC learn, the kit player with pan
//    and polyphony, and a virtual MIDI source whose notes and CCs reach the
//    input.
//
//  The limit of the recovery checks, stated where they are: each drum is
//  rendered by Transmute's own synth and analysed by Transmute's own
//  analysis. That proves the analysis inverts the synth - a necessary
//  condition, and one that caught real bugs - but not that a recorded kick
//  is modelled well. Only recordings can show that: the "Recorded kicks"
//  and "Recorded snares" sections, when the Test Samples folder is there
//  (not part of the repository).
//
//  Usage: Verification/run.sh [-O]
//

import Foundation
import AVFoundation
import Accelerate
import CoreMIDI

var failures = 0

func check(_ condition: Bool, _ message: String) {
    print("\(condition ? "  ok  " : "  FAIL") \(message)")
    if !condition { failures += 1 }
}

func section(_ title: String) { print("\n\(title)") }

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("transmute_harness_files")
try? FileManager.default.removeItem(at: scratch)
try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

func kickParams() -> DrumParams {
    var p = DrumParams()
    p.fundamental = 58; p.pitchStart = 140; p.pitchDecay = 0.072
    p.ampAttack = 0.0005; p.ampDecay = 0.32; p.ampShape = 1; p.startPhase = 0
    p.transient = 0.82; p.clickTone = 3000; p.clickDecay = 0.0015
    p.noise = 0.11; p.noiseTone = 2500; p.noiseDecay = 0.05
    p.gainDB = -3; p.length = 1.2
    p.autoLength = false    // test signals of a known length; the ending has its own checks
    return p
}

func snareParams() -> DrumParams {
    var p = DrumParams()
    p.model = .snare
    p.fundamental = 185; p.pitchStart = 230; p.pitchDecay = 0.02
    p.ampAttack = 0.0005; p.ampDecay = 0.06; p.ampShape = 1.2
    p.transient = 0.5; p.clickTone = 3000; p.clickDecay = 0.001
    p.noise = 0.45; p.noiseTone = 5000; p.noiseWidth = 3; p.noiseDecay = 0.07; p.noiseShape = 1.8
    p.mode2Level = 0.4; p.mode2Ratio = 1.8; p.mode2Decay = 0.015
    p.gainDB = -3; p.length = 0.5
    p.autoLength = false
    return p
}

func hatParams() -> DrumParams {
    var p = DrumParams()
    p.model = .hat
    p.gainDB = -12; p.ampAttack = 0.0005
    p.noiseTone = 8000; p.noiseWidth = 1.2; p.noiseDecay = 0.04; p.noiseShape = 1.5
    p.metalTone = 300; p.metal = 0.7.squareRoot(); p.noise = 0.3.squareRoot()
    p.transient = 0.3; p.clickTone = 6000; p.clickDecay = 0.0005
    p.length = 0.3
    p.autoLength = false
    return p
}

func modalParams() -> DrumParams {
    var p = DrumParams()
    p.model = .modal
    p.modalTone = 900; p.ampAttack = 0.0005; p.ampDecay = 0.1; p.ampShape = 1
    p.modalRatio2 = 1.33; p.modalLevel2 = 0.3; p.modalDecay2 = 0.08
    p.modalRatio3 = 2.0; p.modalLevel3 = 0.5; p.modalDecay3 = 0.02
    p.modalRatio4 = 3.0; p.modalLevel4 = 0.1; p.modalDecay4 = 0.1
    p.transient = 0.2; p.clickTone = 4000; p.clickDecay = 0.0005; p.noise = 0
    p.gainDB = -6; p.length = 0.6
    p.autoLength = false
    return p
}

func clapParams() -> DrumParams {
    var p = DrumParams()
    p.model = .clap
    p.clapBursts = 4; p.clapSpacing = 0.011; p.clapBurstDecay = 0.003
    p.noiseTone = 1500; p.noiseWidth = 4
    p.noise = 0.5; p.noiseDecay = 0.06; p.noiseShape = 0.8
    p.clapTailTone = 1000; p.clapTailWidth = 3
    p.transient = 0; p.gainDB = -12; p.length = 0.6
    p.autoLength = false
    return p
}

/// Mean |synth − original| of the RMS over 1 ms (every 0.5 ms) in the
/// first 60 ms, where the original is within 30 dB of its loudest: the
/// burst pattern of a clap, which the 5 ms octave cells blur.
func burstError(_ original: [Double], _ synth: [Double], sampleRate sr: Double) -> Double {
    let w = Int(0.001 * sr), hop = Int(0.0005 * sr)
    func levels(_ x: [Double]) -> [Double] {
        stride(from: 0, to: min(x.count, Int(0.06 * sr)) - w, by: hop).map { i in
            var ms = 0.0
            x.withUnsafeBufferPointer { vDSP_measqvD($0.baseAddress! + i, 1, &ms, vDSP_Length(w)) }
            return 10 * log10(ms + 1e-20)
        }
    }
    let a = levels(original), b = levels(synth)
    let top = a.max() ?? 0
    var sum = 0.0, count = 0.0
    for (x, y) in zip(a, b) where x > top - 30 { sum += abs(x - max(y, top - 60)); count += 1 }
    return count > 0 ? sum / count : 0
}

/// Semitone bands (100 Hz up) × 10 ms from 2048-point frames, in dB: fine
/// enough to see which partials sound - an octave band cannot tell a
/// cowbell from a sine and some noise of the same energy.
func semitoneGrid(_ x: [Double], sampleRate sr: Double) -> [[Double]] {
    let size = 2048, hop = Int(0.01 * sr)
    let edges = (0...88).map { 100 * pow(2, Double($0) / 12) }.filter { $0 < 0.45 * sr }
    let bin = sr / Double(size)
    return stride(from: 0, to: x.count, by: hop).map { i in
        let frame = Array(x[i..<min(i + size, x.count)])
        let m = Analyzer.spectrum(frame + [Double](repeating: 0, count: size - frame.count), size: size)
        return (0..<(edges.count - 1)).map { j in
            let a = Int(edges[j] / bin), b = max(Int(edges[j + 1] / bin), a + 1)
            return 10 * log10((a..<min(b, m.count)).map { m[$0] * m[$0] }.reduce(0, +) + 1e-14)
        }
    }
}

/// Mean |synth − original| over the semitone cells of the original within
/// 30 dB of its loudest (the synth floored 60 dB down).
func semitoneError(_ original: [Double], _ synth: [Double], sampleRate sr: Double) -> Double {
    let a = semitoneGrid(original, sampleRate: sr), b = semitoneGrid(synth, sampleRate: sr)
    let loudest = a.flatMap { $0 }.max() ?? 0
    var sum = 0.0, count = 0.0
    for (ra, rb) in zip(a, b) {
        for (x, y) in zip(ra, rb) where x > loudest - 30 { sum += abs(x - max(y, loudest - 60)); count += 1 }
    }
    return count > 0 ? sum / count : 0
}

/// Octave bands (63 Hz … 16 kHz) × 5 ms, in dB: coarse enough that two
/// renders of the same noise agree within about a decibel, fine enough to
/// see a band or a decay that is off.
func octaveGrid(_ x: [Double], sampleRate sr: Double) -> [[Double]] {
    let hop = Int(0.005 * sr)
    return (0..<9).map { b in
        let centre = 62.5 * pow(2, Double(b))
        let band = Filters.zeroPhase(x, [Biquad(.bandPass, frequency: centre, q: 1.41, sampleRate: sr),
                                         Biquad(.bandPass, frequency: centre, q: 1.41, sampleRate: sr)])
        return stride(from: 0, to: x.count, by: hop).map { i in
            let lo = max(i - hop, 0), hi = min(i + hop, x.count)
            var ms = 0.0
            band.withUnsafeBufferPointer { vDSP_measqvD($0.baseAddress! + lo, 1, &ms, vDSP_Length(hi - lo)) }
            return 10 * log10(ms + 1e-14)
        }
    }
}

/// Mean |synth − original| over the cells of the original within 20 dB of
/// its loudest - what is heard, not the quiet cells the noise fills.
func loudCellError(_ original: [Double], _ synth: [Double], sampleRate sr: Double) -> Double {
    let a = octaveGrid(original, sampleRate: sr), b = octaveGrid(synth, sampleRate: sr)
    let loudest = a.flatMap { $0 }.max() ?? 0
    var sum = 0.0, count = 0.0
    for (ra, rb) in zip(a, b) {
        for (x, y) in zip(ra, rb) where x > loudest - 20 { sum += abs(x - y); count += 1 }
    }
    return count > 0 ? sum / count : 0
}

// MARK: - FFT and envelope

section("FFT and envelope")
do {
    let fft = RealFFT(size: 1024)
    var noise = Xorshift(seed: 7)
    let input = (0..<1024).map { _ in Float(noise.next()) }
    var real = [Float](repeating: 0, count: 512), imag = [Float](repeating: 0, count: 512)
    var output = [Float](repeating: 0, count: 1024)
    input.withUnsafeBufferPointer { fft.forward($0.baseAddress!, real: &real, imag: &imag) }
    fft.inverse(real: &real, imag: &imag, output: &output)
    let error = zip(input, output).map { abs($0 - $1) }.max()!
    check(error < 1e-5, String(format: "inverse(forward(x)) == x (max error %.1e)", error))

    // A decaying 58 Hz sine, the shape the envelope is used on. It starts
    // with a step, and the analytic signal rings after a step: measured
    // +7 % at 10 ms, ±2 % by 50 ms, about 1 % from there on. The Analyzer
    // copes by fitting a free level over the whole decay (see fitDecay);
    // this checks the part it relies on.
    let decaying = (0..<48_000).map { i -> Double in
        let t = Double(i) / 48_000
        return 0.5 * exp(-t / 0.3) * sin(2 * Double.pi * 58 * t)
    }
    let envelope = Filters.envelope(decaying)
    var worst = 0.0
    for i in stride(from: 2400, to: 38_400, by: 48) {
        let truth = 0.5 * exp(-Double(i) / 48_000 / 0.3)
        worst = max(worst, abs(envelope[i] / truth - 1))
    }
    check(worst < 0.02, String(format: "Hilbert envelope of a decaying 58 Hz sine follows its exponential, 50-800 ms (worst %.2f %%)", worst * 100))
}

// MARK: - Synth

section("Synth")
do {
    var p = kickParams()
    let a = DrumSynth.render(p, sampleRate: 48_000)
    let b = DrumSynth.render(p, sampleRate: 48_000)
    check(a == b, "same parameters, same samples, bit for bit")
    check(a.count == 57_600, "1.2 s at 48 kHz is 57 600 frames (\(a.count))")
    check(DrumSynth.render(p, sampleRate: 44_100).count == 52_920, "and at 44.1 kHz 52 920")

    var clean = p
    clean.transient = 0; clean.noise = 0
    let body = DrumSynth.render(clean, sampleRate: 48_000)
    let peak = body.map(abs).max()!
    check(abs(20 * log10(Double(peak)) - clean.gainDB) < 0.1,
          String(format: "body peak %.2f dBFS for a level of %.1f dB", 20 * log10(Double(peak)), clean.gainDB))

    // After the attack, no step larger than a sine at the highest pitch
    // can take; during it, the rise adds at most π/2 per attack length.
    check(body[0] == 0, "the body starts from silence")
    let attackEnd = Int(clean.ampAttack * 48_000)
    let steepest = 2 * Double.pi * clean.pitchStart / 48_000 * Double(peak) * 1.05
    let rising = steepest + Double.pi / 2 / Double(attackEnd) * Double(peak)
    let steps = zip(body.dropFirst(), body).map { Double(abs($0 - $1)) }
    let jumpAfter = steps[attackEnd...].max()!, jumpDuring = steps[..<attackEnd].max()!
    check(jumpAfter <= steepest && jumpDuring <= rising,
          String(format: "no jumps: largest step %.4f ≤ %.4f after the attack, %.4f ≤ %.4f during it",
                 jumpAfter, steepest, jumpDuring, rising))

    // Every period measured from the zero crossings sits on the formula.
    var up: [Double] = []
    for i in 1..<body.count where body[i - 1] < 0 && body[i] >= 0 {
        up.append((Double(i - 1) + Double(body[i - 1] / (body[i - 1] - body[i]))) / 48_000)
    }
    var worst = 0.0
    for j in 1..<up.count where up[j] < 0.6 {
        // The phase advance across a period is exactly one cycle, so the
        // mean of the formula over it is 1 / period.
        let t0 = up[j - 1], t1 = up[j]
        let cycles = clean.fundamental * (t1 - t0)
            + (clean.pitchStart - clean.fundamental) * clean.pitchDecay * (exp(-t0 / clean.pitchDecay) - exp(-t1 / clean.pitchDecay))
        worst = max(worst, abs(cycles - 1))
    }
    check(worst < 0.002, String(format: "sweep follows f₁ + (f₀ − f₁)e^(−t/τ): every period within %.2f %% of one cycle", worst * 100))

    // The end. Automatic length: the drum has fallen 60 dB under the
    // body's peak before the fade begins, and the fade (three periods, at
    // least 30 ms) ends on exactly 0 - on a short kick, an 808 with a
    // held decay, and a decay lengthened by hand, which is where the
    // clicks came from with a 5 ms fade at the original's length.
    var long = clean
    long.ampDecay = 1.0
    var held = clean
    held.fundamental = 45; held.ampDecay = 0.5; held.ampShape = 2.2; held.drive = 0.5
    for (name, base) in [("kick", clean), ("808-style", held), ("long decay", long)] {
        var q = base
        q.autoLength = true
        let x = DrumSynth.render(q, sampleRate: 44_100)
        let frames = Int((q.renderLength * 44_100).rounded())
        let fadeStart = x.count - Int(q.fadeSeconds * 44_100)
        let gain = pow(10, q.gainDB / 20)
        let before = x[max(fadeStart - 441, 0)..<fadeStart].map { Double(abs($0)) }.max() ?? 0
        let tail = Array(x.suffix(4410))
        let bound = 2 * Double.pi * q.fundamental / 44_100 * Double(tail.map(abs).max() ?? 0) * 1.05 + 1e-9
        let step = zip(tail.dropFirst(), tail).map { Double(abs($0 - $1)) }.max() ?? 0
        check(x.count == frames && before <= gain * 1e-3 * 1.05 && x.last == 0 && step <= bound,
              String(format: "%@: auto length %.3f s, %.1f dB under the peak where the %.0f ms fade begins, ends on 0, no step",
                     name, q.renderLength, 20 * log10(max(before, 1e-12) / gain), q.fadeSeconds * 1000))
    }
    var high = clean
    high.fundamental = 150
    check(abs(held.fadeSeconds - 3 / 45.0) < 1e-12 && abs(clean.fadeSeconds - 3 / 58.0) < 1e-12 && high.fadeSeconds == 0.03,
          "the fade is three periods, at least 30 ms (45 Hz: 67 ms, 58 Hz: 52 ms, 150 Hz: 30 ms)")

    var manual = clean
    manual.autoLength = false
    manual.length = 0.2137
    let cut = DrumSynth.render(manual, sampleRate: 44_100)
    check(cut.count == Int((0.2137 * 44_100).rounded()) && cut.last == 0,
          "a length set by hand is kept to the frame, and still fades to 0")

    var auto = clean
    auto.autoLength = true
    let whole = DrumSynth.render(auto, sampleRate: 48_000)
    let window = DrumSynth.render(auto, sampleRate: 48_000, frames: 20_000)
    check(window == Array(whole.prefix(20_000)),
          "a window shorter than the drum is the drum's first frames, not a faded copy")
    check(DrumSynth.render(auto, sampleRate: 48_000, frames: whole.count + 5_000) == whole + [Float](repeating: 0, count: 5_000),
          "a window longer than the drum is the drum and silence")

    var driven = clean
    driven.drive = 3
    let hot = DrumSynth.render(driven, sampleRate: 48_000).map(abs).max()!
    check(abs(Double(hot) - Double(peak)) < 0.01, String(format: "drive keeps the peak (%.3f vs %.3f)", hot, peak))
}

section("Snare voice")
do {
    let p = snareParams()
    check(DrumSynth.render(p, sampleRate: 48_000) == DrumSynth.render(p, sampleRate: 48_000),
          "same parameters, same samples, bit for bit")

    // The second mode at its ratio of the body's pitch: with click, wires
    // and body's own sweep out of the way, the spectrum peaks at both.
    var tones = p
    tones.transient = 0; tones.noise = 0; tones.pitchStart = tones.fundamental
    tones.ampDecay = 0.2; tones.mode2Decay = 0.2
    let x = DrumSynth.render(tones, sampleRate: 48_000).map(Double.init)
    let m = Analyzer.spectrum(Array(x.prefix(24_000)), size: 1 << 16)
    let binHz = 48_000.0 / Double(1 << 16)
    func peak(near hz: Double) -> Double {
        let lo = Int(0.9 * hz / binHz), hi = Int(1.1 * hz / binHz)
        let k = (lo...hi).max { m[$0] < m[$1] }!
        return Analyzer.interpolatedPeak(m, k) * binHz
    }
    let first = peak(near: 185), second = peak(near: 185 * 1.8)
    check(abs(first - 185) < 0.5 && abs(second / first - 1.8) < 0.003,
          String(format: "the second mode sounds at %.1f Hz, %.3f × the body's %.1f Hz", second, second / first, first))

    // The wires hold with their shape: exp(−(t/τ)^k) at k 1.8 falls 30 dB
    // from 10 ms to 2τ, where a plain exponential falls 16. RMS over 12 ms
    // centred on each time (two renders of noise agree within ~0.5 dB).
    var wires = p
    wires.noise = 1
    let w = DrumSynth.noiseLayer(wires, sampleRate: 48_000, frames: 48_000)
    func rms(_ at: Double) -> Double {
        let i = Int(at * 48_000), half = 288
        return (w[(i - half)..<(i + half)].map { $0 * $0 }.reduce(0, +) / Double(2 * half)).squareRoot()
    }
    let t1 = 0.01, t2 = 2 * p.noiseDecay
    let drop = 20 * log10(rms(t1) / rms(t2))
    let expected = 20 * log10(M_E) * (pow(t2 / p.noiseDecay, 1.8) - pow(t1 / p.noiseDecay, 1.8))
    check(abs(drop - expected) < 1.5,
          String(format: "the wires fall %.1f dB from 10 ms to 2τ, as their shape says (%.1f; a plain exponential: %.1f)",
                 drop, expected, 20 * log10(M_E) * (t2 - t1) / p.noiseDecay))

    // Automatic length: wires and second mode have fallen about 60 dB
    // under the body's peak before the fade, and it still ends on 0. The
    // look is at the 10 ms before the fade, like the kick's, and a shaped
    // decay falls steeply there - 2.5 dB in those 10 ms at k 1.8 - so the
    // line is 57 dB, not 60.
    var auto = p
    auto.autoLength = true
    auto.noiseDecay = 0.15
    let y = DrumSynth.render(auto, sampleRate: 44_100)
    let fadeStart = y.count - Int(auto.fadeSeconds * 44_100)
    let before = y[max(fadeStart - 441, 0)..<fadeStart].map { Double(abs($0)) }.max() ?? 0
    let gain = pow(10, auto.gainDB / 20)
    check(y.count == Int((auto.renderLength * 44_100).rounded()) && before <= gain * pow(10, -57.0 / 20) && y.last == 0,
          String(format: "auto length %.3f s: %.1f dB under the peak in the 10 ms before the fade, ends on 0",
                 auto.renderLength, 20 * log10(max(before, 1e-12) / gain)))

    var kick = kickParams()
    kick.mode2Level = 1; kick.noiseWidth = 7; kick.noiseShape = 3
    check(DrumSynth.render(kick, sampleRate: 48_000) == DrumSynth.render(kickParams(), sampleRate: 48_000),
          "a kick ignores the snare's parameters")
}

section("Hi-hat voice")
do {
    let p = hatParams()
    check(DrumSynth.render(p, sampleRate: 48_000) == DrumSynth.render(p, sampleRate: 48_000),
          "same parameters, same samples, bit for bit")

    // No body: with noise, metal and click at 0 there is nothing at all.
    var silent = p
    silent.noise = 0; silent.metal = 0; silent.transient = 0
    check(DrumSynth.render(silent, sampleRate: 48_000).allSatisfy { $0 == 0 }, "no body: without its layers a hat is silence")

    // The metal's partials: the six squares' fundamentals at the 808's
    // ratios of the tone, in the unfiltered source.
    let source = DrumSynth.metalSource(tone: 205.3, sampleRate: 48_000, frames: 48_000)
    let m = Analyzer.spectrum(source, size: 1 << 16)
    let binHz = 48_000.0 / Double(1 << 16)
    let found = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0].map { hz -> Double in
        let lo = Int(0.99 * hz / binHz), hi = Int(1.01 * hz / binHz)
        let k = (lo...hi).max { m[$0] < m[$1] }!
        return Analyzer.interpolatedPeak(m, k) * binHz
    }
    let worst = zip(found, [205.3, 304.4, 369.6, 522.7, 540.0, 800.0]).map { abs($0 / $1 - 1) }.max()!
    check(worst < 0.001, String(format: "the metal's six oscillators sit at the 808's 205.3 … 800 Hz (worst %.3f %%)", worst * 100))

    // The band's skirts: an octave under the high-pass corner, 24 dB/oct
    // takes about 24 dB (a 12 dB/oct pair about 12).
    var wide = p
    wide.noiseTone = 8000; wide.noiseWidth = 2      // corners 4 and 16 kHz
    var random = Xorshift(seed: 5)
    let band = DrumSynth.bandPass((0..<96_000).map { _ in random.next() }, wide, sampleRate: 48_000)
    let spectrum = Analyzer.spectrum(band, size: 1 << 17)
    func level(_ hz: Double) -> Double {
        let bin = 48_000.0 / Double(1 << 17), k = Int(hz / bin), w = Int(0.1 * hz / bin)
        return 10 * log10(spectrum[(k - w)...(k + w)].map { $0 * $0 }.reduce(0, +) / Double(2 * w + 1))
    }
    let skirt = level(8000) - level(2000)
    check(skirt > 20 && skirt < 30, String(format: "the band falls %.1f dB an octave under its high-pass corner", skirt))

    var auto = p
    auto.autoLength = true
    let y = DrumSynth.render(auto, sampleRate: 44_100)
    let fadeStart = y.count - Int(auto.fadeSeconds * 44_100)
    let before = y[max(fadeStart - 441, 0)..<fadeStart].map { Double(abs($0)) }.max() ?? 0
    let gain = pow(10, auto.gainDB / 20)
    check(y.count == Int((auto.renderLength * 44_100).rounded()) && before <= gain * pow(10, -57.0 / 20) && y.last == 0,
          String(format: "auto length %.3f s: %.1f dB under the start's level in the 10 ms before the fade, ends on 0",
                 auto.renderLength, 20 * log10(max(before, 1e-12) / gain)))
}

section("Modal voice")
do {
    let p = modalParams()
    let x = DrumSynth.render(p, sampleRate: 48_000).map(Double.init)
    check(DrumSynth.render(p, sampleRate: 48_000) == DrumSynth.render(p, sampleRate: 48_000),
          "same parameters, same samples, bit for bit")
    var tones = p
    tones.transient = 0
    let y = DrumSynth.render(tones, sampleRate: 48_000).map(Double.init)
    check(y[0] == 0, "the modes start from phase 0, as a struck resonator does")
    let m = Analyzer.spectrum(Array(y.prefix(24_000)), size: 1 << 16)
    let binHz = 48_000.0 / Double(1 << 16)
    let want = [900.0, 900 * 1.33, 1800, 2700]
    let found = want.map { hz -> Double in
        let lo = Int(0.97 * hz / binHz), hi = Int(1.03 * hz / binHz)
        return Analyzer.interpolatedPeak(m, (lo...hi).max { m[$0] < m[$1] }!) * binHz
    }
    let worst = zip(found, want).map { abs($0 / $1 - 1) }.max()!
    check(worst < 0.001, String(format: "the modes sound at 900, 1197, 1800 and 2700 Hz (worst %.3f %%)", worst * 100))
    // Each at its own rate: mode 3 (20 ms) has fallen 26 dB more than mode
    // 1 (100 ms) from 10 to 80 ms: 70·(1/20 − 1/100) nepers.
    func level(_ hz: Double, _ at: Double) -> Double {
        let band = Filters.zeroPhase(y, [Biquad(.bandPass, frequency: hz, q: 20, sampleRate: 48_000),
                                         Biquad(.bandPass, frequency: hz, q: 20, sampleRate: 48_000)])
        let e = Filters.envelope(band)
        return 20 * log10(e[Int(at * 48_000)])
    }
    let fall1 = level(900, 0.01) - level(900, 0.08), fall3 = level(1800, 0.01) - level(1800, 0.08)
    let expected = 20 * log10(M_E) * 0.07 * (1 / 0.02 - 1 / 0.1)
    check(abs((fall3 - fall1) - expected) < 1.5,
          String(format: "mode 3 falls %.1f dB more than mode 1 over 10-80 ms (its decay says %.1f)", fall3 - fall1, expected))
    var auto = p
    auto.autoLength = true
    let z = DrumSynth.render(auto, sampleRate: 44_100)
    check(z.count == Int((auto.renderLength * 44_100).rounded()) && z.last == 0 && abs(auto.renderLength - (0.0005 + 0.1 * log(1000) + 0.03)) < 0.002,
          String(format: "auto length %.3f s: mode 1 at −60 dB, then 30 ms of fade, ending on 0", auto.renderLength))
    _ = x

    // Rendered with vForce since 2026-09-26: against the sample-by-sample
    // formula it replaced, the difference is rounding.
    var shaped = p
    shaped.ampShape = 1.6; shaped.ampAttack = 0.002
    let fast = DrumSynth.modal(shaped, sampleRate: 48_000, frames: 30_000)
    var slow = [Double](repeating: 0, count: 30_000)
    let attackFrames = Int(shaped.ampAttack * 48_000)
    for mode in shaped.modes {
        let m = min(30_000, attackFrames + Int(mode.decay * pow(12, 1 / shaped.ampShape) * 48_000) + 1)
        for i in 0..<m {
            let x = sin(0.5 * .pi * Double(i) / Double(attackFrames))
            let envelope = i < attackFrames ? x * x : exp(-pow(Double(i - attackFrames) / (mode.decay * 48_000), shaped.ampShape))
            slow[i] += mode.level * envelope * sin(2 * .pi * mode.hz * Double(i) / 48_000)
        }
    }
    let deviation = zip(fast, slow).map { abs($0 - $1) }.max() ?? 1
    check(deviation < 1e-9, String(format: "the vectorised modes equal the formula sample by sample (largest difference %.1e)", deviation))

    var kick = kickParams()
    kick.modalLevel2 = 1; kick.modalTone = 3000; kick.metal = 1
    check(DrumSynth.render(kick, sampleRate: 48_000) == DrumSynth.render(kickParams(), sampleRate: 48_000),
          "a kick ignores the hat's and the modal drum's parameters")
}

section("Clap voice")
do {
    let p = clapParams()
    check(DrumSynth.render(p, sampleRate: 48_000) == DrumSynth.render(p, sampleRate: 48_000),
          "same parameters, same samples, bit for bit")
    let x = DrumSynth.render(p, sampleRate: 48_000).map(Double.init)
    let found = Analyzer.bursts(x, sampleRate: 48_000).map(\.time)
    let want = (0..<4).map { Double($0) * 0.011 }
    // Found to about a millisecond: the peak of an RMS over 1 ms of noise.
    check(found.count == 4 && zip(found, want).allSatisfy { abs($0 - $1) < 0.0015 },
          "four bursts, 11 ms apart: " + found.map { String(format: "%.1f", $0 * 1000) }.joined(separator: ", ") + " ms")
    check(Analyzer.isClap(x, sampleRate: 48_000), "and they read as a clap")

    // The tail through its own band: measured the way the analysis does
    // (a log centroid leans to the top of a band octaves wide), the
    // tail's centre near its tone, the bursts' near theirs.
    func centre(_ from: Double, _ to: Double) -> Double {
        Analyzer.measureBand(Array(x[Int(from * 48_000)..<Int(to * 48_000)]), aboveHz: 100, sampleRate: 48_000)?.tone ?? 0
    }
    let bursts = centre(0, 0.03), tail = centre(0.1, 0.25)
    check(tail < bursts && abs(log2(tail / p.clapTailTone)) < 0.7 && abs(log2(bursts / p.noiseTone)) < 0.7,
          String(format: "bursts centred at %.0f Hz (tone %.0f), the tail at %.0f Hz (its tone %.0f)", bursts, p.noiseTone, tail, p.clapTailTone))

    var auto = p
    auto.autoLength = true
    let y = DrumSynth.render(auto, sampleRate: 44_100)
    let fadeStart = y.count - Int(auto.fadeSeconds * 44_100)
    let before = y[max(fadeStart - 441, 0)..<fadeStart].map { Double(abs($0)) }.max() ?? 0
    let gain = pow(10, auto.gainDB / 20)
    check(y.count == Int((auto.renderLength * 44_100).rounded()) && before <= gain * pow(10, -57.0 / 20) && y.last == 0,
          String(format: "auto length %.3f s: %.1f dB under a burst in the 10 ms before the fade, ends on 0",
                 auto.renderLength, 20 * log10(max(before, 1e-12) / gain)))

    var kick = kickParams()
    kick.clapBursts = 7; kick.clapTailTone = 300
    check(DrumSynth.render(kick, sampleRate: 48_000) == DrumSynth.render(kickParams(), sampleRate: 48_000),
          "a kick ignores the clap's parameters")
}

// MARK: - Recovery

section("Analysis and fit: recovering known drums")
print("  (rendered by this synth, analysed by this analysis: proves the one inverts the other, not more)")

struct Tolerance {
    let id: String
    let relative: Double?
    let absolute: Double?
}

func recover(_ name: String, _ truth: DrumParams, lead: Double = 0, vinyl: Bool = false,
             tolerances: [Tolerance], maxScore: Double) {
    let sr = 48_000.0
    var samples = [Float](repeating: 0, count: Int(lead * sr)) + DrumSynth.render(truth, sampleRate: sr)
    if vinyl {
        var random = Xorshift(seed: 99)
        var hiss = 0.0
        for i in samples.indices {
            hiss = 0.9 * hiss + 0.1 * random.next()
            samples[i] += Float(hiss * 0.01)                                  // ≈ −50 dB of hiss
            if i % 7919 == 0 { samples[i] += Float(0.2 * random.next()) }     // crackle
        }
    }
    let analysis: Analysis
    let report: FitReport
    do {
        analysis = try Analyzer.analyze(MonoAudio(samples, sampleRate: sr))
        report = try Fitter.fit(analysis)
    } catch {
        check(false, "\(name): \(error)")
        return
    }
    check(analysis.suggested == truth.model, "\(name): suggested as \(analysis.suggested.title)")
    let truthScore = Comparison(target: analysis.hit, pitchTrack: analysis.pitchTrack).score(truth).total
    print(String(format: "  %@: match %.2f dB (the true parameters score %.2f; the analysis alone %.2f), %d renders, %.1f s",
                 name, report.score.total, truthScore, report.initialScore.total, report.evaluations, report.seconds))
    if lead > 0 {
        check(abs(analysis.onsetSeconds - lead) < 0.0005,
              String(format: "%@: onset at %.2f ms (lead-in %.2f ms)", name, analysis.onsetSeconds * 1000, lead * 1000))
    }
    check(report.score.total <= maxScore, String(format: "%@: match ≤ %.2f dB", name, maxScore))
    for tolerance in tolerances {
        let spec = ParamSpec.spec(tolerance.id)
        let want = truth[keyPath: spec.keyPath], got = report.params[keyPath: spec.keyPath]
        var ok = true
        var limit = ""
        if let r = tolerance.relative { ok = abs(got / want - 1) <= r; limit = String(format: "±%.0f %%", r * 100) }
        if let a = tolerance.absolute { ok = abs(got - want) <= a; limit = "±" + spec.format(a) }
        check(ok, "\(name): \(spec.title) \(spec.format(got)), truth \(spec.format(want)) \(limit)")
    }
}

func body(_ extra: [Tolerance] = []) -> [Tolerance] {
    [Tolerance(id: "fundamental", relative: nil, absolute: 1),
     Tolerance(id: "pitchStart", relative: 0.05, absolute: nil),
     Tolerance(id: "pitchDecay", relative: 0.1, absolute: nil),
     Tolerance(id: "ampDecay", relative: 0.1, absolute: nil),
     Tolerance(id: "ampShape", relative: 0.1, absolute: nil),
     Tolerance(id: "gainDB", relative: nil, absolute: 0.5)] + extra
}

let kick = kickParams()
recover("kick", kick,
        tolerances: body([Tolerance(id: "transient", relative: nil, absolute: 0.15),
                          Tolerance(id: "clickTone", relative: 0.5, absolute: nil),
                          Tolerance(id: "noise", relative: nil, absolute: 0.03),
                          Tolerance(id: "noiseTone", relative: 0.2, absolute: nil),
                          Tolerance(id: "noiseDecay", relative: 0.2, absolute: nil)]),
        maxScore: 0.5)
recover("kick on vinyl", kick, lead: 0.05, vinyl: true,
        tolerances: body([Tolerance(id: "transient", relative: nil, absolute: 0.15),
                          Tolerance(id: "noise", relative: nil, absolute: 0.03),
                          Tolerance(id: "noiseDecay", relative: 0.2, absolute: nil)]),
        maxScore: 3.0)
var boom = kick
boom.fundamental = 45; boom.pitchStart = 90; boom.pitchDecay = 0.03
boom.ampDecay = 0.5; boom.ampShape = 2.2; boom.drive = 0.5   // the fit's cap (Fitter.maxDrive)
boom.transient = 0.1; boom.noise = 0; boom.length = 1.5
recover("808-style kick", boom,
        tolerances: body([Tolerance(id: "drive", relative: nil, absolute: 0.5),
                          Tolerance(id: "noise", relative: nil, absolute: 0.03)]),
        maxScore: 0.6)
// Drive under a record: saturation flattens the peaks, and a fit that
// tries drive too late gives a longer, rounder decay instead (drive 0.4
// for 1.2, before the Fitter's drive trials got a body fit of their own;
// 0.4 here since the fit stops at 0.5).
var driven = kick
driven.fundamental = 52; driven.pitchStart = 170; driven.pitchDecay = 0.045
driven.ampDecay = 0.28; driven.ampShape = 1.3; driven.drive = 0.4
driven.transient = 0.6; driven.clickTone = 2500; driven.noise = 0.08; driven.noiseTone = 3000
driven.noiseDecay = 0.04; driven.gainDB = -4; driven.length = 0.9; driven.startPhase = 20
recover("driven kick on vinyl", driven, lead: 0.03, vinyl: true,
        tolerances: body([Tolerance(id: "drive", relative: nil, absolute: 0.3)]),
        maxScore: 3.0)
var tom = kick
tom.fundamental = 110; tom.pitchStart = 150; tom.pitchDecay = 0.12; tom.ampDecay = 0.25
tom.transient = 0.3; tom.noise = 0.2; tom.noiseTone = 900; tom.noiseDecay = 0.08; tom.startPhase = 70
recover("tom", tom,
        tolerances: body([Tolerance(id: "startPhase", relative: nil, absolute: 10),
                          Tolerance(id: "noise", relative: nil, absolute: 0.03),
                          Tolerance(id: "noiseTone", relative: 0.2, absolute: nil),
                          Tolerance(id: "noiseDecay", relative: 0.2, absolute: nil)]),
        maxScore: 0.5)

recover("snare", snareParams(),
        tolerances: body([Tolerance(id: "mode2Level", relative: nil, absolute: 0.05),
                          Tolerance(id: "mode2Ratio", relative: 0.01, absolute: nil),
                          Tolerance(id: "mode2Decay", relative: 0.2, absolute: nil),
                          // Under the wires, the click's tone and length
                          // are hard to hear and to fit (1.7 kHz, 1.7 ms
                          // for 3 kHz, 1 ms); its level is checked.
                          Tolerance(id: "transient", relative: nil, absolute: 0.2),
                          Tolerance(id: "noise", relative: nil, absolute: 0.05),
                          Tolerance(id: "noiseTone", relative: 0.15, absolute: nil),
                          Tolerance(id: "noiseWidth", relative: nil, absolute: 0.5),
                          Tolerance(id: "noiseDecay", relative: 0.15, absolute: nil),
                          Tolerance(id: "noiseShape", relative: 0.15, absolute: nil)]),
        maxScore: 0.5)

recover("modal drum", modalParams(),
        tolerances: [Tolerance(id: "modalTone", relative: 0.005, absolute: nil),
                     Tolerance(id: "modalRatio2", relative: 0.01, absolute: nil),
                     Tolerance(id: "modalRatio3", relative: 0.01, absolute: nil),
                     Tolerance(id: "modalRatio4", relative: 0.01, absolute: nil),
                     Tolerance(id: "modalLevel2", relative: nil, absolute: 0.05),
                     Tolerance(id: "modalLevel3", relative: nil, absolute: 0.05),
                     Tolerance(id: "modalLevel4", relative: nil, absolute: 0.05),
                     Tolerance(id: "modalDecay2", relative: 0.15, absolute: nil),
                     Tolerance(id: "modalDecay3", relative: 0.15, absolute: nil),
                     Tolerance(id: "modalDecay4", relative: 0.15, absolute: nil),
                     Tolerance(id: "ampDecay", relative: 0.1, absolute: nil),
                     Tolerance(id: "gainDB", relative: nil, absolute: 0.5)],
        maxScore: 0.5)

recover("clap", clapParams(),
        tolerances: [Tolerance(id: "clapBursts", relative: nil, absolute: 0),
                     Tolerance(id: "clapSpacing", relative: 0.05, absolute: nil),
                     Tolerance(id: "clapBurstDecay", relative: 0.2, absolute: nil),
                     Tolerance(id: "gainDB", relative: nil, absolute: 1),
                     Tolerance(id: "noise", relative: nil, absolute: 0.1),
                     Tolerance(id: "noiseDecay", relative: 0.2, absolute: nil),
                     Tolerance(id: "noiseTone", relative: 0.25, absolute: nil),
                     Tolerance(id: "clapTailTone", relative: 0.25, absolute: nil)],
        maxScore: 0.5)

// The hat's Match limit is 1.5, not 0.5: its metal is deterministic, but
// a tone off by 0.07 % (299.8 Hz for 300, as measured) drifts its partials
// against the original's within milliseconds, and the comparison sees that
// like another noise - the true parameters at 299.8 Hz score 1.19 dB, the
// fit 1.03. The tone itself is checked to 0.5 %.
recover("hi-hat", hatParams(),
        tolerances: [Tolerance(id: "metalTone", relative: 0.005, absolute: nil),
                     Tolerance(id: "metal", relative: nil, absolute: 0.1),
                     Tolerance(id: "gainDB", relative: nil, absolute: 1),
                     Tolerance(id: "noiseTone", relative: 0.15, absolute: nil),
                     Tolerance(id: "noiseWidth", relative: nil, absolute: 0.5),
                     Tolerance(id: "noiseDecay", relative: 0.15, absolute: nil),
                     Tolerance(id: "noiseShape", relative: 0.15, absolute: nil)],
        maxScore: 1.5)

// MARK: - Parallel fits

section("Fits in parallel")
// The app runs as many fits at once as the Mac has cores less two. That
// is only right if a fit shares nothing with another: four drums fitted at
// once must come out as they do one at a time, bit for bit.
do {
    let drums = [kickParams(), snareParams(), hatParams(), modalParams()]
    let analyses = try drums.map { try Analyzer.analyze(MonoAudio(DrumSynth.render($0, sampleRate: 48_000), sampleRate: 48_000)) }
    let started = Date()
    let alone = try analyses.map { try Fitter.fit($0).params }
    let oneByOne = Date().timeIntervalSince(started)
    final class Results: @unchecked Sendable {
        var params: [DrumParams?]
        let lock = NSLock()
        init(_ n: Int) { params = Array(repeating: nil, count: n) }
    }
    let results = Results(analyses.count)
    let parallelStart = Date()
    DispatchQueue.concurrentPerform(iterations: analyses.count) { i in
        let p = try? Fitter.fit(analyses[i]).params
        results.lock.lock(); results.params[i] = p; results.lock.unlock()
    }
    let atOnce = Date().timeIntervalSince(parallelStart)
    check(results.params.map { $0 } == alone.map { Optional($0) },
          String(format: "four drums fitted at once equal their fits one at a time (%.1f s against %.1f s)", atOnce, oneByOne))
} catch {
    check(false, "parallel fits: \(error)")
}

// MARK: - Recorded kicks

section("Recorded kicks (Transmute/Test Samples/Kick, if present)")
// Recorded samples, not generated: the only check here that is not a round
// trip through Transmute's own synth. Judged by measures the fit does not
// optimise - peak level, and the envelope over 5-60 ms - because the match
// figure is the fit's own number. Skipped, not failed, when the folder is
// gone: the samples are not part of the repository.
let testSamples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Test Samples")
let samples = testSamples.appendingPathComponent("Kick")
if let names = try? FileManager.default.contentsOfDirectory(atPath: samples.path).filter({ $0.hasSuffix(".wav") }).sorted(),
   !names.isEmpty {
    for name in names {
        do {
            let (audio, _) = try Decoder.decode(samples.appendingPathComponent(name))
            let analysis = try Analyzer.analyze(audio)
            check(analysis.suggested == .kick, "\(name): suggested as \(analysis.suggested.title)")
            let report = try Fitter.fit(analysis)
            let sr = analysis.hit.sampleRate
            let o = analysis.hit.array.map(Double.init)
            let s = DrumSynth.render(report.params, sampleRate: sr, frames: analysis.hit.frameCount).map(Double.init)
            let eo = Filters.envelope(o), es = Filters.envelope(s)
            let w = Int(0.001 * sr)
            func db(_ e: [Double], _ ms: Double) -> Double {
                let i = Int(ms / 1000 * sr), lo = max(i - w, 0), hi = min(i + w, e.count)
                return 20 * log10(e[lo..<hi].reduce(0, +) / Double(max(hi - lo, 1)) + 1e-9)
            }
            let peak = 20 * log10(s.map(abs).max()! / o.map(abs).max()!)
            let envelope = stride(from: 5.0, through: 60, by: 1).map { abs(db(eo, $0) - db(es, $0)) }.reduce(0, +) / 56
            print(String(format: "  %@: match %.2f dB, peak %+.1f dB, envelope 5-60 ms %.1f dB, start %.1f ms, attack noise %@, %.1f s",
                         name, report.score.total, peak, envelope, report.params.delay * 1000,
                         report.params.attack == nil ? "off" : "on", report.seconds))
            // Measured 2026-09-25: the two acoustic kicks at −2.2 / −1.3 dB
            // and 0.9 / 1.0 dB with drive free, 1.1 / 1.6 dB with drive
            // capped at 0.5 (Fitter.maxDrive - the author's call, it sounded too
            // hard), hence the 2 dB line. The heavily
            // distorted lofi kick: +0.8 dB but 5.2 dB of envelope - its
            // lopsided clipping is beyond the voice, so it is reported, not
            // held to the same line.
            check(abs(peak) <= 3, "\(name): peak within 3 dB of the original's")
            if !name.contains("Lofi") {
                check(envelope <= 2, "\(name): envelope over 5-60 ms within 2 dB")
            }
        } catch {
            check(false, "\(name): \(error.localizedDescription)")
        }
    }
} else {
    print("  skipped: no Test Samples/Kick folder beside the project")
}

// MARK: - Recorded snares

section("Recorded snares (Transmute/Test Samples/Snare, if present)")
// Drum-machine snares (626, 808, 909, Drumulator), 2026-09-26. Judged
// by the loud cells (see loudCellError): the Match figure of a snare is
// mostly its wires' noise - two renders of the same parameters with
// different noise seeds already scored 2.5-4.7 dB apart - and so is its
// sample peak. Each snare is also fitted as a kick, and the snare model
// must not be the worse of the two by more than the noise: measured
// 2026-09-26, loud cells 1.89 / 1.37 / 1.75 / 1.83 dB for the 626, 808,
// 909 and Drumulator, as a kick 2.08 / 1.17 / 2.63 / 2.15 - the 808's
// wires are close to the kick's one band, and the kick's filter lost the
// 909's pitch (27 Hz). The loudest millisecond came out +3.3 / +1.4 /
// +0.9 / +0.1 dB: the 626's click.
let snares = testSamples.appendingPathComponent("Snare")
if let names = try? FileManager.default.contentsOfDirectory(atPath: snares.path).filter({ $0.hasSuffix(".wav") }).sorted(),
   !names.isEmpty {
    for name in names {
        do {
            let (audio, _) = try Decoder.decode(snares.appendingPathComponent(name))
            let analysis = try Analyzer.analyze(audio)
            check(analysis.suggested == .snare && analysis.initial.model == .snare,
                  "\(name): suggested and analysed as \(analysis.suggested.title)")
            let report = try Fitter.fit(analysis)
            let asKick = try Fitter.fit(try Analyzer.analyze(audio, model: .kick))
            let sr = analysis.hit.sampleRate
            let o = analysis.hit.array.map(Double.init)
            func synth(_ p: DrumParams) -> [Double] {
                DrumSynth.render(p, sampleRate: sr, frames: analysis.hit.frameCount).map(Double.init)
            }
            let s = synth(report.params)
            let loud = loudCellError(o, s, sampleRate: sr)
            let loudKick = loudCellError(o, synth(asKick.params), sampleRate: sr)
            func rmsPeak(_ x: [Double]) -> Double {
                let w = Int(0.001 * sr)
                return stride(from: 0, to: x.count - w, by: w / 4).map { i in
                    (x[i..<(i + w)].map { $0 * $0 }.reduce(0, +) / Double(w)).squareRoot()
                }.max() ?? 0
            }
            let level = 20 * log10(rmsPeak(s) / rmsPeak(o))
            let p = report.params
            print(String(format: "  %@: loud cells %.2f dB (as a kick %.2f), 1 ms level %+.1f dB, match %.2f, mode 2 %.2f × %.2f, wires %.1f oct at %.0f Hz, shape %.2f, %.1f s",
                         name, loud, loudKick, level, report.score.total, p.mode2Level, p.mode2Ratio,
                         p.noiseWidth, p.noiseTone, p.noiseShape, report.seconds))
            check(loud <= 2.5, "\(name): loud cells within 2.5 dB")
            check(loud <= loudKick + 0.3, "\(name): no worse than the kick model beyond the noise (0.3 dB)")
            check(abs(level) <= 3.5, "\(name): loudest millisecond within 3.5 dB of the original's")
        } catch {
            check(false, "\(name): \(error.localizedDescription)")
        }
    }
} else {
    print("  skipped: no Test Samples/Snare folder beside the project")
}

// MARK: - Recorded hi-hats

section("Recorded hi-hats (Transmute/Test Samples/Hat, if present)")
// Two 808 closed hats, an 808 open one and two acoustic hats, 2026-09-26.
// Judged by the loud cells like the snares, and against both other
// models: measured, 1.67 / 0.86 / 1.52 / 1.04 / 1.40 dB as a hat (808 HRD
// CHH, 808BRT OHH, 808DNC CHH1, HARD CHH 1 and 2), 1.6-5.5 as a snare and
// 2.1-4.0 as a kick. With a 12 dB/oct band the hat model had lost to the
// snare's on three of them: 10-23 dB too much at 1-4 kHz.
let hats = testSamples.appendingPathComponent("Hat")
if let names = try? FileManager.default.contentsOfDirectory(atPath: hats.path).filter({ $0.hasSuffix(".wav") }).sorted(),
   !names.isEmpty {
    for name in names {
        do {
            let (audio, _) = try Decoder.decode(hats.appendingPathComponent(name))
            let analysis = try Analyzer.analyze(audio)
            check(analysis.suggested == .hat && analysis.initial.model == .hat,
                  "\(name): suggested and analysed as \(analysis.suggested.title)")
            let report = try Fitter.fit(analysis)
            let sr = analysis.hit.sampleRate
            let o = analysis.hit.array.map(Double.init)
            func loud(_ p: DrumParams) -> Double {
                loudCellError(o, DrumSynth.render(p, sampleRate: sr, frames: analysis.hit.frameCount).map(Double.init),
                              sampleRate: sr)
            }
            let asHat = loud(report.params)
            let others = try [DrumModel.snare, .kick].map { try loud(Fitter.fit(try Analyzer.analyze(audio, model: $0)).params) }
            let p = report.params
            print(String(format: "  %@: loud cells %.2f dB (as a snare %.2f, as a kick %.2f), match %.2f, metal %.2f at %.1f Hz, noise %.2f, band %.0f Hz %.1f oct, %.1f s",
                         name, asHat, others[0], others[1], report.score.total, p.metal, p.metalTone, p.noise,
                         p.noiseTone, p.noiseWidth, report.seconds))
            check(asHat <= 2, "\(name): loud cells within 2 dB")
            check(asHat <= others.min()! + 0.1, "\(name): closer than the snare and kick models")
        } catch {
            check(false, "\(name): \(error.localizedDescription)")
        }
    }
} else {
    print("  skipped: no Test Samples/Hat folder beside the project")
}

// MARK: - Recorded modal drums

section("Recorded modal drums (Transmute/Test Samples/Modal, if present)")
// Three cowbells (8000, 808, Linn), two claves (808, Drumulator), two rims
// (808, 909) and a woodblock, 2026-09-26. Judged in semitone bands (see
// semitoneError): octave bands scored a kick's sine and noise as close to
// a cowbell as the modes were. Each is fitted as all four models;
// measured, modal was the closest on seven of the eight - 808 rim the
// exception, 5.4 dB against 3.4 as a kick: fifty milliseconds, its
// partials gone after fifteen and high noise left - and within 7 dB on
// all.
let modal = testSamples.appendingPathComponent("Modal")
if let names = try? FileManager.default.contentsOfDirectory(atPath: modal.path).filter({ $0.hasSuffix(".wav") }).sorted(),
   !names.isEmpty {
    var wins = 0
    for name in names {
        do {
            let (audio, _) = try Decoder.decode(modal.appendingPathComponent(name))
            let analysis = try Analyzer.analyze(audio)
            check(analysis.suggested == .modal && analysis.initial.model == .modal,
                  "\(name): suggested and analysed as \(analysis.suggested.title)")
            let report = try Fitter.fit(analysis)
            let sr = analysis.hit.sampleRate
            let o = analysis.hit.array.map(Double.init)
            func error(_ p: DrumParams) -> Double {
                semitoneError(o, DrumSynth.render(p, sampleRate: sr, frames: analysis.hit.frameCount).map(Double.init),
                              sampleRate: sr)
            }
            let own = error(report.params)
            let others = try [DrumModel.kick, .snare, .hat].map { try error(Fitter.fit(try Analyzer.analyze(audio, model: $0)).params) }
            if own <= others.min()! { wins += 1 }
            print(String(format: "  %@: semitone cells %.2f dB (kick %.2f, snare %.2f, hat %.2f), match %.2f, %d modes from %.0f Hz, %.1f s",
                         name, own, others[0], others[1], others[2], report.score.total, report.params.modes.count,
                         report.params.modalTone, report.seconds))
            check(own <= 7, "\(name): semitone cells within 7 dB")
        } catch {
            check(false, "\(name): \(error.localizedDescription)")
        }
    }
    check(wins >= names.count - 1, "modal the closest model on \(wins) of \(names.count) (at most one exception)")
} else {
    print("  skipped: no Test Samples/Modal folder beside the project")
}

// MARK: - Recorded claps

section("Recorded claps (Transmute/Test Samples/Clap, if present)")
// 808, 909, Linn and a "smooth" clap, 2026-09-26. Judged by their burst
// pattern (see burstError) against all five models, and by the loud
// octave cells like the other noise drums. Measured: bursts 2.01 / 2.96 /
// 2.12 / 2.19 dB as a clap (808, 909, Linn, smooth), the best other model
// 2.44-4.10 (the hat, mostly); loud cells 1.7-3.1. The Linn is a real clap with ragged hands - two clean bursts -
// and is not suggested as one (it comes out modal); chosen, it fits best.
let claps = testSamples.appendingPathComponent("Clap")
if let names = try? FileManager.default.contentsOfDirectory(atPath: claps.path).filter({ $0.hasSuffix(".wav") }).sorted(),
   !names.isEmpty {
    for name in names {
        do {
            let (audio, _) = try Decoder.decode(claps.appendingPathComponent(name))
            let suggested = try Analyzer.analyze(audio).suggested
            if !name.contains("LINN") {
                check(suggested == .clap, "\(name): suggested as \(suggested.title)")
            }
            let analysis = try Analyzer.analyze(audio, model: .clap)
            let report = try Fitter.fit(analysis)
            let sr = analysis.hit.sampleRate
            let o = analysis.hit.array.map(Double.init)
            func synth(_ p: DrumParams) -> [Double] {
                DrumSynth.render(p, sampleRate: sr, frames: analysis.hit.frameCount).map(Double.init)
            }
            let own = burstError(o, synth(report.params), sampleRate: sr)
            let loud = loudCellError(o, synth(report.params), sampleRate: sr)
            let others = try [DrumModel.kick, .snare, .hat, .modal].map {
                burstError(o, synth(try Fitter.fit(try Analyzer.analyze(audio, model: $0)).params), sampleRate: sr)
            }
            let p = report.params
            print(String(format: "  %@ (suggested %@): bursts %.2f dB (kick %.2f, snare %.2f, hat %.2f, modal %.2f), loud cells %.2f, match %.2f, %d bursts %.1f ms apart, %.1f s",
                         name, suggested.title, own, others[0], others[1], others[2], others[3], loud, report.score.total,
                         p.burstCount, p.clapSpacing * 1000, report.seconds))
            check(own <= others.min()!, "\(name): the clap model closest in its bursts")
            check(loud <= 3.2, "\(name): loud cells within 3.2 dB")
        } catch {
            check(false, "\(name): \(error.localizedDescription)")
        }
    }
} else {
    print("  skipped: no Test Samples/Clap folder beside the project")
}

// MARK: - Export

section("Export")

/// Reads a file back at its own rate, and what it says it is.
func readBack(_ url: URL) throws -> (samples: [Float], format: AVAudioFormat) {
    let file = try AVAudioFile(forReading: url)
    let format = file.fileFormat
    let (audio, _) = try Decoder.decode(url, rate: format.sampleRate)
    return (audio.array, format)
}

do {
    // −6 dB: the kick's click lands on the body's first peak, and at −1 dB
    // the sum reached +3 dBFS - which the float formats keep and the
    // integer ones clip. That is what the formats do; what the app does
    // about it is to show the peak (see ClipWarning in the UI).
    var p = kickParams()
    p.gainDB = -6
    check(DrumSynth.renderAudio(p, sampleRate: 48_000).peak < 1, "the export test signal stays below 0 dBFS")
    for rate in [44_100.0, 48_000.0] {
        let audio = DrumSynth.renderAudio(p, sampleRate: rate)
        for format in OutputFormat.allCases {
            for quality in format.qualityOptions {
                let url = scratch.appendingPathComponent("export_\(Int(rate))_\(format.rawValue)_\(quality.label).\(format.fileExtension)")
                do {
                    try Exporter.export(audio, format: format, quality: quality, to: url)
                    let (samples, fileFormat) = try readBack(url)
                    let n = min(samples.count, audio.frameCount)
                    var error: Float = 0
                    for i in 0..<n { error = max(error, abs(samples[i] - audio.samples[i])) }
                    // Dither ±1 LSB plus rounding half an LSB.
                    let lsb = quality.integerBitDepth.map { 1 / Float(1 << ($0 - 1)) } ?? 1e-6
                    let depth = quality.pcmBits.map { UInt32($0) } ?? 0
                    let storedDepth = fileFormat.streamDescription.pointee.mBitsPerChannel
                    let depthOK = fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM
                        ? storedDepth == depth : true
                    check(samples.last == 0, "\(format.menuTitle) \(quality.label): the last sample reads back as exactly 0")
                    check(samples.count == audio.frameCount && error <= 1.6 * lsb && fileFormat.channelCount == 1
                          && fileFormat.sampleRate == rate && depthOK,
                          String(format: "%@ %@ at %.1f kHz: %d frames, mono, max error %.2f LSB",
                                 format.menuTitle, quality.label, rate / 1000, samples.count, error / lsb))
                } catch {
                    check(false, "\(format.menuTitle) \(quality.label): \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Export Kit

section("Export Kit")
do {
    check(KitExport.fileName(prefix: "TR-707 Transmute", index: 0, fileExtension: "wav") == "TR-707 Transmute 1.wav"
          && KitExport.fileName(prefix: "TR-707 Transmute", index: 7, fileExtension: "wav") == "TR-707 Transmute 8.wav",
          "prefix \"TR-707 Transmute\": pad 1 → \"TR-707 Transmute 1.wav\", pad 8 → \"TR-707 Transmute 8.wav\"")
    check(KitExport.cleanPrefix("  a/b:c   d ") == "a-b-c d" && KitExport.cleanPrefix("   ") == "Kit"
          && KitExport.cleanPrefix("..hidden") == "hidden",
          "the prefix loses / and : (to -), extra spaces and leading dots; empty is \"Kit\"")

    // Pads 1, 3 and 8 - the numbers are the pads', gaps and all - at two
    // rates, as 24-bit WAV.
    let folder = scratch.appendingPathComponent("kit export")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var short = kickParams()
    short.length = 0.3
    let items = [KitExport.Item(index: 0, params: short, sampleRate: 44_100),
                 KitExport.Item(index: 2, params: snareParams(), sampleRate: 48_000),
                 KitExport.Item(index: 7, params: hatParams(), sampleRate: 44_100)]
    let format = OutputFormat.wav
    let quality = format.qualityOptions.first { $0.label.contains("24") } ?? format.defaultQuality
    let written = try KitExport.export(items, prefix: "TR-707 Transmute", format: format, quality: quality, to: folder)
    let names = written.map(\.lastPathComponent)
    check(names == ["TR-707 Transmute 1.wav", "TR-707 Transmute 3.wav", "TR-707 Transmute 8.wav"],
          "three pads, three files: " + names.joined(separator: ", "))
    var sound = true
    for (item, url) in zip(items, written) {
        let (samples, fileFormat) = try readBack(url)
        let frames = Int((item.params.renderLength * item.sampleRate).rounded())
        sound = sound && samples.count == frames && fileFormat.sampleRate == item.sampleRate && fileFormat.channelCount == 1
    }
    check(sound, "each reads back mono, at its pad's rate, as long as the drum")
} catch {
    check(false, "export kit: \(error)")
}

// MARK: - Max level

section("Max level")
do {
    check(LevelLimit.snapped(-1.3) == -1.5 && LevelLimit.snapped(-1.2) == -1 && LevelLimit.snapped(2) == 0
          && LevelLimit.snapped(-20) == -12 && LevelLimit.snapped(.nan) == LevelLimit.defaultDB,
          "the max level snaps to 0.5 dB steps inside -12...0 dBFS")

    // Every model, 6 dB too loud: lowered to the ceiling at both rates and
    // nothing but Level touched - the synth's gain is its last multiply.
    let rates = [MonoAudio.analysisRate, 44_100.0]
    var exact = true, onlyLevel = true, worst = 0.0
    for base in [kickParams(), snareParams(), hatParams(), modalParams(), clapParams()] {
        var loud = base
        loud.gainDB += 6
        guard let limited = LevelLimit.limited(loud, maxDB: -1.5, rates: rates) else { exact = false; continue }
        let peak = rates.map { LevelLimit.peakDB(limited, sampleRate: $0) }.max()!
        worst = max(worst, abs(peak + 1.5))
        exact = exact && peak <= -1.5 + 1e-4
        var back = limited
        back.gainDB = loud.gainDB
        onlyLevel = onlyLevel && back == loud
    }
    check(exact && worst < 0.001, String(format: "five models 6 dB too loud come down to -1.5 dBFS exactly (worst %.5f dB off)", worst))
    check(onlyLevel, "only Level changes")
    var quiet = kickParams()
    quiet.gainDB = -12
    check(LevelLimit.limited(quiet, maxDB: -1.5, rates: rates) == nil, "a drum under the ceiling is left alone - never raised")
}

// MARK: - Batch convert

section("Batch convert")
do {
    let input = scratch.appendingPathComponent("batch in")
    let output = scratch.appendingPathComponent("batch out")
    try? FileManager.default.removeItem(at: input)
    try? FileManager.default.removeItem(at: output)
    try FileManager.default.createDirectory(at: input.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let wav = OutputFormat.wav
    let depth24 = wav.qualityOptions.first { $0.label.contains("24") } ?? wav.defaultQuality
    var loudClap = clapParams()
    loudClap.gainDB += 6
    try Exporter.export(DrumSynth.renderAudio(loudClap, sampleRate: 44_100), format: wav, quality: depth24,
                        to: input.appendingPathComponent("hit 10.wav"))
    try Exporter.export(DrumSynth.renderAudio(kickParams(), sampleRate: 48_000), format: wav, quality: depth24,
                        to: input.appendingPathComponent("hit 2.wav"))
    try Exporter.export(DrumSynth.renderAudio(snareParams(), sampleRate: 48_000), format: wav, quality: depth24,
                        to: input.appendingPathComponent("sub/a snare.wav"))
    try Data("not audio".utf8).write(to: input.appendingPathComponent("notes.txt"))
    try Exporter.export(DrumSynth.renderAudio(kickParams(), sampleRate: 48_000), format: wav, quality: depth24,
                        to: input.appendingPathComponent(".hidden.wav"))

    let files = BatchConvert.audioFiles(in: [input, input.appendingPathComponent("hit 2.wav")])
    let names = files.map(\.lastPathComponent)
    check(names == ["a snare.wav", "hit 2.wav", "hit 10.wav"],
          "a folder brings its audio files, subfolders too, each once, by name (\"2\" before \"10\"), no text or hidden files: "
          + names.joined(separator: ", "))
    check(BatchConvert.fileName(prefix: "Clap", position: 0, fileExtension: "wav") == "Clap 1.wav"
          && BatchConvert.fileName(prefix: " ", position: 11, fileExtension: "aiff") == "Kit 12.aiff",
          "names are Export Kit's: \"Clap 1.wav\"; an empty prefix is \"Kit\"")

    // The loud clap, as a clap, held to -1.5 dBFS: a 44.1 kHz mono file at
    // the ceiling.
    let clapOut = output.appendingPathComponent("Clap 1.wav")
    let clap = try BatchConvert.convert(input.appendingPathComponent("hit 10.wav"), model: .clap, maxLevelDB: -1.5,
                                        format: wav, quality: depth24, to: clapOut)
    let (samples, fileFormat) = try readBack(clapOut)
    let filePeak = 20 * log10(Double(samples.map(abs).max() ?? 0))
    check(clap.params.model == .clap && fileFormat.sampleRate == 44_100 && fileFormat.channelCount == 1,
          "a clap chosen for the batch is fitted as a clap and written mono at its source's 44.1 kHz")
    check(clap.loweredDB > 0 && filePeak <= -1.5 + 0.01 && filePeak > -1.6,
          String(format: "held to the max level: lowered %.1f dB, file peak %.2f dBFS", clap.loweredDB, filePeak))

    // A kick, as a clap: the model chosen is the one used, whatever the
    // sample would suggest. Automatic takes the suggestion.
    let forced = try BatchConvert.convert(input.appendingPathComponent("hit 2.wav"), model: .clap, maxLevelDB: nil,
                                          format: wav, quality: depth24, to: output.appendingPathComponent("Clap 2.wav"))
    let (kickAudio, _) = try Decoder.decode(input.appendingPathComponent("hit 2.wav"))
    let suggested = try Analyzer.analyze(kickAudio, model: nil).suggested
    let auto = try BatchConvert.convert(input.appendingPathComponent("hit 2.wav"), model: nil, maxLevelDB: nil,
                                        format: wav, quality: depth24, to: output.appendingPathComponent("Auto 1.wav"))
    check(forced.params.model == .clap && auto.params.model == suggested && forced.loweredDB == 0,
          "Clap for all: a kick is fitted as a clap too; Automatic takes the suggestion (\(suggested.title)); no max level, no lowering")
} catch {
    check(false, "batch convert: \(error)")
}

// MARK: - Decoder

section("Decoder")

/// A stereo WAV of two given channels. In a function of its own: the
/// file is finished when the writer is released, at the end of a scope.
func writeStereo(_ left: [Float], _ right: [Float], rate: Double, to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
    buffer.frameLength = AVAudioFrameCount(left.count)
    buffer.floatChannelData![0].update(from: left, count: left.count)
    buffer.floatChannelData![1].update(from: right, count: right.count)
    try file.write(from: buffer)
}

do {
    let tone = (0..<44_100).map { Float(0.5 * sin(2 * Double.pi * 100 * Double($0) / 44_100)) }
    let silent = [Float](repeating: 0, count: tone.count)
    let both = scratch.appendingPathComponent("both.wav")
    let one = scratch.appendingPathComponent("one.wav")
    try writeStereo(tone, tone, rate: 44_100, to: both)
    try writeStereo(tone, silent, rate: 44_100, to: one)
    let (a, info) = try Decoder.decode(both)
    let (b, _) = try Decoder.decode(one)
    check(info.sampleRate == 44_100 && info.channels == 2, "source info: 44.1 kHz, 2 channels")
    check(a.sampleRate == 48_000 && abs(a.frameCount - 48_000) <= 2, "resampled to 48 kHz: \(a.frameCount) frames")
    check(abs(a.peak - 0.5) < 0.005, String(format: "identical channels keep their level (peak %.3f)", a.peak))
    check(abs(b.peak - 0.25) < 0.005, String(format: "one silent channel halves it - an average (peak %.3f)", b.peak))

    let long = scratch.appendingPathComponent("long.wav")
    let minutes = [Float](repeating: 0.1, count: 44_100 * 11)
    try writeStereo(minutes, minutes, rate: 44_100, to: long)
    do {
        _ = try Decoder.decode(long)
        check(false, "an 11 s file is refused")
    } catch DecodeError.tooLong {
        check(true, "an 11 s file is refused as too long for one hit")
    }

    let garbage = scratch.appendingPathComponent("garbage.wav")
    try Data("not audio at all".utf8).write(to: garbage)
    check((try? Decoder.decode(garbage)) == nil, "a file that is not audio is refused")
} catch {
    check(false, "decoder: \(error)")
}

// MARK: - Parameter files

section("Parameter files")
do {
    let url = scratch.appendingPathComponent("kick.\(DrumParams.fileExtension)")
    let p = kickParams()
    try p.write(to: url)
    check(try DrumParams.read(from: url) == p, "a .drumparams file reads back identical")

    let partial = Data(#"{"fundamental": 72, "ampDecay": 0.5}"#.utf8)
    let q = try JSONDecoder().decode(DrumParams.self, from: partial)
    var expected = DrumParams()
    expected.fundamental = 72; expected.ampDecay = 0.5
    check(q == expected, "missing keys keep their defaults")

    check(q.model == .kick, "a file from before the snare model opens as a kick")
    let snareURL = scratch.appendingPathComponent("snare.\(DrumParams.fileExtension)")
    try snareParams().write(to: snareURL)
    check(try DrumParams.read(from: snareURL) == snareParams(), "a snare's file reads back identical, model and all")
    let hatURL = scratch.appendingPathComponent("hat.\(DrumParams.fileExtension)")
    try hatParams().write(to: hatURL)
    check(try DrumParams.read(from: hatURL) == hatParams(), "a hi-hat's file reads back identical")

    let wild = Data(#"{"fundamental": 5, "noise": 9, "gainDB": 40}"#.utf8)
    let r = try JSONDecoder().decode(DrumParams.self, from: wild)
    check(r.fundamental == 20 && r.noise == 1 && r.gainDB == 6, "values outside the sliders' ranges are clamped")
} catch {
    check(false, "parameter files: \(error)")
}

// MARK: - Player

section("Player (render block driven by hand)")
do {
    let core = OneShotCore(sampleRate: 48_000)
    let original = MonoAudio((0..<4800).map { Float(sin(Double($0) * 0.05)) * 0.8 }, sampleRate: 48_000)
    let synth = MonoAudio((0..<9600).map { Float(sin(Double($0) * 0.01)) * 0.5 }, sampleRate: 48_000)
    let o = Unmanaged.passRetained(original), s = Unmanaged.passRetained(synth)
    core.original.store(UnsafeRawPointer(o.toOpaque()), ordering: .releasing)
    core.synth.store(UnsafeRawPointer(s.toOpaque()), ordering: .releasing)
    var block = [Float](repeating: 0, count: 512)

    core.pending.store(OneShotSource.original.rawValue, ordering: .releasing)
    block.withUnsafeMutableBufferPointer { core.render(into: $0.baseAddress!, count: 512) }
    check(block == Array(original.array[0..<512]), "a trigger plays the source from its first sample")

    var all = block
    core.pending.store(OneShotSource.synth.rawValue, ordering: .releasing)
    for _ in 0..<4 {
        block.withUnsafeMutableBufferPointer { core.render(into: $0.baseAddress!, count: 512) }
        all += block
    }
    // Neither test signal ever steps by more than 0.04 (0.8 × 0.05); a cut
    // would step by up to 0.8.
    let jump = zip(all.dropFirst(), all).map { abs($0 - $1) }.max()!
    check(jump <= 0.0401, String(format: "a retrigger fades the old hit out: largest step %.4f ≤ 0.04, the signals' own", jump))
    let fadeFrames = Int(0.003 * 48_000)
    check(Array(all[(512 + fadeFrames)..<(512 + fadeFrames + 100)]) == Array(synth.array[0..<100]),
          "and then starts the new one from its first sample, at full level, 3 ms later")

    for _ in 0..<40 { block.withUnsafeMutableBufferPointer { core.render(into: $0.baseAddress!, count: 512) } }
    check(core.playing.load(ordering: .acquiring) == -1 && block.allSatisfy { $0 == 0 }, "and stops at its end")
    o.release(); s.release()
}

// MARK: - Filter, slider mapping

section("Filter")
do {
    func level(_ hz: Double, _ type: FilterType, cutoff: Double, q: Double = 0.707) -> Double {
        var p = DrumParams()
        p.filterType = type; p.filterCutoff = cutoff; p.filterQ = q
        var x = (0..<48_000).map { sin(2 * Double.pi * hz * Double($0) / 48_000) }
        DrumSynth.applyFilter(p, to: &x, sampleRate: 48_000)
        let tail = x[24_000...].map(abs).max()!      // settled
        return 20 * log10(max(tail, 1e-12))
    }
    var off = kickParams()
    off.filterCutoff = 123
    check(DrumSynth.render(off, sampleRate: 48_000) == DrumSynth.render(kickParams(), sampleRate: 48_000),
          "filter off leaves the samples untouched, whatever its cutoff")
    let lp = (pass: level(50, .lowPass, cutoff: 200), stop: level(2000, .lowPass, cutoff: 200))
    check(abs(lp.pass) < 0.5 && lp.stop < -20, String(format: "low-pass 200 Hz: 50 Hz %.1f dB, 2 kHz %.1f dB", lp.pass, lp.stop))
    let hp = (pass: level(5000, .highPass, cutoff: 500), stop: level(50, .highPass, cutoff: 500))
    check(abs(hp.pass) < 0.5 && hp.stop < -20, String(format: "high-pass 500 Hz: 5 kHz %.1f dB, 50 Hz %.1f dB", hp.pass, hp.stop))
    let bp = (centre: level(1000, .bandPass, cutoff: 1000, q: 2), side: level(250, .bandPass, cutoff: 1000, q: 2))
    check(abs(bp.centre) < 0.5 && bp.side < -12, String(format: "band-pass 1 kHz: centre %.1f dB, 250 Hz %.1f dB", bp.centre, bp.side))
    let wide = level(1500, .bandPass, cutoff: 1000, q: 1), narrow = level(1500, .bandPass, cutoff: 1000, q: 8)
    check(narrow < wide - 6, String(format: "a higher Q narrows the band: 1.5 kHz at Q 1 %.1f dB, at Q 8 %.1f dB", wide, narrow))
    var res = DrumParams()
    res.filterType = .lowPass; res.filterCutoff = 1000; res.filterQ = 4
    var peakTone = (0..<48_000).map { sin(2 * Double.pi * 1000 * Double($0) / 48_000) }
    DrumSynth.applyFilter(res, to: &peakTone, sampleRate: 48_000)
    check(20 * log10(peakTone[24_000...].map(abs).max()!) > 6, "a resonant low-pass peaks at its cutoff")
}

section("Slider mapping")
do {
    var worst = 0.0
    for spec in ParamSpec.all {
        for position in [0.0, 0.25, 0.5, 0.75, 1] {
            worst = max(worst, abs(spec.position(of: spec.value(at: position)) - position))
        }
    }
    check(worst < 1e-9, "every slider maps position → value → position exactly (worst \(worst))")
}

// MARK: - Master envelope

section("Master envelope")
do {
    let sr = 48_000.0
    var p = kickParams()
    p.length = 1.2                                   // longer than the envelope
    p.filterType = .lowPass; p.filterCutoff = 3000   // the envelope comes after the filter
    let plain = DrumSynth.render(p, sampleRate: sr)
    let legacy = try JSONDecoder().decode(DrumParams.self, from: try JSONEncoder().encode(p))
    check(!legacy.envelopeOn && DrumSynth.render(legacy, sampleRate: sr) == plain,
          "off by default and in files from before it: the render is untouched, bit for bit")
    var partial = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
    for key in ["envelopeOn", "envHold", "envRelease", "envCurve"] { partial[key] = nil }
    let old = try JSONDecoder().decode(DrumParams.self, from: JSONSerialization.data(withJSONObject: partial))
    check(!old.envelopeOn && old.envHold == DrumParams().envHold, "a .drumparams without its keys opens with it off")

    p.envelopeOn = true; p.envHold = 0.1; p.envRelease = 0.2; p.envCurve = 1
    let shaped = DrumSynth.render(p, sampleRate: sr)
    let end = Int((0.3 * sr).rounded()), hold = Int((0.1 * sr).rounded())
    check(shaped.count == end, "the file ends where the envelope reaches 0 (\(shaped.count) frames, \(end) expected)")
    check(shaped.last == 0, "and its last sample is exactly 0")
    // Against the same drum over the same frames: the noise layers are
    // normalised over their rendered length, so a shorter file is not the
    // first part of a longer one to the last bit.
    var off = p
    off.envelopeOn = false
    let window = DrumSynth.render(off, sampleRate: sr, frames: end)
    check(Array(shaped[..<hold]) == Array(window[..<hold]), "up to Hold the drum is untouched")
    let mid = hold + (end - 1 - hold) / 2
    let x = Double(mid - hold) / Double(end - 1 - hold)
    check(abs(Double(shaped[mid]) - Double(window[mid]) * (1 - x)) < 1e-6, "Curve 1 is linear: half-way through Release, half the level")
    p.envCurve = 3
    let curved = DrumSynth.render(p, sampleRate: sr)
    check(abs(Double(curved[mid]) - Double(window[mid]) * pow(1 - x, 3)) < 1e-6, "Curve 3: (1 − x)³")

    var auto = kickParams()
    auto.autoLength = true
    auto.envelopeOn = true; auto.envHold = 0.05; auto.envRelease = 0.1
    check(abs(auto.renderLength - 0.15) < 1e-12, "auto length: the envelope's end when it comes before the tail")
    auto.envHold = 3; auto.envRelease = 1
    check(abs(auto.renderLength - (auto.tailSeconds + auto.fadeSeconds)) < 1e-12, "and the tail when that ends first")

    var manual = kickParams()
    manual.length = 0.2
    manual.envelopeOn = true; manual.envHold = 0.3; manual.envRelease = 0.5
    let cut = DrumSynth.render(manual, sampleRate: sr)
    var unshaped = manual
    unshaped.envelopeOn = false
    check(cut.count == Int(0.2 * sr) && cut == DrumSynth.render(unshaped, sampleRate: sr) && cut.last == 0,
          "a Length set by hand before the envelope's Hold ends it, with the usual fade")

    // Not fitted: the fit runs without it and hands it back unchanged.
    var start = kickParams()
    start.length = 0.8
    let analysis = try Analyzer.analyze(MonoAudio(DrumSynth.render(start, sampleRate: sr), sampleRate: sr))
    var from = analysis.initial
    let bare = try Fitter.fit(analysis, from: from)
    from.envelopeOn = true; from.envHold = 0.04; from.envRelease = 0.07; from.envCurve = 2
    let withEnvelope = try Fitter.fit(analysis, from: from)
    var back = withEnvelope.params
    check(back.envelopeOn && back.envHold == 0.04 && back.envRelease == 0.07 && back.envCurve == 2,
          "a fit gives the envelope back as it was")
    back.envelopeOn = false
    back.envHold = bare.params.envHold; back.envRelease = bare.params.envRelease; back.envCurve = bare.params.envCurve
    check(back == bare.params && withEnvelope.score.total == bare.score.total,
          "and fits the voice exactly as without it (match \(String(format: "%.2f", bare.score.total)) dB)")
} catch {
    check(false, "master envelope: \(error)")
}

// MARK: - Kit file and MIDI learn

section("Kit file and learn")
do {
    var kit = DrumKit()
    check(kit.pads.map(\.note) == DrumKit.defaultNotes.map { Optional($0) }, "a new kit has sixteen pads on notes 36-51 (C1-D#2, the MPD218's bank A)")
    kit.pads[2].params = kickParams()
    kit.pads[2].name = "Kick"
    kit.pads[2].pan = -40
    kit.pads[2].params?.envelopeOn = true
    kit.pads[2].params?.filterType = .lowPass
    // Dropping: pad 1 takes up to eight, by name as Finder sorts; every
    // other pad one.
    var random = Xorshift(seed: 11)
    let dropped = (1...20).map { ($0, random.next()) }.sorted { $0.1 < $1.1 }
        .map { URL(fileURLWithPath: "/tmp/Kit \($0.0).wav") }
    let multi = DrumKit.dropTargets(dropped, on: 0)
    check(multi.map(\.pad) == Array(0..<16) && multi.map(\.url.lastPathComponent) == (1...16).map { "Kit \($0).wav" },
          "twenty files on pad 1: Kit 1 … Kit 16 on pads 1-16 in name order (Kit 2 before Kit 10), Kit 17-20 left out")
    let three = Array(dropped.prefix(3))
    let single = DrumKit.dropTargets(three, on: 4)
    check(single.count == 1 && single[0].pad == 4 && single[0].url.lastPathComponent == "Kit 1.wav",
          "three files on pad 5: only the first by name (Kit 1), on pad 5")
    check(DrumKit.dropTargets(three, on: 0).map(\.pad) == [0, 1, 2], "three files on pad 1: pads 1-3, the rest untouched")

    kit.pads[5].model = .modal
    kit.pads[6].model = .clap
    let url = scratch.appendingPathComponent("test.\(DrumKit.fileExtension)")
    try? kit.write(to: url)
    check((try? DrumKit.read(from: url)) == kit, "a .drumkit reads back identical, a pad's chosen model with it")
    let empty = try? JSONDecoder().decode(DrumKit.self, from: Data("{}".utf8))
    check(empty == DrumKit() && empty?.pads.count == 16, "an empty file is an empty kit of sixteen pads")
    let short = try? JSONDecoder().decode(DrumKit.self, from: Data(#"{"pads":[{"name":"A","pan":500}]}"#.utf8))
    check(short?.pads.count == 16 && short?.pads[0].pan == 100,
          "a short file is filled up to sixteen pads, values clamped")
    // A kit from before 2026-09-26 holds four velocity slots per pad.
    let slotted = try? JSONDecoder().decode(DrumKit.self, from: Data(
        #"{"pads":[{"name":"A","pan":20,"mods":[{"source":"velocity","target":"noiseTone","amount":0.5},{"source":"velocity","amount":0}]}]}"#.utf8))
    check(slotted?.pads[0].name == "A" && slotted?.pads[0].pan == 20, "a kit with the old velocity slots still opens")
    // A kit saved with eight pads, as every one before 2026-09-26.
    var old = DrumKit()
    old.pads[3].params = kickParams()
    let eight = try JSONEncoder().encode(["pads": Array(old.pads.prefix(8))])
    let reopened = try JSONDecoder().decode(DrumKit.self, from: eight)
    check(reopened.pads.count == 16 && reopened.pads[3].params == kickParams()
          && reopened.pads[8...].allSatisfy { $0.params == nil } && reopened.pads[15].note == 51,
          "an eight-pad kit opens with its drums on 1-8 and pads 9-16 empty on notes 44-51")
    kit.learn(note: 38, for: 0)
    check(kit.pads[0].note == 38 && kit.pads[2].note == nil && kit.pads(for: 38) == [0],
          "learning a note takes it from the pad that had it")
    check(NoteName.string(36) == "C1" && NoteName.string(nil) == "–", "36 is C1")

    var map = MIDIMap()
    let cc21 = MIDIControlChange(channel: 1, controller: 21, value: 64)
    map.learn("noiseTone", from: cc21)
    map.learn(LearnTarget.pan, from: MIDIControlChange(channel: 1, controller: 22, value: 0))
    map.learn("envRelease", from: cc21)
    check(map.targets(for: cc21) == ["envRelease"] && map.controls["noiseTone"] == nil,
          "learning a CC takes it from the control that had it")
    let suite = UserDefaults(suiteName: "transmute.verify.learn")!
    suite.removePersistentDomain(forName: "transmute.verify.learn")
    map.save(suite)
    check(MIDIMap.load(suite) == map, "the learnt map is kept as JSON data")
    suite.removePersistentDomain(forName: "transmute.verify.learn")
    var stale = map
    stale.controls["amount1"] = CCAddress(channel: 1, controller: 30)
    stale.save(suite)
    check(MIDIMap.load(suite) == map, "a CC learnt to a velocity amount is forgotten on load")
    suite.removePersistentDomain(forName: "transmute.verify.learn")

    var parser = MIDIStreamParser()
    let notes = parser.feed([0x99, 36, 100, 37, 0, 0xF8, 38, 90, 0x89, 36, 0]).compactMap(\.noteOn)
    check(notes == [MIDINoteOn(channel: 10, note: 36, velocity: 100), MIDINoteOn(channel: 10, note: 38, velocity: 90)],
          "note-ons found across running status and a clock byte; velocity 0 and note-off are not hits")
}

// MARK: - Kit player

section("Kit player (render block driven by hand)")
do {
    let tone = MonoAudio((0..<4800).map { Float(sin(Double($0) * 0.05)) * 0.8 }, sampleRate: 48_000)
    let other = MonoAudio((0..<4800).map { Float(sin(Double($0) * 0.02)) * 0.5 }, sampleRate: 48_000)
    let centre = PadVoiceSet(audio: tone, pan: 0)
    let left = PadVoiceSet(audio: other, pan: -100)
    let core = KitCore(sampleRate: 48_000)
    let a = Unmanaged.passRetained(centre), b = Unmanaged.passRetained(left)
    core.pads[0].set.store(UnsafeRawPointer(a.toOpaque()), ordering: .releasing)
    core.pads[1].set.store(UnsafeRawPointer(b.toOpaque()), ordering: .releasing)
    var l = [Float](repeating: 0, count: 512), r = [Float](repeating: 0, count: 512)
    func block() { l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        core.render(left: lp.baseAddress!, right: rp.baseAddress!, count: 512) } } }

    core.pads[0].pending.store(true, ordering: .releasing)
    block()
    let g = Float(cos(Double.pi / 4))
    check(zip(l, tone.array.prefix(512)).allSatisfy { abs($0 - $1 * g) < 1e-6 } && l == r,
          "a hit plays its pad from the first sample, centred at −3 dB each side")
    core.pads[1].pending.store(true, ordering: .releasing)
    block()
    let expected = (512..<1024).map { tone.samples[$0] * g + other.samples[$0 - 512] }
    check(zip(l, expected).allSatisfy { abs($0 - $1) < 1e-6 } && zip(r, (512..<1024).map { tone.samples[$0] * g }).allSatisfy { abs($0 - $1) < 1e-6 },
          "two pads sound together; the one panned hard left is only on the left")
    var all = l
    core.pads[0].pending.store(true, ordering: .releasing)
    for _ in 0..<3 { block(); all += l }
    let bound = 0.8 * 0.05 * Double(g) + 0.5 * 0.02 + 0.01
    let jump = zip(all.dropFirst(), all).map { Double(abs($0 - $1)) }.max()!
    check(jump <= bound, String(format: "a retrigger fades its old voice instead of cutting it (largest step %.4f ≤ %.4f)", jump, bound))
    for _ in 0..<20 { block() }
    check(core.sounding.load(ordering: .acquiring) == 0 && l.allSatisfy { $0 == 0 }, "and all voices end")

    // The last pad plays too: the lights' bit mask and the channels reach 16.
    core.pads[15].set.store(UnsafeRawPointer(a.toOpaque()), ordering: .releasing)
    core.pads[15].pending.store(true, ordering: .releasing)
    block()
    check(core.sounding.load(ordering: .acquiring) & (1 << 15) != 0, "pad 16 plays and lights")
    for _ in 0..<20 { block() }
    a.release(); b.release()

    var kick = kickParams()
    kick.length = 0.3
    check(PadVoiceSet.make(params: kick, pan: 0).audio.array == DrumSynth.render(kick, sampleRate: MonoAudio.analysisRate),
          "a pad plays its drum as rendered for export")
}

// MARK: - MIDI end to end

section("MIDI: a virtual source plays notes and CCs into the input")
do {
    let defaults = UserDefaults(suiteName: "transmute.verify.midi")!
    defaults.removePersistentDomain(forName: "transmute.verify.midi")
    var client = MIDIClientRef()
    var source = MIDIEndpointRef()
    let name = "Transmute Verify Controller"
    if MIDIClientCreateWithBlock("TransmuteVerify" as CFString, &client, nil) == noErr,
       MIDISourceCreate(client, name as CFString, &source) == noErr {
        let input = MIDIControllerInput(defaults: defaults)
        var notes: [MIDINoteOn] = [], changes: [MIDIControlChange] = []
        input.onNoteOn = { notes.append($0) }
        input.onControlChange = { changes.append($0) }
        func settle(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        func send(_ bytes: [UInt8]) {
            var packet = MIDIPacket()
            packet.length = UInt16(bytes.count)
            withUnsafeMutableBytes(of: &packet.data) { $0.copyBytes(from: bytes) }
            var list = MIDIPacketList(numPackets: 1, packet: packet)
            MIDIReceived(source, &list)
        }
        settle { input.sources.contains { $0.name == name } }
        if let found = input.sources.first(where: { $0.name == name }) {
            input.setController(found, on: true)
            send([0x99, 36, 110, 0xB0, 21, 64, 0x89, 36, 0])
            settle { notes.count >= 1 && changes.count >= 1 }
            check(notes == [MIDINoteOn(channel: 10, note: 36, velocity: 110)]
                  && changes == [MIDIControlChange(channel: 1, controller: 21, value: 64)],
                  "a pad note and a knob arrive; the note-off does not (\(notes), \(changes))")
            var kit = DrumKit()
            check(kit.pads(for: notes.first?.note ?? 0) == [0], "and note 36 plays pad 1")
            kit.learn(note: 36, for: 5)
            check(kit.pads(for: 36) == [5], "until Learn gives it to pad 6")
        } else {
            check(false, "the virtual source is not listed: \(input.sources.map(\.name))")
        }
        MIDIEndpointDispose(source)
        MIDIClientDispose(client)
    } else {
        check(false, "could not create a virtual MIDI source")
    }
    defaults.removePersistentDomain(forName: "transmute.verify.midi")
}

print(failures == 0 ? "\nall checks passed" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
