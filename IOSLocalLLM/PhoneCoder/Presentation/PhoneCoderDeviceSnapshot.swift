import Foundation
import Combine

/// Presentation only. These sampled values never admit a model or replace the
/// live MemoryAdvisor / DeviceSafetyMonitor checks before heavy work.
struct PhoneCoderDeviceSnapshot {
    enum Entitlement: String {
        case present = "Present"
        case absent = "Absent"
        case notApplicable = "Not applicable"
        case unavailable = "Unavailable"
    }

    enum Kind: String {
        case raw, derived, estimated, unavailable
    }

    struct Row: Identifiable {
        let id: String
        let title: String
        let value: String
        let kind: Kind
        var label: String { "\(title) (\(kind.rawValue))" }
    }

    let sampledAt: Date
    let physicalMemoryBytes: Int64?
    let appFootprintBytes: Int64?
    let processAvailableBytes: Int64?
    let processCeilingBytes: Int64?
    let modelHeadroomBytes: Int64?
    let entitlement: Entitlement
    let thermalState: ProcessInfo.ThermalState
    let effectiveThermalState: ProcessInfo.ThermalState
    let lowPowerMode: Bool
    let stopReason: DeviceSafetyMonitor.StopReason?
    let isThrottling: Bool

    init(sampledAt: Date, physicalMemoryBytes: Int64, appFootprintBytes: Int64,
         processAvailableBytes: Int64, processCeilingBytes: Int64,
         entitlement: Entitlement, thermalState: ProcessInfo.ThermalState,
         effectiveThermalState: ProcessInfo.ThermalState, lowPowerMode: Bool,
         stopReason: DeviceSafetyMonitor.StopReason?, isThrottling: Bool) {
        self.sampledAt = sampledAt
        self.physicalMemoryBytes = physicalMemoryBytes > 0 ? physicalMemoryBytes : nil
        self.appFootprintBytes = appFootprintBytes > 0 ? appFootprintBytes : nil
        self.processAvailableBytes = processAvailableBytes > 0 ? processAvailableBytes : nil
        self.processCeilingBytes = processCeilingBytes > 0 ? processCeilingBytes : nil
        // A policy fallback is useful as an estimated ceiling, but cannot turn
        // missing kernel measurements into live allocatable memory. Clamp the
        // advisory difference to the raw headroom too; readings are not atomic.
        if appFootprintBytes > 0, processAvailableBytes > 0, processCeilingBytes > 0 {
            modelHeadroomBytes = min(processAvailableBytes, max(0, processCeilingBytes - appFootprintBytes))
        } else {
            modelHeadroomBytes = nil
        }
        self.entitlement = entitlement
        self.thermalState = thermalState
        self.effectiveThermalState = effectiveThermalState
        self.lowPowerMode = lowPowerMode
        self.stopReason = stopReason
        self.isThrottling = isThrottling
    }

    private var ceilingKind: Kind {
        appFootprintBytes != nil && processAvailableBytes != nil ? .derived : .estimated
    }

    var sampledAtText: String { ISO8601DateFormatter().string(from: sampledAt) }

    var rows: [Row] { presentationRows(byteValues: false) }

    /// Fixed allowlist, fixed ordering, locale-independent byte counts and UTC
    /// time. No caller-provided strings, errors, paths or user data are accepted.
    var diagnostics: String {
        (["Device snapshot (advisory; runtime gates recheck)", "Sampled at: \(sampledAtText)"] +
         presentationRows(byteValues: true).map { "\($0.title) [\($0.kind.rawValue)]: \($0.value)" })
            .joined(separator: "\n")
    }

    private func presentationRows(byteValues: Bool) -> [Row] {
        [memoryRow("physical", "Physical memory", physicalMemoryBytes, .raw, byteValues),
         memoryRow("footprint", "App footprint", appFootprintBytes, .raw, byteValues),
         memoryRow("processAvailable", "Process available", processAvailableBytes, .raw, byteValues),
         memoryRow("ceiling", "Process ceiling", processCeilingBytes, ceilingKind, byteValues),
         memoryRow("modelHeadroom", "Model headroom", modelHeadroomBytes, .derived, byteValues),
         .init(id: "entitlement", title: "Increased-memory entitlement", value: entitlement.rawValue,
               kind: entitlement == .unavailable ? .unavailable : .raw),
         .init(id: "thermal", title: "Thermal", value: thermalLabel(thermalState), kind: .raw),
         .init(id: "effectiveThermal", title: "Effective thermal", value: thermalLabel(effectiveThermalState), kind: .derived),
         .init(id: "lowPower", title: "Low power mode", value: lowPowerMode ? "On" : "Off", kind: .raw),
         .init(id: "safety", title: "Runtime safety", value: safetyLabel, kind: .derived)]
    }

    private func memoryRow(_ id: String, _ title: String, _ bytes: Int64?, _ kind: Kind,
                           _ byteValues: Bool) -> Row {
        guard let bytes else { return .init(id: id, title: title, value: "Unavailable", kind: .unavailable) }
        let value = byteValues ? "\(bytes) bytes" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
        return .init(id: id, title: title, value: value, kind: kind)
    }

    private func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unavailable"
        }
    }

    private var safetyLabel: String {
        switch stopReason {
        case .thermal: return "Paused: thermal"
        case .memoryPressure: return "Paused: memory pressure"
        case nil: return isThrottling ? "Throttling" : "No current stop signal"
        }
    }
}

@MainActor
protocol PhoneCoderDeviceSnapshotProviding {
    func sample() -> PhoneCoderDeviceSnapshot
}

@MainActor
struct PhoneCoderLiveDeviceSnapshotProvider: PhoneCoderDeviceSnapshotProviding {
    func sample() -> PhoneCoderDeviceSnapshot {
        let safety = DeviceSafetyMonitor.shared
        let entitlement: PhoneCoderDeviceSnapshot.Entitlement
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        entitlement = MemoryAdvisor.hasIncreasedMemoryLimitEntitlement ? .present : .absent
        #else
        // MemoryAdvisor returns true on Simulator/Catalyst for runtime policy;
        // that does not mean an iOS entitlement was observed in a signature.
        entitlement = .notApplicable
        #endif
        return .init(sampledAt: .now,
                     physicalMemoryBytes: MemoryAdvisor.deviceTotalRAM,
                     appFootprintBytes: MemoryAdvisor.physFootprint,
                     processAvailableBytes: MemoryAdvisor.processAvailableMemory,
                     processCeilingBytes: MemoryAdvisor.processMemoryCeiling,
                     entitlement: entitlement, thermalState: safety.thermalState,
                     effectiveThermalState: safety.effectiveThermalState,
                     lowPowerMode: safety.lowPowerMode, stopReason: safety.stopReason,
                     isThrottling: safety.shouldThrottle)
    }
}

@MainActor
final class PhoneCoderDeviceSnapshotModel: ObservableObject {
    @Published private(set) var snapshot: PhoneCoderDeviceSnapshot?
    private let provider: any PhoneCoderDeviceSnapshotProviding

    init(provider: (any PhoneCoderDeviceSnapshotProviding)? = nil) {
        self.provider = provider ?? PhoneCoderLiveDeviceSnapshotProvider()
    }

    func refresh() { snapshot = provider.sample() }
}
