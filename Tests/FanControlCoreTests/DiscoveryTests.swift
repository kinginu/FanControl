import Foundation
import Testing
@testable import FanControlCore

struct FanDiscoveryTests {
    @Test func testIntelFans() throws {
        let reader = Fixtures.intel()
        let fans = try FanDiscovery.discoverFans(using: reader)
        #expect(fans == [
            FanDevice(id: 0, name: "Left Side", minRPM: 1200, maxRPM: 6000),
            FanDevice(id: 1, name: "Right Side", minRPM: 1300, maxRPM: 5500),
        ])
        #expect(FanDiscovery.readCurrentRPMs(fans: fans, using: reader) == [0: 1210, 1: 2500])
        #expect(FanDiscovery.readTargetRPMs(fans: fans, using: reader) == [0: 1200, 1: 2500])
        // FS! = 0x0002 -> fan 1 forced.
        #expect(FanDiscovery.fanControlModes(fans: fans, using: reader) == [0: .automatic, 1: .constant(rpm: 2500)])
    }

    @Test func testAppleSiliconFans() throws {
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

    @Test func testSkipsFansWithUnreadableLimits() throws {
        let reader = Fixtures.intel()
        reader.failingReads.insert(.fanMax(1))
        let fans = try FanDiscovery.discoverFans(using: reader)
        #expect(fans.map(\.id) == [0])
    }

    @Test func testMissingFanCountThrows() {
        let reader = MockSMCReader([])
        #expect(throws: FanControlError.keyNotFound("FNum")) {
            try FanDiscovery.discoverFans(using: reader)
        }
    }

    @Test func testReaderHelpers() throws {
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

struct SensorCatalogTests {
    @Test func testDisplayNames() {
        #expect(SensorCatalog.displayName(for: "TC0P") == "CPU Proximity")
        #expect(SensorCatalog.displayName(for: "TPCD") == "Platform Controller Hub Die")
        #expect(SensorCatalog.displayName(for: "Tp09") == "CPU Performance Core 09")
        #expect(SensorCatalog.displayName(for: "Te05") == "CPU Efficiency Core 05")
        #expect(SensorCatalog.displayName(for: "Tg0f") == "GPU 0f")
        #expect(SensorCatalog.displayName(for: "TaLP") == "Airflow Left P")
        #expect(SensorCatalog.displayName(for: "TaRF") == "Airflow Right F")
        #expect(SensorCatalog.displayName(for: "TB1T") == "Battery 1T")
        #expect(SensorCatalog.displayName(for: "TH0x") == "Storage 0x")
        #expect(SensorCatalog.displayName(for: "Tm0P") == "Sensor Tm0P")
    }

    @Test func testDiscoverIntel() throws {
        let sensors = try SensorCatalog.discoverTemperatureSensors(using: Fixtures.intel())
        #expect(sensors.map(\.id) == ["TC0P", "TG0D", "TB0T", "Tm0P"])
        #expect(sensors.first?.temperature == 55.5)
        #expect(sensors.first?.name == "CPU Proximity")
        #expect(sensors[1].temperature == 48.25)
        #expect(sensors.allSatisfy { $0.sensorType == .smc })
    }

    @Test func testDiscoverAppleSilicon() throws {
        let sensors = try SensorCatalog.discoverTemperatureSensors(using: Fixtures.appleSilicon())
        #expect(sensors.map(\.id) == ["Tp09", "Te05"])
        #expect(sensors[0].temperature == 61.5)
        #expect(sensors[0].name == "CPU Performance Core 09")
        let wide = try SensorCatalog.discoverTemperatureSensors(using: Fixtures.appleSilicon(),
                                                                plausibleRange: -20...200)
        #expect(wide.map(\.id) == ["Tp09", "Te05", "Tg0f"])
    }

    @Test func testDiscoverToleratesReadFailures() throws {
        let reader = Fixtures.intel()
        reader.failingReads.insert("TC0P")
        let sensors = try SensorCatalog.discoverTemperatureSensors(using: reader)
        #expect(sensors.map(\.id) == ["TG0D", "TB0T", "Tm0P"])
    }

    @Test func testReadTemperatures() {
        let readings = SensorCatalog.readTemperatures(keys: ["TC0P", "NOPE", "bad", "TB0T"], using: Fixtures.intel())
        #expect(readings.map(\.id) == ["TC0P", "TB0T"])
        #expect(readings[1].temperature == 31)
    }

    @Test func testFahrenheit() {
        let reading = SensorReading(id: "TC0P", name: "CPU", temperature: 100, sensorType: .smc)
        #expect(reading.temperature(in: .fahrenheit) == 212)
        #expect(reading.temperature(in: .celsius) == 100)
    }
}
