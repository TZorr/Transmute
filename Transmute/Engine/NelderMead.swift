//
//  NelderMead.swift
//  Transmute
//
//  The downhill simplex method, with the dimension-dependent coefficients
//  of Gao and Han (2012), which keep it from stalling beyond a handful of
//  dimensions the way the classic 1 / 2 / ½ / ½ set does.
//
//  Why this and not a gradient method: the function it minimises renders
//  a drum and compares spectra, which has no gradient to ask for, and a
//  numerical one would cost two renders per parameter per step and be
//  thrown off by the band edges. Nelder–Mead asks only for values. It is
//  also small enough to read in one sitting, which a borrowed optimiser
//  would not be.
//

import Foundation

nonisolated enum NelderMead {
    struct Result {
        var point: [Double]
        var value: Double
        var evaluations: Int
    }

    /// Minimises `f` from `start`, with an initial simplex one `steps[i]`
    /// along each axis. Stops after `maxEvaluations`, when the simplex's
    /// values agree within `tolerance`, or when `shouldStop` says so.
    static func minimize(_ f: ([Double]) -> Double, start: [Double], steps: [Double],
                         maxEvaluations: Int, tolerance: Double = 1e-4,
                         shouldStop: () -> Bool = { false }) -> Result {
        let n = start.count
        let dimension = Double(n)
        let alpha = 1.0
        let beta = 1 + 2 / dimension
        let gamma = 0.75 - 1 / (2 * dimension)
        let delta = 1 - 1 / dimension

        var evaluations = 0
        func value(_ x: [Double]) -> Double {
            evaluations += 1
            let v = f(x)
            return v.isFinite ? v : .greatestFiniteMagnitude
        }

        var simplex = [start]
        for i in 0..<n {
            var vertex = start
            vertex[i] += steps[i]
            simplex.append(vertex)
        }
        var values = simplex.map(value)

        while evaluations < maxEvaluations && !shouldStop() {
            let order = values.indices.sorted { values[$0] < values[$1] }
            simplex = order.map { simplex[$0] }
            values = order.map { values[$0] }
            if values[n] - values[0] < tolerance { break }

            var centroid = [Double](repeating: 0, count: n)
            for vertex in simplex.dropLast() {
                for i in 0..<n { centroid[i] += vertex[i] / dimension }
            }
            func along(_ t: Double) -> [Double] {
                (0..<n).map { centroid[$0] + t * (simplex[n][$0] - centroid[$0]) }
            }

            let reflected = along(-alpha)
            let r = value(reflected)
            if r < values[0] {
                let expanded = along(-alpha * beta)
                let e = value(expanded)
                if e < r { simplex[n] = expanded; values[n] = e } else { simplex[n] = reflected; values[n] = r }
            } else if r < values[n - 1] {
                simplex[n] = reflected; values[n] = r
            } else {
                let outside = r < values[n]
                let contracted = along(outside ? -alpha * gamma : gamma)
                let c = value(contracted)
                if c < (outside ? r : values[n]) {
                    simplex[n] = contracted; values[n] = c
                } else {
                    // Shrink everything towards the best vertex.
                    for j in 1...n {
                        simplex[j] = (0..<n).map { simplex[0][$0] + delta * (simplex[j][$0] - simplex[0][$0]) }
                        values[j] = value(simplex[j])
                    }
                }
            }
        }
        let best = values.indices.min { values[$0] < values[$1] } ?? 0
        return Result(point: simplex[best], value: values[best], evaluations: evaluations)
    }
}
