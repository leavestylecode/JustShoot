import Foundation
import CoreLocation

struct CaptureLocation: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let timestamp: Date

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.altitude
        horizontalAccuracy = location.horizontalAccuracy
        verticalAccuracy = location.verticalAccuracy
        timestamp = location.timestamp
    }

    var location: CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                   altitude: altitude, horizontalAccuracy: horizontalAccuracy,
                   verticalAccuracy: verticalAccuracy, timestamp: timestamp)
    }

    static func isUsable(_ location: CLLocation, at date: Date) -> Bool {
        let age = date.timeIntervalSince(location.timestamp)
        return CLLocationCoordinate2DIsValid(location.coordinate)
            && location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 1_000
            && age >= -5 && age <= 30
    }
}

/// A capture freezes its render recipe and LUT independently of mutable presets and caches.
struct CaptureRecipe: Codable, Sendable {
    let id: UUID
    let captureDate: Date
    let filterName: String
    let displayLabel: String?
    let focalLength: Int
    let outputQuality: Double
    let profile: FilmRenderProfile
    let grainSeed: UInt32
    let location: CaptureLocation?
    let lutDimension: Int
    let photoDisplayTime: Double?
}

struct CaptureJob: Codable, Sendable {
    var formatVersion = 1
    let recipe: CaptureRecipe
    let hasSourceMovie: Bool
    var rendered = false
    var hasRenderedMovie = false
    var assetIdentifier: String?

    var id: UUID { recipe.id }
}

/// The manifest is the commit marker. Incomplete staging directories are retained for recovery,
/// and only a completed export/index transaction may remove a committed job.
struct CaptureJournal: Sendable {
    let root: URL
    static let maximumJobs = 16
    static let maximumBytes: Int64 = 1_024 * 1_024 * 1_024

    enum JournalError: LocalizedError {
        case full
        case invalidJob

        var errorDescription: String? {
            switch self {
            case .full: String(localized: "Please wait for your photos to finish saving.")
            case .invalidJob: String(localized: "A saved photo could not be opened. Its original files have been kept.")
            }
        }
    }

    static var application: CaptureJournal {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CaptureJournal(root: support.appendingPathComponent("PendingCaptures", isDirectory: true))
    }

    func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func file(_ name: String, for id: UUID) -> URL { directory(for: id).appendingPathComponent(name) }

    func jobs() throws -> [CaptureJob] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { directory in
                guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("discarded").path) else { return nil }
                do {
                    let job = try JSONDecoder().decode(CaptureJob.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
                    guard job.formatVersion == 1, job.id.uuidString == directory.lastPathComponent else { throw JournalError.invalidJob }
                    return job
                } catch {
                    // A damaged manifest must never cause deletion of its original capture.
                    Log.save.error("capture_manifest_unreadable directory=\(directory.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            .sorted { $0.recipe.captureDate < $1.recipe.captureDate }
    }

    func recover() throws -> [CaptureJob] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        for staging in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where staging.lastPathComponent.hasPrefix("staging-") {
            guard let data = try? Data(contentsOf: staging.appendingPathComponent("manifest.json")),
                  let job = try? JSONDecoder().decode(CaptureJob.self, from: data),
                  job.formatVersion == 1,
                  staging.lastPathComponent == "staging-" + job.id.uuidString,
                  fm.fileExists(atPath: staging.appendingPathComponent("original.image").path),
                  fm.fileExists(atPath: staging.appendingPathComponent("lut.bin").path),
                  !job.hasSourceMovie || fm.fileExists(atPath: staging.appendingPathComponent("source.mov").path),
                  !fm.fileExists(atPath: directory(for: job.id).path) else { continue }
            try fm.moveItem(at: staging, to: directory(for: job.id))
        }
        return try jobs()
    }

    func hasRoom(for bytes: Int64) throws -> Bool {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard try diskUsage() + bytes <= Self.maximumBytes else { return false }
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return available.map { $0 >= bytes + 128 * 1_024 * 1_024 } ?? true
    }

    func stage(recipe: CaptureRecipe, imageData: Data, movieURL: URL?, lut: CubeLUT, reserved: Bool = false) throws -> CaptureJob {
        guard recipe.lutDimension == lut.dimension else { throw JournalError.invalidJob }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Reservations are checked before exposure. Once accepted, persist the capture even if a
        // soft budget changes during exposure; only a real filesystem error may stop this write.
        if !reserved {
            let movieBytes = movieURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
            guard try jobs().count < Self.maximumJobs,
                  try hasRoom(for: Int64(imageData.count) + Int64(lut.data.count) + Int64(movieBytes)) else {
                throw JournalError.full
            }
        }

        let staging = root.appendingPathComponent("staging-\(recipe.id.uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try write(imageData, to: staging.appendingPathComponent("original.image"))
        try write(lut.data, to: staging.appendingPathComponent("lut.bin"))
        if let movieURL {
            let destination = staging.appendingPathComponent("source.mov")
            if !fm.fileExists(atPath: destination.path) { try fm.copyItem(at: movieURL, to: destination) }
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        }
        let job = CaptureJob(recipe: recipe, hasSourceMovie: movieURL != nil)
        try write(JSONEncoder().encode(job), to: staging.appendingPathComponent("manifest.json"))
        try fm.moveItem(at: staging, to: directory(for: recipe.id))
        if let movieURL { try? fm.removeItem(at: movieURL) }
        return job
    }

    func update(_ job: CaptureJob) throws {
        try write(JSONEncoder().encode(job), to: file("manifest.json", for: job.id))
    }

    func lut(for job: CaptureJob) throws -> CubeLUT {
        try CubeLUT.validated(data: Data(contentsOf: file("lut.bin", for: job.id)), dimension: job.recipe.lutDimension)
    }

    func writeRenderedImage(_ data: Data, for id: UUID) throws {
        try write(data, to: file("rendered.image", for: id))
    }

    func markDiscarded(_ id: UUID) throws { try write(Data(), to: file("discarded", for: id)) }

    func undoDiscard(_ id: UUID) throws {
        let marker = file("discarded", for: id)
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    }

    func finish(_ id: UUID) throws { try FileManager.default.removeItem(at: directory(for: id)) }

    func diskUsage() throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        return total
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
