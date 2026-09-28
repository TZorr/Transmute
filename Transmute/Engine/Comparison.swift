//
//  Comparison.swift
//  Transmute
//
//  How far a render is from the original, as one number in dB - what the
//  Fitter minimises and what the window shows as "Match".
//
//  Three parts:
//  - Spectral: both signals cut into frames at four sizes (64, 256, 1024
//    and 4096 samples, half-overlapping, so 1.3, 5, 21 and 85 ms at 48 kHz),
//    each frame's power summed into sixth-octave bands, and the band levels
//    compared in dB. Several sizes because no single one sees a drum: the
//    long frames see the pitch the body settles on, the middle ones the
//    sweep, and the shortest the click - which only covers two of the 5 ms
//    frames, too few for the fit to tell a 1 kHz click from a 3 kHz one
//    (measured: 0.27 against 0.23 dB). The 64-sample frames only cover the
//    first 50 ms, where the click is; after that they would add thousands
//    of frames that see nothing the 256-sample ones do not.
//    Bands, not FFT bins, because the click and the noise are noise: two
//    noise signals of the same colour differ bin by bin by many dB, but
//    their band sums agree, so a bin comparison would punish the right
//    noise level almost as much as a wrong one. And each size only keeps
//    the bands it resolves, from two bins up: in a 5 ms frame a 45 Hz body
//    is not a frequency but a slope, and its level there depends on where
//    in the cycle the frame falls - on the phase, which the fit does not
//    search (see Fitter).
//  - Envelope: the analytic magnitude, averaged over 2 ms, in dB. It says
//    the same thing as the spectrum in a different way, and is what keeps
//    the decay honest where the spectrum is dominated by one strong band.
//    Not an RMS: over 2 ms the RMS of a 45 Hz wave follows |sin|, so it
//    too depended on the phase, and the fit bent the pitch sweep to line
//    those ripples up (measured on an 808-style kick: 2.9 dB of envelope
//    error with decay, shape, level and drive all exactly right).
//  - Pitch: the model's pitch at every measured period, in semitones from
//    the measurement (see Analyzer.pitchTrack). The spectrum sees the
//    sweep only coarsely, in 5 ms frames; the periods see every cycle.
//
//  The five parts - four resolutions and the envelope - are computed at
//  once (2026-09-26), each on its own core, and added in the same order as
//  before, so a score is what it was to the bit. Safe because a part only
//  reads the targets and its own FFT setup, which vDSP allows from several
//  threads; every buffer is the call's own.
//
//  Every cell counts by its amplitude: the loud attack and body far more
//  than the many quiet cells of the tail (see distance, and why).
//
//  Levels below the recording's own floor are raised to it, in both
//  signals, before they are compared. A clean synth should not be pushed
//  into reproducing a record's hiss, and must not be rewarded for filling
//  it with noise of its own either: at the floor, both read the same.
//

import Foundation
import Accelerate

nonisolated struct MatchScore: Sendable, Equatable {
    var spectralDB: Double
    var envelopeDB: Double
    var pitchSemitones: Double

    /// What the fit minimises. A semitone of pitch error weighs like a dB.
    var total: Double { spectralDB + envelopeDB + pitchSemitones }
}

nonisolated final class Comparison: @unchecked Sendable {
    let sampleRate: Double
    let frameCount: Int
    let pitchTrack: [PitchPoint]

    private struct Resolution {
        let size: Int
        let hop: Int
        let fft: RealFFT
        let window: [Float]
        let bands: [Range<Int>]
        /// Frames from the onset on; nil for all of them.
        let frameLimit: Int?
        var target: [Float] = []
        var floors: [Float] = []
    }

    private var resolutions: [Resolution] = []
    private let envelopeHop: Int
    private let envelopeFFT: RealFFT
    private var targetEnvelope: [Float] = []
    private var envelopeFloor: Float = -200

    init(target: MonoAudio, pitchTrack: [PitchPoint]) {
        sampleRate = target.sampleRate
        frameCount = target.frameCount
        self.pitchTrack = pitchTrack
        envelopeHop = max(Int(0.002 * sampleRate), 1)
        var size = 2
        while size < 2 * frameCount { size <<= 1 }
        envelopeFFT = RealFFT(size: size)
        let samples = target.array
        for size in [64, 256, 1024, 4096] {
            let limit = size == 64 ? Int(0.05 * sampleRate) / (size / 2) + 1 : nil
            var resolution = Resolution(size: size, hop: size / 2, fft: RealFFT(size: size),
                                        window: Self.hann(size), bands: Self.bands(size: size, sampleRate: sampleRate),
                                        frameLimit: limit)
            resolution.target = spectrogram(samples, resolution)
            resolution.floors = Self.floors(resolution.target, bands: resolution.bands.count)
            resolutions.append(resolution)
        }
        targetEnvelope = envelope(samples)
        envelopeFloor = Self.floors(targetEnvelope, bands: 1)[0]
    }

    func score(_ candidate: [Float]) -> MatchScore {
        let count = resolutions.count
        let parts = Fitter.parallel(count + 1) { i -> Double in
            if i == count {
                return Self.distance(self.envelope(candidate), self.targetEnvelope, floors: [self.envelopeFloor], bands: 1)
            }
            let r = self.resolutions[i]
            return Self.distance(self.spectrogram(candidate, r), r.target, floors: r.floors, bands: r.bands.count)
        }
        var spectral = 0.0
        for i in 0..<count { spectral += parts[i] }
        spectral /= Double(count)
        return MatchScore(spectralDB: spectral, envelopeDB: parts[count], pitchSemitones: 0)
    }

    func score(_ params: DrumParams) -> MatchScore {
        var result = score(DrumSynth.render(params, sampleRate: sampleRate, frames: frameCount))
        result.pitchSemitones = pitchError(params)
        return result
    }

    /// Weighted mean distance of the model's sweep from the measured
    /// periods, in semitones. A period is an average over its own length,
    /// and so is the model here: the phase advance across the period.
    func pitchError(_ p: DrumParams) -> Double {
        guard !pitchTrack.isEmpty else { return 0 }
        var sum = 0.0, weights = 0.0
        for point in pitchTrack {
            let model = p.pitch(at: point.time)
            sum += point.weight * abs(12 * log2(max(model, 1) / point.hz))
            weights += point.weight
        }
        return weights > 0 ? sum / weights : 0
    }

    // MARK: - Pieces

    /// Frame × band levels in dB, frames centred from t = 0 to the end.
    private func spectrogram(_ x: [Float], _ r: Resolution) -> [Float] {
        let half = r.size / 2
        let frames = min(frameCount / r.hop + 1, r.frameLimit ?? .max)
        let bandCount = r.bands.count
        var out = [Float](repeating: 0, count: frames * bandCount)
        var frame = [Float](repeating: 0, count: r.size)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        x.withUnsafeBufferPointer { signal in
            for f in 0..<frames {
                // Centred on f·hop: the first frame reaches half a frame
                // before the onset, into zeros.
                let start = f * r.hop - half
                for i in 0..<r.size {
                    let j = start + i
                    frame[i] = j >= 0 && j < x.count ? signal[j] * r.window[i] : 0
                }
                frame.withUnsafeBufferPointer { r.fft.forward($0.baseAddress!, real: &real, imag: &imag) }
                real.withUnsafeMutableBufferPointer { re in
                    imag.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                    }
                }
                power[0] = 0     // slot 0 is DC and Nyquist packed; neither is a band
                for (b, band) in r.bands.enumerated() {
                    var sum: Float = 0
                    power.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + band.lowerBound, 1, &sum, vDSP_Length(band.count)) }
                    out[f * bandCount + b] = 10 * log10(sum + 1e-20)
                }
            }
        }
        return out
    }

    /// Mean analytic power in dB per 2 ms frame.
    private func envelope(_ x: [Float]) -> [Float] {
        let n = min(x.count, frameCount)
        var input = [Float](repeating: 0, count: envelopeFFT.size)
        for i in 0..<n { input[i] = x[i] }
        let half = envelopeFFT.half
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var quadrature = [Float](repeating: 0, count: envelopeFFT.size)
        input.withUnsafeBufferPointer { envelopeFFT.forward($0.baseAddress!, real: &real, imag: &imag) }
        // −i on the positive frequencies (see Filters.envelope).
        swap(&real, &imag)
        var minusOne: Float = -1
        vDSP_vsmul(imag, 1, &minusOne, &imag, 1, vDSP_Length(half))
        real[0] = 0; imag[0] = 0
        envelopeFFT.inverse(real: &real, imag: &imag, output: &quadrature)
        var power = [Float](repeating: 0, count: n)
        vDSP_vmul(input, 1, input, 1, &power, 1, vDSP_Length(n))
        vDSP_vma(quadrature, 1, quadrature, 1, power, 1, &power, 1, vDSP_Length(n))

        let frames = max(frameCount / envelopeHop, 1)
        var out = [Float](repeating: 0, count: frames)
        power.withUnsafeBufferPointer { values in
            for f in 0..<frames {
                let count = min(envelopeHop, n - f * envelopeHop)
                var mean: Float = 0
                if count > 0 { vDSP_meanv(values.baseAddress! + f * envelopeHop, 1, &mean, vDSP_Length(count)) }
                out[f] = 10 * log10(mean + 1e-20)
            }
        }
        return out
    }

    /// Mean |a − b| in dB, both raised to the band's floor first, each cell
    /// weighted by the amplitude of the louder of the two relative to the
    /// loudest cell: 1 at the peak, 0.1 at −20 dB, 0.01 at −40.
    ///
    /// A plain mean counts cells, and a drum has far more quiet cells than
    /// loud ones - on three recorded kicks about fifteen times more 40-90 dB
    /// down than within 20 dB of the peak. The fit then gave away what is
    /// heard to match what is not: on the two acoustic kicks it came out 5.5
    /// and 6.1 dB off in peak level and started the body 4 ms early, and a
    /// grid over start and level barely moved the plain mean (11-14 dB
    /// everywhere). Judged by measures the fit does not see - peak level,
    /// and the envelope over 5-60 ms - amplitude weighting brought those two
    /// kicks to within 2.2 / 1.3 dB of peak and 0.9 / 1.0 dB of envelope,
    /// found the 4 ms start, and left the synthetic drums where they were.
    /// Two gentler weightings (dB above the floor, and the square root of
    /// amplitude) were tried alongside: the first put the synthetic tom's
    /// level 0.6 dB off, the second landed between the two.
    ///
    /// By the louder of the two, not the original alone, so the synth is
    /// still charged for anything it adds where the original is quiet.
    private static func distance(_ a: [Float], _ b: [Float], floors: [Float], bands: Int) -> Double {
        let count = min(a.count, b.count)
        let loudest = Double(max(a.max() ?? 0, b.max() ?? 0))
        var sum = 0.0
        var weights = 0.0
        for i in 0..<count {
            let floor = floors[i % bands]
            let x = max(a[i], floor), y = max(b[i], floor)
            if x > floor || y > floor {
                let weight = pow(10, (Double(max(x, y)) - loudest) / 20)
                sum += weight * Double(abs(x - y))
                weights += weight
            }
        }
        return weights > 0 ? sum / weights : 0
    }

    /// Per band: 3 dB over the quietest tenth of the target's frames, but
    /// never more than 80 dB under the loudest cell - a clean target's
    /// quietest frames are −200 dB of rounding.
    private static func floors(_ levels: [Float], bands: Int) -> [Float] {
        let loudest = levels.max() ?? 0
        return (0..<bands).map { b in
            let column = stride(from: b, to: levels.count, by: bands).map { levels[$0] }.sorted()
            let quiet = column.isEmpty ? loudest : column[column.count / 10]
            return max(quiet + 3, loudest - 80)
        }
    }

    /// Sixth-octave bands from 20 Hz (or two bins, whichever is higher) to
    /// Nyquist, as FFT bin ranges; bands narrower than a bin are merged
    /// into the next.
    private static func bands(size: Int, sampleRate: Double) -> [Range<Int>] {
        let binHz = sampleRate / Double(size)
        let nyquistBin = size / 2
        var ranges: [Range<Int>] = []
        var edge = max(20.0, 2 * binHz)
        var low = max(Int((edge / binHz).rounded(.up)), 2)
        while low < nyquistBin {
            edge *= pow(2, 1.0 / 6)
            let high = min(Int((edge / binHz).rounded(.up)), nyquistBin)
            if high > low {
                ranges.append(low..<high)
                low = high
            }
        }
        return ranges
    }

    private static func hann(_ size: Int) -> [Float] {
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        return window
    }
}
