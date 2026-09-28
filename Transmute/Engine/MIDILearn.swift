//
//  MIDILearn.swift
//  Transmute
//
//  Which Control Change moves which control: any slider, or Pan. Pad notes
//  live in the kit (DrumKit.learn); this is the controller side, kept per
//  Mac - a controller belongs to the desk
//  it sits on, not to a kit (Ultramix's rule for its lane knobs, whose
//  learn logic this follows).
//
//  A CC moves its control on the selected pad, the way the edit knobs of a
//  hardware drum machine do: select a pad, turn, select the next. The CC's
//  0…127 is the slider's position (ParamSpec.position), so the knob and the
//  slider agree at every point, log sliders included.
//
//  Learning takes the CC away from anything else that had it.
//

import Foundation

/// A Control Change address: channel 1…16 and controller 0…127.
nonisolated struct CCAddress: Codable, Hashable, Sendable {
    var channel: Int
    var controller: Int

    init(channel: Int, controller: Int) {
        self.channel = channel
        self.controller = controller
    }

    init(_ change: MIDIControlChange) {
        self.init(channel: change.channel, controller: change.controller)
    }

    /// "CC 21 · Ch 1".
    var label: String { "CC \(controller) · Ch \(channel)" }
}

nonisolated enum LearnTarget {
    static let pan = "pan"

    /// Something a CC can still move: Pan or a parameter. The velocity
    /// amounts ("amount0"…"amount3") went with the slots, 2026-09-26.
    static func isKnown(_ target: String) -> Bool {
        target == pan || ParamSpec.find(target) != nil
    }
}

nonisolated struct MIDIMap: Codable, Equatable, Sendable {
    /// UserDefaults key. Stored as JSON **Data** - a String written in its
    /// place reads back as nothing and the map silently empties.
    static let storageKey = "midiLearn"

    /// Target (a ParamSpec id or "pan") → address.
    var controls: [String: CCAddress] = [:]

    mutating func learn(_ target: String, from change: MIDIControlChange) {
        let address = CCAddress(change)
        for (other, bound) in controls where other != target && bound == address {
            controls[other] = nil
        }
        controls[target] = address
    }

    mutating func forget(_ target: String) {
        controls[target] = nil
    }

    /// The targets this Control Change moves - one, after Learn.
    func targets(for change: MIDIControlChange) -> [String] {
        let address = CCAddress(change)
        return controls.filter { $0.value == address }.map(\.key).sorted()
    }

    static func load(_ defaults: UserDefaults = .standard) -> MIDIMap {
        guard let data = defaults.data(forKey: storageKey),
              var map = try? JSONDecoder().decode(MIDIMap.self, from: data) else { return MIDIMap() }
        // Learnt to a control that is gone: forgotten, not listed.
        map.controls = map.controls.filter { LearnTarget.isKnown($0.key) }
        return map
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
