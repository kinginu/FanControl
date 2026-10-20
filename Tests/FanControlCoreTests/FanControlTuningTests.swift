import Foundation
import Testing
@testable import FanControlCore

/// `TemperatureSmoother`, `FanTargetStabilizer` and the whole anti-hunting pipeline
/// (filter → aggregate → smoothing → curve → deadband / dwell / slew).
@Suite("Anti-hunting control loop", .tags(.control))
struct FanControlTuningTests {
    let fan = Fixtures.mac14_9Fans[0]
    let tuning = FanControlTuning.default

    private func at(_ seconds: Double) -> Date { TestClock.at(seconds) }

    // MARK: Tuning

    @Test func defaultsAndCodable() throws {
        #expect(tuning.riseTimeConstant == 3)
        #expect(tuning.fallTimeConstant == 25)
        #expect(tuning.deadbandRPM == 150)
        #expect(tuning.minimumDwell == 10)
        #expect(tuning.maximumStepRPM == 500)
        #expect(!tuning.dwellAppliesToIncreases)
        #expect(try JSONDecoder().decode(FanControlTuning.self, from: Data("{}".utf8)) == .default)
        let partial = try JSONDecoder().decode(FanControlTuning.self, from: Data(#"{"deadbandRPM":80}"#.utf8))
        #expect(partial.deadbandRPM == 80 && partial.fallTimeConstant == 25)
        let data = try JSONEncoder().encode(FanControlTuning.disabled)
        #expect(try JSONDecoder().decode(FanControlTuning.self, from: data) == .disabled)
    }

    // MARK: Smoother

    @Test func smootherAsymmetry() {
        var smoother = TemperatureSmoother()
        #expect(smoother.update(key: "k", temperature: 60, at: at(0), tuning: tuning) == 60)
        // Rise 60 → 70 for one time constant (3 s): 1 − e⁻¹ ≈ 63 % of the step.
        let up = smoother.update(key: "k", temperature: 70, at: at(3), tuning: tuning)!
        #expect(abs(up - (60 + 10 * (1 - exp(-1)))) < 1e-9)
        // Fall back to 60 for 3 s: only 1 − e^(−3/25) ≈ 11 % of the gap.
        let down = smoother.update(key: "k", temperature: 60, at: at(6), tuning: tuning)!
        #expect(abs(down - (up - (up - 60) * (1 - exp(-3.0 / 25)))) < 1e-9)
        #expect(down > 65)
        // Non-finite samples are ignored; clock going backwards restarts from the raw value.
        #expect(smoother.update(key: "k", temperature: .nan, at: at(8), tuning: tuning) == down)
        #expect(smoother.update(key: "k", temperature: 50, at: at(1), tuning: tuning) == 50)
        // Disabled tuning: raw values.
        var raw = TemperatureSmoother()
        raw.update(key: "k", temperature: 60, at: at(0), tuning: .disabled)
        #expect(raw.update(key: "k", temperature: 90, at: at(2), tuning: .disabled) == 90)
    }

    @Test func smoothReadingsOnlyForControlKeys() {
        var smoother = TemperatureSmoother()
        func batch(_ cpu: Double, _ gpu: Double) -> [SensorReading] {
            [SensorReading(id: "agg:cpu", name: "CPU", temperature: cpu, sensorType: .greatest),
             SensorReading(id: "agg:gpu", name: "GPU", temperature: gpu, sensorType: .greatest)]
        }
        _ = smoother.smooth(batch(60, 50), keys: ["agg:cpu"], at: at(0), tuning: tuning)
        let out = smoother.smooth(batch(80, 70), keys: ["agg:cpu"], at: at(2), tuning: tuning)
        #expect(out[0].temperature > 60 && out[0].temperature < 80)
        #expect(out[1].temperature == 70)  // not a control key: raw
        #expect(Set(smoother.values.keys) == ["agg:cpu"])
        #expect(smoother.value(for: "agg:cpu") == out[0].temperature)
        // A key that drops out of use forgets its state.
        _ = smoother.smooth(batch(80, 70), keys: [], at: at(4), tuning: tuning)
        #expect(smoother.values.isEmpty)
        let fresh = smoother.smooth(batch(40, 70), keys: ["agg:cpu"], at: at(6), tuning: tuning)
        #expect(fresh[0].temperature == 40)
    }

    // MARK: Stabilizer

    @Test func deadbandAndBounds() {
        var s = FanTargetStabilizer()
        #expect(s.stabilize([0: 4000], fans: [fan], at: at(0), tuning: tuning) == [0: 4000])  // first: as-is
        #expect(s.stabilize([0: 4100], fans: [fan], at: at(20), tuning: tuning) == [0: 4000])  // < 150
        #expect(s.stabilize([0: 3860], fans: [fan], at: at(40), tuning: tuning) == [0: 4000])
        #expect(s.stabilize([0: 4150], fans: [fan], at: at(60), tuning: tuning) == [0: 4150])  // = 150
        // The fan's maximum / minimum are always reached.
        var top = FanTargetStabilizer()
        _ = top.stabilize([0: 6700], fans: [fan], at: at(0), tuning: tuning)
        #expect(top.stabilize([0: 6800], fans: [fan], at: at(2), tuning: tuning) == [0: 6800])
        var bottom = FanTargetStabilizer()
        _ = bottom.stabilize([0: 2400], fans: [fan], at: at(0), tuning: tuning)
        // (A decrease must be requested for the dwell first.)
        #expect(bottom.stabilize([0: 2317], fans: [fan], at: at(20), tuning: tuning) == [0: 2400])
        #expect(bottom.stabilize([0: 2317], fans: [fan], at: at(30), tuning: tuning) == [0: 2317])
    }

    @Test func slewAndDwell() {
        var s = FanTargetStabilizer()
        _ = s.stabilize([0: 2317], fans: [fan], at: at(0), tuning: tuning)
        // Increases: +500 per poll, no dwell between consecutive increases.
        var outputs: [Int] = []
        for poll in 1...10 {
            outputs.append(s.stabilize([0: 6800], fans: [fan], at: at(Double(poll) * 2), tuning: tuning)[0]!!)
        }
        #expect(outputs == [2817, 3317, 3817, 4317, 4817, 5317, 5817, 6317, 6800, 6800])
        // A decrease is made only after it has been requested on every poll for the dwell
        // (requested from 24 s; the last change at 18 s is old enough by 28 s).
        #expect(s.stabilize([0: 3000], fans: [fan], at: at(24), tuning: tuning) == [0: 6800])
        #expect(s.stabilize([0: 3000], fans: [fan], at: at(28), tuning: tuning) == [0: 6800])
        #expect(s.stabilize([0: 3000], fans: [fan], at: at(34), tuning: tuning) == [0: 6300])
        // Next decrease: 10 s after the previous change.
        #expect(s.stabilize([0: 3000], fans: [fan], at: at(36), tuning: tuning) == [0: 6300])
        #expect(s.stabilize([0: 3000], fans: [fan], at: at(44), tuning: tuning) == [0: 5800])
        // Reversal (increase after a decrease) waits 10 s after the last change as well…
        #expect(s.stabilize([0: 6800], fans: [fan], at: at(46), tuning: tuning) == [0: 5800])
        #expect(s.stabilize([0: 6800], fans: [fan], at: at(54), tuning: tuning) == [0: 6300])
        // …then increases continue every poll.
        #expect(s.stabilize([0: 6800], fans: [fan], at: at(56), tuning: tuning) == [0: 6800])
        // A dip that ends before the dwell does not slow the fan; the timer restarts.
        #expect(s.stabilize([0: 4000], fans: [fan], at: at(70), tuning: tuning) == [0: 6800])
        #expect(s.stabilize([0: 6800], fans: [fan], at: at(78), tuning: tuning) == [0: 6800])
        #expect(s.stabilize([0: 4000], fans: [fan], at: at(80), tuning: tuning) == [0: 6800])
        #expect(s.stabilize([0: 4000], fans: [fan], at: at(88), tuning: tuning) == [0: 6800])
        #expect(s.stabilize([0: 4000], fans: [fan], at: at(90), tuning: tuning) == [0: 6300])
    }

    @Test func dwellAppliesToIncreasesOption() {
        var strict = FanControlTuning.default
        strict.dwellAppliesToIncreases = true
        var s = FanTargetStabilizer()
        _ = s.stabilize([0: 2317], fans: [fan], at: at(0), tuning: strict)
        #expect(s.stabilize([0: 6800], fans: [fan], at: at(2), tuning: strict) == [0: 2317])
        #expect(s.stabilize([0: 6800], fans: [fan], at: at(10), tuning: strict) == [0: 2817])
        #expect(s.stabilize([0: 6800], fans: [fan], at: at(12), tuning: strict) == [0: 2817])
        #expect(s.stabilize([0: 6800], fans: [fan], at: at(20), tuning: strict) == [0: 3317])
    }

    @Test func bypassAutomaticAndSeed() {
        var s = FanTargetStabilizer()
        _ = s.stabilize([0: 2317], fans: [fan], at: at(0), tuning: tuning)
        // Emergency override: straight to max.
        #expect(s.stabilize([0: 6800], fans: [fan], at: at(2), tuning: tuning, bypass: true) == [0: 6800])
        // Back to automatic (restore): passed through, state dropped.
        #expect(s.stabilize([0: nil], fans: [fan], at: at(4), tuning: tuning) == [0: nil])
        #expect(s.states.isEmpty)
        // First manual target after automatic: as-is.
        #expect(s.stabilize([0: 5000], fans: [fan], at: at(6), tuning: tuning) == [0: 5000])
        // A user apply seeds without limits; the dwell restarts.
        s.seed([0: 3000], fans: [fan], at: at(8))
        #expect(s.states[0]?.rpm == 3000)
        #expect(s.stabilize([0: 2500], fans: [fan], at: at(10), tuning: tuning) == [0: 3000])
        #expect(s.stabilize([0: 2500], fans: [fan], at: at(18), tuning: tuning) == [0: 3000])
        #expect(s.stabilize([0: 2500], fans: [fan], at: at(20), tuning: tuning) == [0: 2500])
        s.reset()
        #expect(s.states.isEmpty)
        // Disabled tuning passes everything through.
        var off = FanTargetStabilizer()
        _ = off.stabilize([0: 2317], fans: [fan], at: at(0), tuning: .disabled)
        #expect(off.stabilize([0: 6800], fans: [fan], at: at(1), tuning: .disabled) == [0: 6800])
        #expect(off.stabilize([0: 2400], fans: [fan], at: at(2), tuning: .disabled) == [0: 2400])
    }

    // MARK: Pipeline (hunting)

    /// Deterministic noise (LCG), ±1.
    private struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    /// Simulates `seconds` of 2 s polls: control temperature `temperature(t)` → smoother →
    /// Boost curve → stabilizer. Returns the written targets per poll.
    private func simulate(tuning: FanControlTuning, seconds: Int,
                          temperature: (Double) -> Double) -> [Int] {
        var smoother = TemperatureSmoother()
        var stabilizer = FanTargetStabilizer()
        let profile = FanProfile.boost()
        var outputs: [Int] = []
        for poll in 0..<(seconds / 2) {
            let t = Double(poll * 2)
            let sensors = [SensorReading(id: "agg:cpu", name: "CPU", temperature: temperature(t),
                                         sensorType: .greatest)]
            let control = smoother.smooth(sensors, keys: ["agg:cpu"], at: at(t), tuning: tuning)
            let plan = FanControlEngine.plan(profile: profile, fans: [fan], sensors: control, policy: .default,
                                             isEmergency: false)
            outputs.append(stabilizer.stabilize(plan, fans: [fan], at: at(t), tuning: tuning)[0]!!)
        }
        return outputs
    }

    private func reversals(_ values: [Int]) -> Int {
        var count = 0
        var last = 0
        for (a, b) in zip(values, values.dropFirst()) where a != b {
            let direction = b > a ? 1 : -1
            if last != 0 && direction != last { count += 1 }
            last = direction
        }
        return count
    }

    /// "Max of cores" flapping at a curve boundary (60 °C = 3500 RPM point): the hottest
    /// core alternates 58 / 66 °C from poll to poll, or follows a fast ±4 °C wave (8 s).
    /// After the initial rise the output never reverses and settles in at most two writes.
    @Test(arguments: [0, 1])
    func oscillatingInputGivesMonotoneBoundedOutput(pattern: Int) {
        let flapping: (Double) -> Double = { t in Int(t / 2) % 2 == 0 ? 58.0 : 66.0 }
        let wave: (Double) -> Double = { t in
            let phase: Double = 2 * Double.pi * t / 8 + 0.3
            return 62 + 4 * sin(phase)
        }
        let input = pattern == 0 ? flapping : wave
        let raw = simulate(tuning: .disabled, seconds: 600, temperature: input)
        let stabilized = simulate(tuning: .default, seconds: 600, temperature: input)

        // Without the anti-hunting stages the target hunts on almost every poll.
        #expect(reversals(raw) > 100)
        #expect((raw.max()! - raw.min()!) > 900)

        // With them: monotone after the first 30 s, bounded, few writes.
        let settled = Array(stabilized.dropFirst(15))
        #expect(reversals(settled) == 0, "\(settled)")
        #expect(reversals(stabilized) == 0, "\(stabilized)")
        #expect(zip(settled, settled.dropFirst()).filter { $0 != $1 }.count <= 2)
        #expect((settled.max()! - settled.min()!) <= 500)
        // Never more than the slew limit per poll.
        for (a, b) in zip(stabilized, stabilized.dropFirst()) { #expect(abs(b - a) <= 500) }
    }

    /// Heavy random noise (uniform ±4 °C every poll around 62 °C, ~170 RPM/°C there):
    /// random runs look like small load changes, so the output may move, but rarely
    /// (13 reversals in 9.5 min with this seed, vs. ~1 per poll raw), in ≥ 150 RPM steps,
    /// within a band.
    @Test func noisyInputIsBounded() {
        var noise = Noise(state: 42)
        var samples: [Double] = []
        for _ in 0..<300 { samples.append(62 + 4 * noise.next()) }
        let input: (Double) -> Double = { samples[Int($0) / 2] }
        let raw = simulate(tuning: .disabled, seconds: 600, temperature: input)
        let stabilized = simulate(tuning: .default, seconds: 600, temperature: input)
        #expect(reversals(raw) > 100)
        let settled = Array(stabilized.dropFirst(15))
        #expect(reversals(settled) <= 15, "\(settled)")
        #expect(zip(settled, settled.dropFirst()).filter { $0 != $1 }.count <= 20)
        #expect((settled.max()! - settled.min()!) <= 600)
        for (a, b) in zip(settled, settled.dropFirst()) where a != b { #expect(abs(b - a) >= 150) }
    }

    /// Slow sinusoidal load (period 40 s, ±3 °C) plus noise around 70 °C: far fewer
    /// direction changes than the raw curve, bounded band.
    @Test func sinusoidalLoadDoesNotHunt() {
        var noise = Noise(state: 7)
        var samples: [Double] = []
        for poll in 0..<300 {
            let t = Double(poll * 2)
            samples.append(70 + 3 * sin(2 * .pi * t / 40) + 1.5 * noise.next())
        }
        let input: (Double) -> Double = { samples[Int($0) / 2] }
        let raw = simulate(tuning: .disabled, seconds: 600, temperature: input)
        let stabilized = simulate(tuning: .default, seconds: 600, temperature: input)
        #expect(reversals(raw) > 60)
        let settled = Array(stabilized.dropFirst(30))
        #expect(reversals(settled) <= reversals(raw) / 5, "\(settled)")
        #expect((settled.max()! - settled.min()!) <= 700)
    }

    /// A real step in load is still followed: idle 55 °C → 80 °C sustained → back to 55 °C.
    @Test func stepLoadIsFollowed() {
        let out = simulate(tuning: .default, seconds: 400) { t in (60...200).contains(t) ? 80 : 55 }
        let curve = FanCurve.boost
        #expect(out[20] == curve.rpm(at: 55, for: fan))
        // Up: full plan within ~20 s of the step (500 RPM per poll, no dwell on increases).
        #expect(out[30 + 10] == curve.rpm(at: 80, for: fan) || abs(out[40] - 6400) <= 150)
        // Down: slowly (fall smoothing + dwell), but reaches the idle value before the end.
        #expect(out[102] > 5000)
        #expect(out.last! == curve.rpm(at: 55, for: fan) || abs(out.last! - curve.rpm(at: 55, for: fan)) < 150)
        // Monotone up, then monotone down.
        #expect(reversals(out) == 1)
    }
}
