import Foundation
import CoreLocation
import ImageIO
import UniformTypeIdentifiers

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
    /// Only legacy jobs freeze a manual quality value. New captures use automatic encoding.
    let outputQuality: Double?
    let profile: FilmRenderProfile
    let grainSeed: UInt32
    let location: CaptureLocation?
    let lutDimension: Int
    /// 快门时刻的场景色温快照（设备 AWB 读数，K）。胶片色温响应（未校白）的输入；
    /// optional 兼容旧 journal——缺失时响应中性（增益 1），渲染结果与旧版一致。
    let chromaticSceneCCT: Float?
    let photoDisplayTime: Double?
    var raw: RawCaptureRecipe? = nil
    var plan: PhotoCapturePlan? = nil
    /// Absent on legacy jobs. If present, recovery requires the frozen material payload.
    var materialSHA256: String? = nil
    /// The exact software correction/reference baked into the frozen cube, never a
    /// second WB operation during rendering. Missing on jobs from older releases.
    var colorAdjustment: ResolvedCameraColorAdjustment? = nil
    /// Freeze the renderer's smoothed gain, rather than recomputing from a later AWB reading.
    var frozenChromaticGain: SIMD3<Float>? = nil

    var requiresRawLUT: Bool { raw?.requiresRawLUT == true }

    func withPhotoDisplayTime(_ time: Double?) -> Self {
        Self(id: id, captureDate: captureDate, filterName: filterName, displayLabel: displayLabel,
            focalLength: focalLength, outputQuality: outputQuality, profile: profile, grainSeed: grainSeed,
            location: location, lutDimension: lutDimension, chromaticSceneCCT: chromaticSceneCCT,
            photoDisplayTime: time, raw: raw, plan: plan, materialSHA256: materialSHA256,
            colorAdjustment: colorAdjustment, frozenChromaticGain: frozenChromaticGain)
    }
}

struct CaptureJob: Codable, Sendable {
    var formatVersion = 1
    var recipe: CaptureRecipe
    var hasSourceMovie: Bool
    /// Optional fields keep manifests written before early still checkpointing readable.
    var awaitingCaptureCompletion: Bool?
    var pendingMovieURL: URL?
    var recoveredIncompleteCapture: Bool?
    var rendered = false
    var hasRenderedMovie = false
    var assetIdentifier: String?
    var deferredPhoto: DeferredPhotoState?

    var id: UUID { recipe.id }
}

struct CaptureRecoveryIssue: Identifiable, Hashable, Sendable {
    enum Reason: Hashable, Sendable {
        case missingManifest
        case unreadableManifest
        case unsupportedVersion
        case missingResources
        case incompleteStaging
        case discardedFiles
        case processingFailed

        var message: String {
            switch self {
            case .missingManifest: String(localized: "This photo's recovery information is missing.")
            case .unreadableManifest: String(localized: "This photo's recovery information could not be read.")
            case .unsupportedVersion: String(localized: "This photo needs a different version of the app to recover.")
            case .missingResources: String(localized: "Some files needed to recover this photo are missing.")
            case .incompleteStaging: String(localized: "This photo has not finished preparing for recovery.")
            case .discardedFiles: String(localized: "Files from a deleted photo are still kept on this device.")
            case .processingFailed: String(localized: "This photo could not finish processing or saving. You can retry or export the original.")
            }
        }
    }

    /// Directory identity also distinguishes a staging copy from its committed capture.
    let id: String
    let captureID: UUID
    let reason: Reason
    let hasOriginal: Bool
    let date: Date?
}

struct CaptureRecoveryInventory: Sendable {
    var jobs: [CaptureJob] = []
    var issues: [CaptureRecoveryIssue] = []
}

/// The manifest is the commit marker. Incomplete staging directories are retained for recovery,
/// and only a completed export/index transaction may remove a committed job.
struct CaptureJournal: Sendable {
    private struct ManifestVersion: Decodable { let formatVersion: Int }

    let root: URL
    private let storage = CaptureStorageLedger()
    enum CapacityKind: Sendable { case immediate, importantUsage }
    private let capacityReader: @Sendable (URL, CapacityKind) throws -> Int64?
    var cachedStorageBytes: Int64? { storage.bytes }
    var storageScanCount: Int { storage.scanCount }

    init(root: URL) {
        self.init(root: root, capacityReader: Self.readVolumeCapacity)
    }

    init(root: URL, capacityReader: @escaping @Sendable (URL, CapacityKind) throws -> Int64?) {
        self.root = root
        self.capacityReader = capacityReader
    }

    private static func readVolumeCapacity(at root: URL, kind: CapacityKind) throws -> Int64? {
        // A fresh URL prevents URL resource caching from reusing an earlier capacity reading.
        let volume = URL(fileURLWithPath: root.path, isDirectory: true)
        switch kind {
        case .immediate:
            return try volume.resourceValues(forKeys: [.volumeAvailableCapacityKey])
                .volumeAvailableCapacity.map(Int64.init)
        case .importantUsage:
            return try volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }
    }

    static let maximumJobs = 16
    static let maximumBytes: Int64 = 1_024 * 1_024 * 1_024

    enum JournalError: LocalizedError {
        case full
        case invalidJob
        case recoveryChanged
        case originalUnavailable

        var errorDescription: String? {
            switch self {
            case .full: String(localized: "Please wait for your photos to finish saving.")
            case .invalidJob: String(localized: "A saved photo could not be opened. Its original files have been kept.")
            case .recoveryChanged: String(localized: "This recovery item has changed. Please try again.")
            case .originalUnavailable: String(localized: "The original photo is not available to export.")
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
        try inventory().jobs
    }

    /// Files that cannot currently be processed stay visible alongside recoverable jobs.
    /// Nothing in this read-only scan repairs or removes the original capture.
    func inventory() throws -> CaptureRecoveryInventory {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return CaptureRecoveryInventory() }
        var result = CaptureRecoveryInventory()
        for directory in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = directory.lastPathComponent
            let staging = name.hasPrefix("staging-")
            let captureName = staging ? String(name.dropFirst("staging-".count)) : name
            guard let id = UUID(uuidString: captureName),
                  try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let original = directory.appendingPathComponent("original.image")
            let hasOriginal = fm.fileExists(atPath: original.path)
            let date = (try? original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate)
            func issue(_ reason: CaptureRecoveryIssue.Reason) {
                result.issues.append(CaptureRecoveryIssue(id: name, captureID: id, reason: reason, hasOriginal: hasOriginal, date: date))
            }
            if fm.fileExists(atPath: directory.appendingPathComponent("discarded").path) {
                issue(.discardedFiles)
                continue
            }
            let manifest = directory.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifest.path) else { issue(.missingManifest); continue }
            let job: CaptureJob
            do {
                let data = try Data(contentsOf: manifest)
                let version = try JSONDecoder().decode(ManifestVersion.self, from: data)
                guard version.formatVersion == 1 else { issue(.unsupportedVersion); continue }
                job = try JSONDecoder().decode(CaptureJob.self, from: data)
            } catch {
                issue(.unreadableManifest)
                Log.save.error("capture_manifest_unreadable directory=\(name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                continue
            }
            guard job.id.uuidString == captureName else { issue(.unreadableManifest); continue }
            let required = job.rendered
                ? ["rendered.image"] + (job.hasRenderedMovie ? ["rendered.mov"] : [])
                : ["original.image", "lut.bin"] + (job.recipe.requiresRawLUT ? ["raw-lut.bin"] : [])
                    + (job.recipe.materialSHA256 != nil ? ["material.bin"] : [])
                    + (job.hasSourceMovie ? ["source.mov"] : [])
            guard required.allSatisfy({ fm.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
                issue(.missingResources)
                continue
            }
            if staging { issue(.incompleteStaging) }
            else {
                result.jobs.append(job)
                if fm.fileExists(atPath: directory.appendingPathComponent("attention").path) { issue(.processingFailed) }
            }
        }
        result.jobs.sort { $0.recipe.captureDate < $1.recipe.captureDate }
        result.issues.sort { $0.id < $1.id }
        return result
    }

    func recover(excludingInFlight inFlight: Set<UUID> = []) throws -> [CaptureJob] {
        try recoverInventory(excludingInFlight: inFlight).jobs
    }

    func recoverInventory(excludingInFlight inFlight: Set<UUID> = []) throws -> CaptureRecoveryInventory {
        storage.invalidate()
        defer { _ = try? diskUsage() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return CaptureRecoveryInventory() }
        for staging in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where staging.lastPathComponent.hasPrefix("staging-") {
            guard let data = try? Data(contentsOf: staging.appendingPathComponent("manifest.json")),
                  let job = try? JSONDecoder().decode(CaptureJob.self, from: data),
                  job.formatVersion == 1,
                  staging.lastPathComponent == "staging-" + job.id.uuidString,
                  fm.fileExists(atPath: staging.appendingPathComponent("original.image").path),
                  fm.fileExists(atPath: staging.appendingPathComponent("lut.bin").path),
                  job.recipe.materialSHA256 == nil || fm.fileExists(atPath: staging.appendingPathComponent("material.bin").path),
                  !job.recipe.requiresRawLUT || fm.fileExists(atPath: staging.appendingPathComponent("raw-lut.bin").path),
                  !job.hasSourceMovie || fm.fileExists(atPath: staging.appendingPathComponent("source.mov").path),
                  !fm.fileExists(atPath: directory(for: job.id).path) else { continue }
            do { try fm.moveItem(at: staging, to: directory(for: job.id)) }
            catch {
                Log.save.error("capture_staging_recovery_deferred id=\(job.id) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        var recovered = try inventory()
        recovered.jobs = recovered.jobs.map { job in
            guard job.awaitingCaptureCompletion == true, !inFlight.contains(job.id) else { return job }
            // A previous process cannot finish this native capture. Recover its durable still,
            // and retain a movie if AVFoundation finished writing it before the process ended.
            let movie = job.pendingMovieURL.flatMap {
                fm.fileExists(atPath: $0.path) ? $0 : nil
            }
            do {
                return try completeCapture(id: job.id, photoDisplayTime: nil, movieURL: movie, recovered: true)
            } catch {
                Log.save.error("capture_checkpoint_recovery_deferred id=\(job.id) error=\(error.localizedDescription, privacy: .public)")
                // A missing/unreadable native movie should not block other recoverable jobs.
                return (try? completeCapture(id: job.id, photoDisplayTime: nil, movieURL: nil, recovered: true)) ?? job
            }
        }
        return recovered
    }

    /// Export is an exact copy, so recovery never depends on decoding or re-encoding the original.
    func exportOriginal(for issue: CaptureRecoveryIssue) throws -> URL {
        let current = try currentIssue(issue)
        guard current.hasOriginal else { throw JournalError.originalUnavailable }
        let source = root.appendingPathComponent(current.id, isDirectory: true).appendingPathComponent("original.image")
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let imageSource = CGImageSourceCreateWithData(data as CFData, nil)
        let type = imageSource.flatMap { CGImageSourceGetType($0) }
        let suffix = imageSource.map { RawFilmRenderer.isDNG($0) } == true ? "dng"
            : (type.flatMap { UTType($0 as String)?.preferredFilenameExtension } ?? "image")
        let exportDirectory = try ShareExportDirectory.application.create()
        let destination = exportDirectory.appendingPathComponent("JustShoot-Recovered-\(current.captureID.uuidString.prefix(8)).\(suffix)")
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch {
            try? FileManager.default.removeItem(at: exportDirectory)
            throw error
        }
        return destination
    }

    func discardRecoveryFiles(for issue: CaptureRecoveryIssue) throws {
        let current = try currentIssue(issue)
        defer { refreshStorageDirectory(current.id) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(current.id, isDirectory: true))
    }

    func markDiscarded(_ issue: CaptureRecoveryIssue) throws {
        let current = try currentIssue(issue)
        defer { refreshStorageDirectory(current.id) }
        try write(Data(), to: root.appendingPathComponent(current.id, isDirectory: true).appendingPathComponent("discarded"))
    }

    func markNeedsAttention(_ id: UUID) throws {
        _ = try job(for: id)
        defer { refreshStorageDirectory(id.uuidString) }
        try write(Data(), to: file("attention", for: id))
    }

    func undoDiscard(_ issue: CaptureRecoveryIssue) throws {
        let current = try currentIssue(issue)
        defer { refreshStorageDirectory(current.id) }
        let marker = root.appendingPathComponent(current.id, isDirectory: true).appendingPathComponent("discarded")
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    }

    private func currentIssue(_ issue: CaptureRecoveryIssue) throws -> CaptureRecoveryIssue {
        guard let current = try inventory().issues.first(where: { $0.id == issue.id && $0.captureID == issue.captureID }) else {
            throw JournalError.recoveryChanged
        }
        return current
    }

    func hasRoom(for bytes: Int64) throws -> Bool {
        try hasJournalRoom(for: bytes) && hasVolumeRoom(for: bytes)
    }

    func hasJournalRoom(for bytes: Int64) throws -> Bool {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try (storage.bytes ?? diskUsage()) + bytes <= Self.maximumBytes
    }

    func hasVolumeRoom(for bytes: Int64) throws -> Bool {
        let required = bytes + 128 * 1_024 * 1_024
        // Avoid asking the storage service to estimate reclaimable capacity on every shutter
        // tap. Keep that fallback for low-space volumes so purgeable space still counts.
        if let immediate = try? capacityReader(root, .immediate), immediate >= required { return true }
        let available = try capacityReader(root, .importantUsage)
        return available.map { $0 >= required } ?? true
    }

    func stage(recipe: CaptureRecipe, imageData: Data, movieURL: URL?, lut: CubeLUT, rawLUT: RawFilmLUT? = nil, reserved: Bool = false,
        awaitingCaptureCompletion: Bool = false, pendingMovieURL: URL? = nil,
        deferredPhoto: DeferredPhotoState? = nil) throws -> CaptureJob {
        guard recipe.lutDimension == lut.dimension else { throw JournalError.invalidJob }
        let materialData = try lut.material?.encoded()
        var frozenRecipe = recipe
        frozenRecipe.materialSHA256 = materialData.map(FilmMaterial.digest)
        guard recipe.materialSHA256 == nil || recipe.materialSHA256 == frozenRecipe.materialSHA256 else { throw JournalError.invalidJob }
        if let deferredPhoto {
            guard recipe.raw == nil, movieURL == nil, pendingMovieURL == nil,
                  recipe.plan?.capturesLivePhoto != true,
                  deferredPhoto.width > 0, deferredPhoto.height > 0 else { throw JournalError.invalidJob }
        }
        if let plan = recipe.plan {
            guard plan.accepts(rawRecipe: recipe.raw),
                  plan.capturesLivePhoto || (movieURL == nil && pendingMovieURL == nil) else {
                throw JournalError.invalidJob
            }
        }
        if let raw = recipe.raw {
            guard movieURL == nil, pendingMovieURL == nil,
                  let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  RawFilmRenderer.isDNG(source) else { throw JournalError.invalidJob }
            if raw.requiresRawLUT {
                guard let rawLUT else { throw JournalError.invalidJob }
                try raw.validate(lut: rawLUT)
            } else {
                guard rawLUT == nil else { throw JournalError.invalidJob }
                try raw.validate(displayLUT: lut)
            }
        } else if rawLUT != nil { throw JournalError.invalidJob }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Reservations are checked before exposure. Once accepted, persist the capture even if a
        // soft budget changes during exposure; only a real filesystem error may stop this write.
        if !reserved {
            let movieBytes = movieURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
            guard try jobs().count < Self.maximumJobs,
                  try hasRoom(for: Int64(imageData.count) + Int64(lut.data.count) + Int64(materialData?.count ?? 0) + Int64(rawLUT?.data.count ?? 0) + Int64(movieBytes)) else {
                throw JournalError.full
            }
        }

        let staging = root.appendingPathComponent("staging-\(recipe.id.uuidString)", isDirectory: true)
        defer {
            refreshStorageDirectory(staging.lastPathComponent)
            refreshStorageDirectory(recipe.id.uuidString)
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try write(imageData, to: staging.appendingPathComponent("original.image"))
        try write(lut.data, to: staging.appendingPathComponent("lut.bin"))
        if let materialData { try write(materialData, to: staging.appendingPathComponent("material.bin")) }
        if let rawLUT { try write(rawLUT.data, to: staging.appendingPathComponent("raw-lut.bin")) }
        if let movieURL {
            let destination = staging.appendingPathComponent("source.mov")
            if !fm.fileExists(atPath: destination.path) { try fm.copyItem(at: movieURL, to: destination) }
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        }
        let job = CaptureJob(recipe: frozenRecipe, hasSourceMovie: movieURL != nil,
            awaitingCaptureCompletion: awaitingCaptureCompletion ? true : nil, pendingMovieURL: pendingMovieURL,
            deferredPhoto: deferredPhoto)
        try write(JSONEncoder().encode(job), to: staging.appendingPathComponent("manifest.json"))
        try fm.moveItem(at: staging, to: directory(for: recipe.id))
        if let movieURL { try? fm.removeItem(at: movieURL) }
        return job
    }

    func job(for id: UUID) throws -> CaptureJob {
        let job = try JSONDecoder().decode(CaptureJob.self, from: Data(contentsOf: file("manifest.json", for: id)))
        guard job.formatVersion == 1, job.id == id,
              !FileManager.default.fileExists(atPath: file("discarded", for: id).path) else { throw JournalError.invalidJob }
        return job
    }

    /// Commit the movie before changing the manifest. A crash between these writes leaves a
    /// complete source.mov that recovery can discover, while the original still stays usable.
    func completeCapture(id: UUID, photoDisplayTime: Double?, movieURL: URL?, recovered: Bool = false) throws -> CaptureJob {
        var job = try job(for: id)
        defer { refreshStorageDirectory(id.uuidString) }
        guard job.awaitingCaptureCompletion == true else { return job }
        let fm = FileManager.default
        let destination = file("source.mov", for: id)
        if let movieURL, !fm.fileExists(atPath: destination.path) {
            let temporary = file("source.pending.mov", for: id)
            if fm.fileExists(atPath: temporary.path) { try fm.removeItem(at: temporary) }
            try fm.copyItem(at: movieURL, to: temporary)
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
            try fm.moveItem(at: temporary, to: destination)
        }
        job.hasSourceMovie = fm.fileExists(atPath: destination.path)
        job.recipe = job.recipe.withPhotoDisplayTime(photoDisplayTime)
        job.awaitingCaptureCompletion = nil
        job.pendingMovieURL = nil
        job.recoveredIncompleteCapture = recovered ? true : nil
        try update(job)
        if let movieURL, movieURL != destination { try? fm.removeItem(at: movieURL) }
        return job
    }

    func update(_ job: CaptureJob) throws {
        defer { refreshStorageDirectory(job.id.uuidString) }
        try write(JSONEncoder().encode(job), to: file("manifest.json", for: job.id))
    }

    func lut(for job: CaptureJob) throws -> CubeLUT {
        var lut = try CubeLUT.validated(data: Data(contentsOf: file("lut.bin", for: job.id)), dimension: job.recipe.lutDimension)
        if let expected = job.recipe.materialSHA256 {
            let url = file("material.bin", for: job.id)
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= FilmMaterial.maximumBytes else { throw JournalError.invalidJob }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard FilmMaterial.digest(data) == expected else { throw JournalError.invalidJob }
            lut.material = try FilmMaterial.decode(data)
        }
        return lut
    }

    func rawLUT(for job: CaptureJob) throws -> RawFilmLUT? {
        guard let raw = job.recipe.raw, raw.requiresRawLUT else { return nil }
        let lut = try RawFilmLUT(data: Data(contentsOf: file("raw-lut.bin", for: job.id), options: .mappedIfSafe))
        try raw.validate(lut: lut)
        return lut
    }

    func writeRenderedImage(_ data: Data, for id: UUID) throws {
        defer { refreshStorageDirectory(id.uuidString) }
        try write(data, to: file("rendered.image", for: id))
    }

    func finalizeDeferredPhoto(_ data: Data, for id: UUID) throws -> CaptureJob {
        defer { refreshStorageDirectory(id.uuidString) }
        var job = try job(for: id)
        guard var deferred = job.deferredPhoto, deferred.assetIdentifier != nil,
              deferred.acceptsFinalImage(data) else { throw JournalError.invalidJob }
        // Commit bytes first. A crash before the manifest update simply re-reads Photos.
        try write(data, to: file("original.image", for: id))
        deferred.finalized = true
        job.deferredPhoto = deferred
        try update(job)
        return job
    }

    func markDiscarded(_ id: UUID) throws {
        defer { refreshStorageDirectory(id.uuidString) }
        try write(Data(), to: file("discarded", for: id))
    }

    func undoDiscard(_ id: UUID) throws {
        defer { refreshStorageDirectory(id.uuidString) }
        let marker = file("discarded", for: id)
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    }

    func finish(_ id: UUID) throws {
        defer { refreshStorageDirectory(id.uuidString) }
        try FileManager.default.removeItem(at: directory(for: id))
    }

    func diskUsage() throws -> Int64 {
        var directories: [String: Int64] = [:]
        if FileManager.default.fileExists(atPath: root.path) {
            let children = try FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
            for child in children {
                directories[child.lastPathComponent] = try Self.bytes(at: child)
            }
        }
        storage.reconcile(directories)
        return directories.values.reduce(0, +)
    }

    private func refreshStorageDirectory(_ name: String) {
        guard storage.bytes != nil else { return }
        do { storage.replace(directory: name, bytes: try Self.bytes(at: root.appendingPathComponent(name))) }
        catch { storage.invalidate() }
    }

    private static func bytes(at url: URL) throws -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        let rootValues = try url.resourceValues(forKeys: keys)
        if rootValues.isRegularFile == true { return Int64(rootValues.fileSize ?? 0) }
        var failure: (any Error)?
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
            failure = error
            return false
        }) else { throw JournalError.invalidJob }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: keys)
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        if let failure { throw failure }
        return total
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
