import Foundation
import Testing
@testable import FanControlCore

@Suite("Fan discovery", .tags(.smc))
struct FanDiscoveryTests {
    /// Intel-era layout (unsupported since 2026-10-20): fpe2 fan keys still decode
    /// generically, but `FS! ` is no longer read, so no fan reports manual mode.
    @Test func legacyFixedPointFansIgnoreForceBits() throws {
        let reader = Fixtures.intel()
        let fans = try FanDiscovery.discoverFans(using: reader)
        #expect(fans == [
            FanDevice(id: 0, name: "Left Side", minRPM: 1200, maxRPM: 6000),
            FanDevice(id: 1, name: "Right Side", minRPM: 1300, maxRPM: 5500),
        ])
        #expect(FanDiscovery.readCurrentRPMs(fans: fans, using: reader) == [0: 1210, 1: 2500])
        #expect(FanDiscovery.readTargetRPMs(fans: fans, using: reader) == [0: 1200, 1: 2500])
        // FS! = 0x0002 (fan 1 forced on Intel) is ignored: no F<n>Md -> automatic.
        #expect(FanDiscovery.fanControlModes(fans: fans, using: reader) == [0: .automatic, 1: .automatic])
    }

    @Test func appleSiliconFans() throws {
        let reader = Fixtures.appleSilicon()
        let fans = try FanDiscovery.discoverFans(using: reader)
        #expect(fans == [
            FanDevice(id: 0, name: "Fan 1", minRPM: 1200, maxRPM: 5779),
            FanDevice(id: 1, name: "Fan 2", minRPM: 1200, maxRPM: 6241),
        ])
        #expect(FanDiscovery.readCurrentRPMs(fans: fans, using: reader) == [0: 2400, 1: 1200])
        // F1Tg is absent -> omitted.
        #expect(FanDiscovery.readTargetRPMs(fans: fans, using: reader) == [0: 2400])
        #expect(FanDiscovery.fanControlModes(fans: fans, using: reader) == [0: .constant(rpm: 2400), 1: .automatic])
    }

    @Test func skipsFansWithUnreadableLimits() throws {
        let reader = Fixtures.intel()
        reader.failingReads.insert(.fanMax(1))
        let fans = try FanDiscovery.discoverFans(using: reader)
        #expect(fans.map(\.id) == [0])
    }

    @Test func missingFanCountThrows() {
        let reader = MockSMCReader([])
        #expect(throws: FanControlError.keyNotFound("FNum")) {
            try FanDiscovery.discoverFans(using: reader)
        }
    }

    @Test func readerHelpers() throws {
        let reader = Fixtures.intel()
        #expect(reader.exists("TC0P"))
        #expect(!reader.exists("XXXX"))
        #expect(try reader.readNumber("TC0P") == 55.5)
        #expect(try reader.readValue("TZZZ") == .string("abcd"))
        #expect(throws: FanControlError.unsupportedDataType("ch8*")) {
            try reader.readNumber("TZZZ")
        }
        // Attributes as reported on Mac14,9 / macOS 26: F0Tg 0xd4, F0Md 0xd0, F0Mn 0x84, FNum 0x80.
        #expect(SMCKeyInfo(dataSize: 4, dataType: .flt, attributes: 0xD4).isWritable)
        #expect(SMCKeyInfo(dataSize: 1, dataType: .ui8, attributes: 0xD0).isWritable)
        #expect(!SMCKeyInfo(dataSize: 4, dataType: .flt, attributes: 0x84).isWritable)
        #expect(!SMCKeyInfo(dataSize: 1, dataType: .ui8, attributes: 0x80).isWritable)
        #expect(SMCKeyInfo(dataSize: 1, dataType: .ui8, attributes: 0x80).isReadable)
        #expect(!SMCKeyInfo(dataSize: 1, dataType: .flag, attributes: 0x50).isReadable)
    }
}

@Suite("Sensor catalog", .tags(.sensors, .smc))
struct SensorCatalogTests {
    @Test func displayNames() {
        // Intel-only names were removed (Intel dropped 2026-10-20): generic fallback.
        for key in ["TC0P", "TC0D", "TG0P", "TG0D", "TA0P", "TPCD"] {
            #expect(SensorCatalog.displayName(for: key) == "Sensor \(key)")
            #expect(SensorCatalog.knownNames[key] == nil)
        }
        #expect(SensorCatalog.displayName(for: "Tp09") == "CPU Performance Core 09")
        #expect(SensorCatalog.displayName(for: "Te05") == "CPU Efficiency Core 05")
        #expect(SensorCatalog.displayName(for: "Tg0f") == "GPU 0f")
        #expect(SensorCatalog.displayName(for: "TaLP") == "Airflow Left")
        #expect(SensorCatalog.displayName(for: "TaRF") == "Airflow Right")
        #expect(SensorCatalog.displayName(for: "TaLT") == "Airflow Left T")
        #expect(SensorCatalog.displayName(for: "TB0T") == "Battery")
        #expect(SensorCatalog.displayName(for: "TB1T") == "Battery 1")
        #expect(SensorCatalog.displayName(for: "TB2T") == "Battery 2")
        #expect(SensorCatalog.displayName(for: "TH0x") == "NAND (SSD)")
        #expect(SensorCatalog.displayName(for: "TH0a") == "Storage 0a")
        #expect(SensorCatalog.displayName(for: "Ts0P") == "Palm Rest")
        #expect(SensorCatalog.displayName(for: "Ts1P") == "Palm Rest 2")
        #expect(SensorCatalog.displayName(for: "TW0P") == "Wireless")
        #expect(SensorCatalog.displayName(for: "Tm0P") == "Sensor Tm0P")
    }

    @Test func unknownAppleSiliconKeysStayGeneric() {
        // No community backing: keep "Sensor <key>" (TG* is battery-area, not GPU, on Mac14,9).
        for key in ["TG0B", "TCMz", "TCMb", "TCDX", "TVM0", "TVm0", "TPD0", "TRD0", "Th00", "TD00",
                    "Tf04", "Ts0C", "Tz11", "Ta0C", "TS0P"] {
            #expect(SensorCatalog.displayName(for: key) == "Sensor \(key)")
        }
    }

    /// Every temperature key found on Mac14,9 (M2 Pro) / macOS 26
    /// (docs/verification/Mac14,9-macOS26-probe.txt).
    static let mac14_9Keys: [String] = """
        TAOL TB0T TB1T TB2T TCDX TCHP TCMb TCMz TD00 TD01 TD02 TD03 TD04 TD10 TD11 TD12 TD13 TD14
        TD20 TD21 TD22 TD23 TD24 TDBP TDEL TDER TDTC TDTP TDVx TDeL TDeR TG0B TG0C TG0H TG0V TG1B
        TG2B TH0a TH0b TH0x TH1a TH1b TMVR TPD0 TPD1 TPD2 TPD3 TPD4 TPD5 TPD6 TPD7 TPD8 TPD9 TPDX
        TPDa TPDb TPDc TPDd TPDe TPDf TPDg TPDh TPDi TPDj TPMP TPSP TPVD TR0Z TR1d TR2d TRD0 TRD1
        TRD2 TRD3 TRD4 TRD5 TRD6 TRD7 TRD8 TRD9 TRDX TRDa TRDb TRDc TRDd TRDe TRDf TRDg TRDh TRDi
        TRDj TS0P TSVR TSWR TSXR TVA0 TVD0 TVM0 TVM2 TVM3 TVM4 TVMC TVMD TVMO TVS0 TVS1 TVS2 TVSx
        TVV0 TVm0 TVm1 TW0P Ta0C Ta0D Ta0G Ta0H Ta0K Ta0L Ta0V Ta0W TaLP TaLT TaLW TaRF TaRT TaRW
        TaTP Te04 Te05 Te06 Tf00 Tf01 Tf02 Tf04 Tf05 Tf06 Tf08 Tf09 Tf0A Tf0B Tf0E Tf10 Tf11 Tf12
        Tf14 Tf15 Tf16 Tf18 Tf19 Tf1A Tf1B Tf1E Tf20 Tf21 Tf22 Tf24 Tf25 Tf26 Tf28 Tf29 Tf2A Tf2B
        Tf2E Tg0W Tg0X Tg0e Tg0f Tg0i Tg0j Tg1g Tg1h Tg1k Tg1l Th00 Th01 Th02 Th04 Th05 Th06 Th08
        Th09 Th0A Th0C Th0D Th0E Th0G Th0H Th0I Tp00 Tp01 Tp02 Tp04 Tp05 Tp06 Tp08 Tp09 Tp0A Tp0C
        Tp0D Tp0E Tp0W Tp0X Tp0Y Tp0a Tp0b Tp0c Tp0e Tp0f Tp0g Tp0i Tp0j Tp0k Tp16 Tp17 Tp18 Tp1A
        Tp1B Tp1C Tp1E Tp1F Tp1G Tp1I Tp1J Tp1K Tp1M Tp1N Tp1O Tp1g Tp1h Tp1i Tp1k Tp1l Tp1m Tp1o
        Tp1p Tp1q Tp1s Tp1t Tp1u Tp2G Tp2H Tp2I Ts0C Ts0D Ts0E Ts0P Ts0e Ts0f Ts0g Ts1P Tz11 Tz12
        Tz13 Tz14 Tz15 Tz16 Tz17 Tz18 Tz1j
        """.split(whereSeparator: \.isWhitespace).map(String.init)

    @Test func displayNamesAreUniqueAndDeterministic() {
        let keys = Self.mac14_9Keys + Array(SensorCatalog.knownNames.keys)
        #expect(Self.mac14_9Keys.count == 259)
        var seen: [String: String] = [:]
        for key in Set(keys) {
            let name = SensorCatalog.displayName(for: key)
            #expect(name == SensorCatalog.displayName(for: key))
            if let other = seen[name] {
                Issue.record("\(key) and \(other) share the name \"\(name)\"")
            }
            seen[name] = key
        }
    }

    /// Intel-era fixture (sp78): discovery still decodes generically.
    @Test func discoverLegacyFixedPointSensors() throws {
        let sensors = try SensorCatalog.discoverTemperatureSensors(using: Fixtures.intel())
        #expect(sensors.map(\.id) == ["TC0P", "TG0D", "TB0T", "Tm0P"])
        #expect(sensors.first?.temperature == 55.5)
        #expect(sensors.first?.name == "Sensor TC0P")
        #expect(sensors[1].temperature == 48.25)
        #expect(sensors.allSatisfy { $0.sensorType == .smc })
    }

    @Test func discoverAppleSilicon() throws {
        let sensors = try SensorCatalog.discoverTemperatureSensors(using: Fixtures.appleSilicon())
        #expect(sensors.map(\.id) == ["Tp09", "Te05"])
        #expect(sensors[0].temperature == 61.5)
        #expect(sensors[0].name == "CPU Performance Core 09")
        let wide = try SensorCatalog.discoverTemperatureSensors(using: Fixtures.appleSilicon(),
                                                                plausibleRange: -20...200)
        #expect(wide.map(\.id) == ["Tp09", "Te05", "Tg0f"])
    }

    @Test func discoverToleratesReadFailures() throws {
        let reader = Fixtures.intel()
        reader.failingReads.insert("TC0P")
        let sensors = try SensorCatalog.discoverTemperatureSensors(using: reader)
        #expect(sensors.map(\.id) == ["TG0D", "TB0T", "Tm0P"])
    }

    @Test func readTemperatures() {
        let readings = SensorCatalog.readTemperatures(keys: ["TC0P", "NOPE", "bad", "TB0T"], using: Fixtures.intel())
        #expect(readings.map(\.id) == ["TC0P", "TB0T"])
        #expect(readings[1].temperature == 31)
    }

    @Test func fahrenheit() {
        let reading = SensorReading(id: "TC0P", name: "CPU", temperature: 100, sensorType: .smc)
        #expect(reading.temperature(in: .fahrenheit) == 212)
        #expect(reading.temperature(in: .celsius) == 100)
    }
}
