import XCTest
@testable import FanControlCore

final class FanDiscoveryTests: XCTestCase {
    func testIntelFans() throws {
        let reader = Fixtures.intel()
        let fans = try FanDiscovery.discoverFans(using: reader)
        XCTAssertEqual(fans, [
            FanDevice(id: 0, name: "Left Side", minRPM: 1200, maxRPM: 6000),
            FanDevice(id: 1, name: "Right Side", minRPM: 1300, maxRPM: 5500),
        ])
        XCTAssertEqual(FanDiscovery.readCurrentRPMs(fans: fans, using: reader), [0: 1210, 1: 2500])
        XCTAssertEqual(FanDiscovery.readTargetRPMs(fans: fans, using: reader), [0: 1200, 1: 2500])
        // FS! = 0x0002 -> fan 1 forced.
        XCTAssertEqual(FanDiscovery.fanControlModes(fans: fans, using: reader),
                       [0: .automatic, 1: .constant(rpm: 2500)])
    }

    func testAppleSiliconFans() throws {
        let reader = Fixtures.appleSilicon()
        let fans = try FanDiscovery.discoverFans(using: reader)
        XCTAssertEqual(fans, [
            FanDevice(id: 0, name: "Fan 1", minRPM: 1200, maxRPM: 5779),
            FanDevice(id: 1, name: "Fan 2", minRPM: 1200, maxRPM: 6241),
        ])
        XCTAssertEqual(FanDiscovery.readCurrentRPMs(fans: fans, using: reader), [0: 2400, 1: 1200])
        // F1Tg is absent -> omitted.
        XCTAssertEqual(FanDiscovery.readTargetRPMs(fans: fans, using: reader), [0: 2400])
        XCTAssertEqual(FanDiscovery.fanControlModes(fans: fans, using: reader),
                       [0: .constant(rpm: 2400), 1: .automatic])
    }

    func testSkipsFansWithUnreadableLimits() throws {
        let reader = Fixtures.intel()
        reader.failingReads.insert(.fanMax(1))
        let fans = try FanDiscovery.discoverFans(using: reader)
        XCTAssertEqual(fans.map(\.id), [0])
    }

    func testMissingFanCountThrows() {
        let reader = MockSMCReader([])
        XCTAssertThrowsError(try FanDiscovery.discoverFans(using: reader)) { error in
            XCTAssertEqual(error as? FanControlError, .keyNotFound("FNum"))
        }
    }

    func testReaderHelpers() throws {
        let reader = Fixtures.intel()
        XCTAssertTrue(reader.exists("TC0P"))
        XCTAssertFalse(reader.exists("XXXX"))
        XCTAssertEqual(try reader.readNumber("TC0P"), 55.5)
        XCTAssertEqual(try reader.readValue("TZZZ"), .string("abcd"))
        XCTAssertThrowsError(try reader.readNumber("TZZZ")) { error in
            XCTAssertEqual(error as? FanControlError, .unsupportedDataType("ch8*"))
        }
        XCTAssertTrue(SMCKeyInfo(dataSize: 2, dataType: .fpe2, attributes: 0xD4).isWritable)
        XCTAssertFalse(SMCKeyInfo(dataSize: 2, dataType: .fpe2, attributes: 0x40).isWritable)
    }
}

final class SensorCatalogTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(SensorCatalog.displayName(for: "TC0P"), "CPU Proximity")
        XCTAssertEqual(SensorCatalog.displayName(for: "TPCD"), "Platform Controller Hub Die")
        XCTAssertEqual(SensorCatalog.displayName(for: "Tp09"), "CPU Performance Core 09")
        XCTAssertEqual(SensorCatalog.displayName(for: "Te05"), "CPU Efficiency Core 05")
        XCTAssertEqual(SensorCatalog.displayName(for: "Tg0f"), "GPU 0f")
        XCTAssertEqual(SensorCatalog.displayName(for: "TaLP"), "Airflow Left P")
        XCTAssertEqual(SensorCatalog.displayName(for: "TaRF"), "Airflow Right F")
        XCTAssertEqual(SensorCatalog.displayName(for: "TB1T"), "Battery 1T")
        XCTAssertEqual(SensorCatalog.displayName(for: "TH0x"), "Storage 0x")
        XCTAssertEqual(SensorCatalog.displayName(for: "Tm0P"), "Sensor Tm0P")
    }

    func testDiscoverIntel() throws {
        let sensors = try SensorCatalog.discoverTemperatureSensors(using: Fixtures.intel())
        XCTAssertEqual(sensors.map(\.id), ["TC0P", "TG0D", "TB0T", "Tm0P"])
        XCTAssertEqual(sensors.first?.temperature, 55.5)
        XCTAssertEqual(sensors.first?.name, "CPU Proximity")
        XCTAssertEqual(sensors[1].temperature, 48.25)
        XCTAssertTrue(sensors.allSatisfy { $0.sensorType == .smc })
    }

    func testDiscoverAppleSilicon() throws {
        let sensors = try SensorCatalog.discoverTemperatureSensors(using: Fixtures.appleSilicon())
        XCTAssertEqual(sensors.map(\.id), ["Tp09", "Te05"])
        XCTAssertEqual(sensors[0].temperature, 61.5)
        XCTAssertEqual(sensors[0].name, "CPU Performance Core 09")
        let wide = try SensorCatalog.discoverTemperatureSensors(using: Fixtures.appleSilicon(),
                                                                plausibleRange: -20...200)
        XCTAssertEqual(wide.map(\.id), ["Tp09", "Te05", "Tg0f"])
    }

    func testDiscoverToleratesReadFailures() throws {
        let reader = Fixtures.intel()
        reader.failingReads.insert("TC0P")
        let sensors = try SensorCatalog.discoverTemperatureSensors(using: reader)
        XCTAssertEqual(sensors.map(\.id), ["TG0D", "TB0T", "Tm0P"])
    }

    func testReadTemperatures() {
        let readings = SensorCatalog.readTemperatures(keys: ["TC0P", "NOPE", "bad", "TB0T"], using: Fixtures.intel())
        XCTAssertEqual(readings.map(\.id), ["TC0P", "TB0T"])
        XCTAssertEqual(readings[1].temperature, 31)
    }

    func testFahrenheit() {
        let reading = SensorReading(id: "TC0P", name: "CPU", temperature: 100, sensorType: .smc)
        XCTAssertEqual(reading.temperature(in: .fahrenheit), 212)
        XCTAssertEqual(reading.temperature(in: .celsius), 100)
    }
}
