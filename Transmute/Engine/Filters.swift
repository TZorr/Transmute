//
//  Filters.swift
//  Transmute
//
//  The few filters the synth and the analysis share: RBJ biquads, a
//  zero-phase way to run them, and the Hilbert envelope.
//
//  Zero-phase (forward, then backward) for the analysis, because the
//  analysis reads *times* off filtered signals - when a zero crossing
//  happens, when the envelope peaks - and an ordinary low-pass delays a
//  58 Hz wave by milliseconds, which the pitch fit would take for a slower
//  sweep. Run twice the filter's delay cancels, and its slope doubles.
//  The synth runs its filters forward only, like any synth: it is heard,
//  not measured.
//
//  The envelope is the magnitude of the analytic signal, not a smoothed
//  RMS: an RMS window short enough to follow a 5 ms click ripples at twice
//  the frequency of a 50 Hz body, and one long enough not to smears the
//  attack. The analytic magnitude of a sine is flat without any window.
//

import Foundation
import Accelerate

/// One RBJ biquad section (Audio EQ Cookbook), Direct Form I in Double.
nonisolated struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    enum Kind { case lowPass, highPass, bandPass }

    init(_ kind: Kind, frequency: Double, q: Double, sampleRate: Double) {
        let f = min(frequency, 0.49 * sampleRate)
        let w = 2 * Double.pi * f / sampleRate
        let alpha = sin(w) / (2 * q)
        let cosw = cos(w)
        let a0 = 1 + alpha
        switch kind {
        case .lowPass:
            b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = (1 - cosw) / 2
        case .highPass:
            b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = (1 + cosw) / 2
        case .bandPass:
            // Constant 0 dB peak gain.
            b0 = alpha; b1 = 0; b2 = -alpha
        }
        b0 /= a0; b1 /= a0; b2 /= a0
        a1 = -2 * cosw / a0
        a2 = (1 - alpha) / a0
    }

    @inline(__always) mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

    /// Filters `signal` in place, front to back.
    mutating func run(_ signal: inout [Double]) {
        for i in signal.indices { signal[i] = process(signal[i]) }
    }
}

nonisolated enum Filters {
    /// A cascade of sections run forward and then backward: no delay, and
    /// the magnitude response squared.
    static func zeroPhase(_ signal: [Double], _ sections: [Biquad]) -> [Double] {
        var y = signal
        for var section in sections { section.run(&y) }
        y.reverse()
        for var section in sections { section.reset(); section.run(&y) }
        y.reverse()
        return y
    }

    /// Fourth-order Butterworth low-pass as two sections (Q 0.541, 1.307);
    /// run zero-phase it is eighth-order.
    static func lowPass(_ signal: [Double], cutoff: Double, sampleRate: Double) -> [Double] {
        zeroPhase(signal, [Biquad(.lowPass, frequency: cutoff, q: 0.5412, sampleRate: sampleRate),
                           Biquad(.lowPass, frequency: cutoff, q: 1.3066, sampleRate: sampleRate)])
    }

    static func highPass(_ signal: [Double], cutoff: Double, sampleRate: Double) -> [Double] {
        zeroPhase(signal, [Biquad(.highPass, frequency: cutoff, q: 0.5412, sampleRate: sampleRate),
                           Biquad(.highPass, frequency: cutoff, q: 1.3066, sampleRate: sampleRate)])
    }

    /// |x + iH{x}|, the analytic magnitude. The signal is zero-padded to at
    /// least twice its length, so the FFT's wrap-around cannot fold the
    /// tail onto the attack.
    static func envelope(_ signal: [Double]) -> [Double] {
        let n = signal.count
        guard n > 1 else { return signal.map(abs) }
        var size = 2
        while size < 2 * n { size <<= 1 }
        let fft = RealFFT(size: size)
        let half = size / 2
        var input = [Float](repeating: 0, count: size)
        for i in 0..<n { input[i] = Float(signal[i]) }
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var quadrature = [Float](repeating: 0, count: size)
        input.withUnsafeBufferPointer { fft.forward($0.baseAddress!, real: &real, imag: &imag) }
        // H multiplies positive frequencies by −i: (re, im) → (im, −re).
        // DC and Nyquist (slot 0) have no quadrature part.
        for k in 1..<half {
            let re = real[k]
            real[k] = imag[k]
            imag[k] = -re
        }
        real[0] = 0; imag[0] = 0
        fft.inverse(real: &real, imag: &imag, output: &quadrature)
        return (0..<n).map { i in
            let q = Double(quadrature[i])
            return (signal[i] * signal[i] + q * q).squareRoot()
        }
    }
}
