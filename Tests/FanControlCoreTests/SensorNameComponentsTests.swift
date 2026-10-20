import Testing
@testable import FanControlCore

/// `SensorCatalog.nameComponents(for:)` (design doc §5.7, localizable sensor names).
@Suite struct SensorNameComponentsTests {

    private func components(_ key: String) -> SensorNameComponents { SensorCatalog.nameComponents(for: key) }

    @Test func testRepresentativeKeys() {
        #expect(components("Tp0D") == SensorNameComponents(labelKey: "CPU Performance Core", suffix: "0D"))
        #expect(components("Te05") == SensorNameComponents(labelKey: "CPU Efficiency Core", suffix: "05"))
        #expect(components("Tg0f") == SensorNameComponents(labelKey: "GPU", suffix: "0f"))
        #expect(components("TB1T") == SensorNameComponents(labelKey: "Battery", suffix: "1"))
        #expect(components("TB0T") == SensorNameComponents(labelKey: "Battery", suffix: nil))
        #expect(components("TaLP") == SensorNameComponents(labelKey: "Airflow Left", suffix: nil))
        #expect(components("TaRF") == SensorNameComponents(labelKey: "Airflow Right", suffix: nil))
        #expect(components("TaLT") == SensorNameComponents(labelKey: "Airflow Left", suffix: "T"))
        #expect(components("TH0x") == SensorNameComponents(labelKey: "NAND (SSD)", suffix: nil))
        #expect(components("TH0a") == SensorNameComponents(labelKey: "Storage", suffix: "0a"))
        #expect(components("Ts0P") == SensorNameComponents(labelKey: "Palm Rest", suffix: nil))
        #expect(components("Ts1P") == SensorNameComponents(labelKey: "Palm Rest", suffix: "2"))
        #expect(components("TW0P") == SensorNameComponents(labelKey: "Wireless", suffix: nil))
        // [legacy] memory family, unverified on Apple Silicon.
        #expect(components("TM0P") == SensorNameComponents(labelKey: "Memory", suffix: "0P"))
    }

    @Test func testFallbackAndAggregates() {
        let unknown = components("Tz11")
        #expect(unknown == SensorNameComponents(labelKey: "Sensor", suffix: "Tz11", isFallback: true))
        #expect(unknown.englishName == "Sensor Tz11")
        #expect(components("agg:cpu") == SensorNameComponents(labelKey: "CPU (max)", suffix: nil))
        #expect(components("agg:nope") == SensorNameComponents(labelKey: "Sensor", suffix: "agg:nope", isFallback: true))
    }

    @Test func testLabelKeysCoverEveryComponent() {
        for key in Self.mac14_9Names.keys + ["TM0P"] {
            let c = components(key)
            #expect(SensorCatalog.labelKeys.contains(c.labelKey), "\(key) → \(c.labelKey)")
            #expect(c.isFallback == (c.labelKey == SensorCatalog.fallbackLabelKey))
        }
        for name in SensorCatalog.knownNames.values {
            #expect(SensorCatalog.labelKeys.contains { name == $0 || name.hasPrefix($0 + " ") })
        }
    }

    @Test func testNameWithLocalizedLabel() {
        #expect(components("Tp09").name(label: "CPU 高性能コア") == "CPU 高性能コア 09")
        #expect(components("TH0x").name(label: "NAND（SSD）") == "NAND（SSD）")
    }

    /// `displayName(for:)` output is unchanged for every `T*` key of the Mac14,9 /
    /// macOS 26 dump (`docs/verification/Mac14,9-macOS26-dump.txt`), recorded
    /// before the names were split into components.
    @Test func testDisplayNameUnchangedForMac14_9Keys() {
        #expect(Self.mac14_9Names.count == 259)
        for (key, name) in Self.mac14_9Names {
            #expect(SensorCatalog.displayName(for: key) == name, "\(key)")
            #expect(components(key).englishName == name, "\(key)")
        }
    }

    static let mac14_9Names: [String: String] = [
        "Ta0C": "Sensor Ta0C",
        "Ta0D": "Sensor Ta0D",
        "Ta0G": "Sensor Ta0G",
        "Ta0H": "Sensor Ta0H",
        "Ta0K": "Sensor Ta0K",
        "Ta0L": "Sensor Ta0L",
        "Ta0V": "Sensor Ta0V",
        "Ta0W": "Sensor Ta0W",
        "TaLP": "Airflow Left",
        "TaLT": "Airflow Left T",
        "TaLW": "Airflow Left W",
        "TAOL": "Sensor TAOL",
        "TaRF": "Airflow Right",
        "TaRT": "Airflow Right T",
        "TaRW": "Airflow Right W",
        "TaTP": "Sensor TaTP",
        "TB0T": "Battery",
        "TB1T": "Battery 1",
        "TB2T": "Battery 2",
        "TCDX": "Sensor TCDX",
        "TCHP": "Sensor TCHP",
        "TCMb": "Sensor TCMb",
        "TCMz": "Sensor TCMz",
        "TD00": "Sensor TD00",
        "TD01": "Sensor TD01",
        "TD02": "Sensor TD02",
        "TD03": "Sensor TD03",
        "TD04": "Sensor TD04",
        "TD10": "Sensor TD10",
        "TD11": "Sensor TD11",
        "TD12": "Sensor TD12",
        "TD13": "Sensor TD13",
        "TD14": "Sensor TD14",
        "TD20": "Sensor TD20",
        "TD21": "Sensor TD21",
        "TD22": "Sensor TD22",
        "TD23": "Sensor TD23",
        "TD24": "Sensor TD24",
        "TDBP": "Sensor TDBP",
        "TDeL": "Sensor TDeL",
        "TDEL": "Sensor TDEL",
        "TDeR": "Sensor TDeR",
        "TDER": "Sensor TDER",
        "TDTC": "Sensor TDTC",
        "TDTP": "Sensor TDTP",
        "TDVx": "Sensor TDVx",
        "Te04": "CPU Efficiency Core 04",
        "Te05": "CPU Efficiency Core 05",
        "Te06": "CPU Efficiency Core 06",
        "Tf00": "Sensor Tf00",
        "Tf01": "Sensor Tf01",
        "Tf02": "Sensor Tf02",
        "Tf04": "Sensor Tf04",
        "Tf05": "Sensor Tf05",
        "Tf06": "Sensor Tf06",
        "Tf08": "Sensor Tf08",
        "Tf09": "Sensor Tf09",
        "Tf0A": "Sensor Tf0A",
        "Tf0B": "Sensor Tf0B",
        "Tf0E": "Sensor Tf0E",
        "Tf10": "Sensor Tf10",
        "Tf11": "Sensor Tf11",
        "Tf12": "Sensor Tf12",
        "Tf14": "Sensor Tf14",
        "Tf15": "Sensor Tf15",
        "Tf16": "Sensor Tf16",
        "Tf18": "Sensor Tf18",
        "Tf19": "Sensor Tf19",
        "Tf1A": "Sensor Tf1A",
        "Tf1B": "Sensor Tf1B",
        "Tf1E": "Sensor Tf1E",
        "Tf20": "Sensor Tf20",
        "Tf21": "Sensor Tf21",
        "Tf22": "Sensor Tf22",
        "Tf24": "Sensor Tf24",
        "Tf25": "Sensor Tf25",
        "Tf26": "Sensor Tf26",
        "Tf28": "Sensor Tf28",
        "Tf29": "Sensor Tf29",
        "Tf2A": "Sensor Tf2A",
        "Tf2B": "Sensor Tf2B",
        "Tf2E": "Sensor Tf2E",
        "TG0B": "Sensor TG0B",
        "TG0C": "Sensor TG0C",
        "Tg0e": "GPU 0e",
        "Tg0f": "GPU 0f",
        "TG0H": "Sensor TG0H",
        "Tg0i": "GPU 0i",
        "Tg0j": "GPU 0j",
        "TG0V": "Sensor TG0V",
        "Tg0W": "GPU 0W",
        "Tg0X": "GPU 0X",
        "TG1B": "Sensor TG1B",
        "Tg1g": "GPU 1g",
        "Tg1h": "GPU 1h",
        "Tg1k": "GPU 1k",
        "Tg1l": "GPU 1l",
        "TG2B": "Sensor TG2B",
        "Th00": "Sensor Th00",
        "Th01": "Sensor Th01",
        "Th02": "Sensor Th02",
        "Th04": "Sensor Th04",
        "Th05": "Sensor Th05",
        "Th06": "Sensor Th06",
        "Th08": "Sensor Th08",
        "Th09": "Sensor Th09",
        "Th0A": "Sensor Th0A",
        "TH0a": "Storage 0a",
        "TH0b": "Storage 0b",
        "Th0C": "Sensor Th0C",
        "Th0D": "Sensor Th0D",
        "Th0E": "Sensor Th0E",
        "Th0G": "Sensor Th0G",
        "Th0H": "Sensor Th0H",
        "Th0I": "Sensor Th0I",
        "TH0x": "NAND (SSD)",
        "TH1a": "Storage 1a",
        "TH1b": "Storage 1b",
        "TMVR": "Memory VR",
        "Tp00": "CPU Performance Core 00",
        "Tp01": "CPU Performance Core 01",
        "Tp02": "CPU Performance Core 02",
        "Tp04": "CPU Performance Core 04",
        "Tp05": "CPU Performance Core 05",
        "Tp06": "CPU Performance Core 06",
        "Tp08": "CPU Performance Core 08",
        "Tp09": "CPU Performance Core 09",
        "Tp0a": "CPU Performance Core 0a",
        "Tp0A": "CPU Performance Core 0A",
        "Tp0b": "CPU Performance Core 0b",
        "Tp0c": "CPU Performance Core 0c",
        "Tp0C": "CPU Performance Core 0C",
        "Tp0D": "CPU Performance Core 0D",
        "Tp0e": "CPU Performance Core 0e",
        "Tp0E": "CPU Performance Core 0E",
        "Tp0f": "CPU Performance Core 0f",
        "Tp0g": "CPU Performance Core 0g",
        "Tp0i": "CPU Performance Core 0i",
        "Tp0j": "CPU Performance Core 0j",
        "Tp0k": "CPU Performance Core 0k",
        "Tp0W": "CPU Performance Core 0W",
        "Tp0X": "CPU Performance Core 0X",
        "Tp0Y": "CPU Performance Core 0Y",
        "Tp16": "CPU Performance Core 16",
        "Tp17": "CPU Performance Core 17",
        "Tp18": "CPU Performance Core 18",
        "Tp1A": "CPU Performance Core 1A",
        "Tp1B": "CPU Performance Core 1B",
        "Tp1C": "CPU Performance Core 1C",
        "Tp1E": "CPU Performance Core 1E",
        "Tp1F": "CPU Performance Core 1F",
        "Tp1g": "CPU Performance Core 1g",
        "Tp1G": "CPU Performance Core 1G",
        "Tp1h": "CPU Performance Core 1h",
        "Tp1i": "CPU Performance Core 1i",
        "Tp1I": "CPU Performance Core 1I",
        "Tp1J": "CPU Performance Core 1J",
        "Tp1k": "CPU Performance Core 1k",
        "Tp1K": "CPU Performance Core 1K",
        "Tp1l": "CPU Performance Core 1l",
        "Tp1m": "CPU Performance Core 1m",
        "Tp1M": "CPU Performance Core 1M",
        "Tp1N": "CPU Performance Core 1N",
        "Tp1o": "CPU Performance Core 1o",
        "Tp1O": "CPU Performance Core 1O",
        "Tp1p": "CPU Performance Core 1p",
        "Tp1q": "CPU Performance Core 1q",
        "Tp1s": "CPU Performance Core 1s",
        "Tp1t": "CPU Performance Core 1t",
        "Tp1u": "CPU Performance Core 1u",
        "Tp2G": "CPU Performance Core 2G",
        "Tp2H": "CPU Performance Core 2H",
        "Tp2I": "CPU Performance Core 2I",
        "TPD0": "Sensor TPD0",
        "TPD1": "Sensor TPD1",
        "TPD2": "Sensor TPD2",
        "TPD3": "Sensor TPD3",
        "TPD4": "Sensor TPD4",
        "TPD5": "Sensor TPD5",
        "TPD6": "Sensor TPD6",
        "TPD7": "Sensor TPD7",
        "TPD8": "Sensor TPD8",
        "TPD9": "Sensor TPD9",
        "TPDa": "Sensor TPDa",
        "TPDb": "Sensor TPDb",
        "TPDc": "Sensor TPDc",
        "TPDd": "Sensor TPDd",
        "TPDe": "Sensor TPDe",
        "TPDf": "Sensor TPDf",
        "TPDg": "Sensor TPDg",
        "TPDh": "Sensor TPDh",
        "TPDi": "Sensor TPDi",
        "TPDj": "Sensor TPDj",
        "TPDX": "Sensor TPDX",
        "TPMP": "Sensor TPMP",
        "TPSP": "Sensor TPSP",
        "TPVD": "Sensor TPVD",
        "TR0Z": "Sensor TR0Z",
        "TR1d": "Sensor TR1d",
        "TR2d": "Sensor TR2d",
        "TRD0": "Sensor TRD0",
        "TRD1": "Sensor TRD1",
        "TRD2": "Sensor TRD2",
        "TRD3": "Sensor TRD3",
        "TRD4": "Sensor TRD4",
        "TRD5": "Sensor TRD5",
        "TRD6": "Sensor TRD6",
        "TRD7": "Sensor TRD7",
        "TRD8": "Sensor TRD8",
        "TRD9": "Sensor TRD9",
        "TRDa": "Sensor TRDa",
        "TRDb": "Sensor TRDb",
        "TRDc": "Sensor TRDc",
        "TRDd": "Sensor TRDd",
        "TRDe": "Sensor TRDe",
        "TRDf": "Sensor TRDf",
        "TRDg": "Sensor TRDg",
        "TRDh": "Sensor TRDh",
        "TRDi": "Sensor TRDi",
        "TRDj": "Sensor TRDj",
        "TRDX": "Sensor TRDX",
        "Ts0C": "Sensor Ts0C",
        "Ts0D": "Sensor Ts0D",
        "Ts0e": "Sensor Ts0e",
        "Ts0E": "Sensor Ts0E",
        "Ts0f": "Sensor Ts0f",
        "Ts0g": "Sensor Ts0g",
        "Ts0P": "Palm Rest",
        "TS0P": "Sensor TS0P",
        "Ts1P": "Palm Rest 2",
        "TSVR": "Sensor TSVR",
        "TSWR": "Sensor TSWR",
        "TSXR": "Sensor TSXR",
        "TVA0": "Sensor TVA0",
        "TVD0": "Sensor TVD0",
        "TVm0": "Sensor TVm0",
        "TVM0": "Sensor TVM0",
        "TVm1": "Sensor TVm1",
        "TVM2": "Sensor TVM2",
        "TVM3": "Sensor TVM3",
        "TVM4": "Sensor TVM4",
        "TVMC": "Sensor TVMC",
        "TVMD": "Sensor TVMD",
        "TVMO": "Sensor TVMO",
        "TVS0": "Sensor TVS0",
        "TVS1": "Sensor TVS1",
        "TVS2": "Sensor TVS2",
        "TVSx": "Sensor TVSx",
        "TVV0": "Sensor TVV0",
        "TW0P": "Wireless",
        "Tz11": "Sensor Tz11",
        "Tz12": "Sensor Tz12",
        "Tz13": "Sensor Tz13",
        "Tz14": "Sensor Tz14",
        "Tz15": "Sensor Tz15",
        "Tz16": "Sensor Tz16",
        "Tz17": "Sensor Tz17",
        "Tz18": "Sensor Tz18",
        "Tz1j": "Sensor Tz1j",
    ]
}
