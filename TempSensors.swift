import Foundation
import IOKit

// Private IOHIDEventSystem API — the same route tools like Stats/macmon use to read
// Apple Silicon die temperatures without root.
private typealias IOHIDEventSystemClientRef = OpaquePointer
private typealias IOHIDServiceClientRef = OpaquePointer
private typealias IOHIDEventRef = OpaquePointer

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClientRef?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: IOHIDEventSystemClientRef, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: IOHIDEventSystemClientRef) -> CFArray?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: IOHIDServiceClientRef, _ key: CFString) -> CFTypeRef?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: IOHIDServiceClientRef, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> IOHIDEventRef?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: IOHIDEventRef, _ field: Int32) -> Double

struct TempReading {
    let average: Double
    let max: Double
    let sensorCount: Int
}

final class TempSensors {
    private let kIOHIDEventTypeTemperature: Int64 = 15
    private let client: IOHIDEventSystemClientRef?

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        if let client {
            let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
            _ = IOHIDEventSystemClientSetMatching(client, matching)
        }
    }

    /// Reads the SoC die sensors ("PMU tdie*" on M5; "pACC/eACC MTR" on older chips).
    func read() -> TempReading? {
        guard let client, let services = IOHIDEventSystemClientCopyServices(client) as? [AnyObject] else { return nil }
        var values: [Double] = []
        for item in services {
            let service = unsafeBitCast(item, to: IOHIDServiceClientRef.self)
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String,
                  name.hasPrefix("PMU tdie") || name.contains("ACC MTR"),
                  let event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0)
            else { continue }
            let value = IOHIDEventGetFloatValue(event, Int32(kIOHIDEventTypeTemperature << 16))
            if value > 0 && value < 150 { values.append(value) }
        }
        guard !values.isEmpty else { return nil }
        return TempReading(average: values.reduce(0, +) / Double(values.count),
                           max: values.max()!,
                           sensorCount: values.count)
    }
}
