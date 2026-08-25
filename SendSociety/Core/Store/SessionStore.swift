import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// On-disk layout for one session:
///
/// ```
/// Sessions/<session-uuid>/
///   session.json
///   processed.json                 ← the completed analytics/result cache
///   videos/<video-uuid>.mov
///   poses/<video-uuid>.json      ← the pose cache
///   plates/<video-uuid>-<key>.png ← the wall backdrop
/// ```
///
/// Sessions are one-off — there is no library and no cross-session
/// persistence — but they are written to disk anyway, because reprocessing a
/// saved session with different thresholds is the whole point of the tuning
/// loop and it must never re-run pose extraction.
public actor SessionStore {

    public enum StoreError: Error, LocalizedError {
        case notFound
        case ioFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notFound: "Session not found."
            case .ioFailed(let s): "Storage error: \(s)"
            }
        }
    }

    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? URL.temporaryDirectory
            self.root = base.appendingPathComponent("VideoOverlapSessions", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func videoURL(session: ClimbSession, video: VideoRef) -> URL {
        directory(for: session.id).appendingPathComponent("videos", isDirectory: true)
            .appendingPathComponent(video.filename)
    }

    /// **Keyed by pose source as well as by video.**
    ///
    /// Without the source in the filename, switching pose model would load the
    /// other model's cached pose — and because "reprocessing never re-runs
    /// Vision" is a deliberate guarantee, that stale read is the *designed*
    /// behaviour rather than an obvious bug. You would compare a tracker against
    /// itself, see no difference, and conclude the models are equivalent.
    func poseURL(session: ClimbSession, video: VideoRef, source: PoseSource) -> URL {
        directory(for: session.id).appendingPathComponent("poses", isDirectory: true)
            .appendingPathComponent("\(video.id.uuidString)-\(source.rawValue).json")
    }

    /// **Keyed by the plate's own tuning fields, not by the whole config.**
    ///
    /// The plate depends on the video, the sample count, the mask padding and
    /// the output size — and on nothing else in `TuningConfig`. Keying on the
    /// whole config would rebuild it every time a contact threshold moved,
    /// which is most of what the tuning loop does; keying on the video alone
    /// would silently serve a stale plate after the padding was raised to cover
    /// a climber's hands.
    func platePrefix(video: VideoRef) -> String { video.id.uuidString }

    func plateKey(config: TuningConfig) -> String {
        "s\(config.wallPlateSampleCount)-p\(Int((config.wallPlateMaskPadding * 1000).rounded()))-d\(config.wallPlateMaxDimension)"
    }

    func plateURL(session: ClimbSession, video: VideoRef, config: TuningConfig, extension ext: String) -> URL {
        directory(for: session.id).appendingPathComponent("plates", isDirectory: true)
            .appendingPathComponent("\(platePrefix(video: video))-\(plateKey(config: config)).\(ext)")
    }

    // MARK: Sessions

    /// Creates the working directory for an unsaved climb. It deliberately
    /// does not write `session.json`, so `listSessions()` cannot expose a climb
    /// before the user confirms its title and grade in Results.
    public func createDraft(name: String) throws -> ClimbSession {
        let session = ClimbSession(name: name)
        let dir = directory(for: session.id)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("videos"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("poses"),
            withIntermediateDirectories: true
        )
        return session
    }

    public func create(name: String) throws -> ClimbSession {
        let session = try createDraft(name: name)
        try save(session)
        return session
    }

    public func save(_ session: ClimbSession) throws {
        let dir = directory(for: session.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(session)
        try data.write(to: dir.appendingPathComponent("session.json"), options: .atomic)
    }

    public func load(id: UUID) throws -> ClimbSession {
        let url = directory(for: id).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url) else { throw StoreError.notFound }
        return try JSONDecoder().decode(ClimbSession.self, from: data)
    }

    public func listSessions() -> [ClimbSession] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return contents.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")) else { return nil }
            return try? JSONDecoder().decode(ClimbSession.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    // MARK: Completed result cache

    private func processedURL(session: ClimbSession) -> URL {
        directory(for: session.id).appendingPathComponent("processed.json")
    }

    /// Saves the complete result except for the wall-plate bitmap, which
    /// already has its own keyed PNG cache. Non-finite alignment diagnostics
    /// are represented as strings so a failed registration remains cacheable.
    public func cacheProcessed(_ processed: ProcessedSession, session: ClimbSession) throws {
        let url = processedURL(session: session)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        try encoder.encode(processed).write(to: url, options: .atomic)
    }

    /// Restores a saved result without running pose extraction, metrics, or an
    /// analysis provider. The current session metadata wins over the copy in
    /// the cache so later title/grade edits cannot go stale.
    public func cachedProcessed(session: ClimbSession) -> ProcessedSession? {
        let url = processedURL(session: session)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        guard var processed = try? decoder.decode(ProcessedSession.self, from: data) else {
            return nil
        }
        processed.session = session
        if let reference = session.reference {
            processed.wallPlate = cachedPlate(
                session: session,
                video: reference,
                config: processed.config
            )
        }
        return processed
    }

    public func removeCachedProcessed(session: ClimbSession) {
        try? FileManager.default.removeItem(at: processedURL(session: session))
    }

    /// Copies a video into the session directory and returns its ref.
    public func importVideo(from source: URL, into session: ClimbSession, role: VideoRef.Role, label: String) throws -> VideoRef {
        let id = UUID()
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let ref = VideoRef(id: id, filename: "\(id.uuidString).\(ext)", role: role, label: label)
        let destination = videoURL(session: session, video: ref)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        // Copy rather than reference: a Photos asset URL is not stable, and a
        // session that loses its video is a session that can never be
        // reprocessed.
        try FileManager.default.copyItem(at: source, to: destination)
        return ref
    }

    /// Deletes a video **and every pose file derived from it**. Leaving the
    /// pose cache behind would orphan a JSON blob per source that nothing can
    /// ever read again, and the cache is keyed by video id, so a later video
    /// cannot collide with it either — it would just sit there.
    public func removeVideo(session: ClimbSession, video: VideoRef) {
        try? FileManager.default.removeItem(at: videoURL(session: session, video: video))
        for source in PoseSource.allCases {
            try? FileManager.default.removeItem(at: poseURL(session: session, video: video, source: source))
        }
        // Plates are keyed by tuning as well as by video, so there may be
        // several. Sweep the directory by prefix rather than guessing keys.
        let plates = directory(for: session.id).appendingPathComponent("plates", isDirectory: true)
        let prefix = platePrefix(video: video)
        let contents = (try? FileManager.default.contentsOfDirectory(at: plates, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Pose cache (task 1.2c / 4.8)

    /// Cached pose for a video, or `nil`. **A results screen must never run
    /// Vision**, so every read path goes through here first.
    public func cachedPose(session: ClimbSession, video: VideoRef, source: PoseSource) -> PoseSequence? {
        let url = poseURL(session: session, video: video, source: source)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PoseSequence.self, from: data)
    }

    public func cachePose(_ sequence: PoseSequence, session: ClimbSession, video: VideoRef, source: PoseSource) throws {
        let url = poseURL(session: session, video: video, source: source)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(sequence)
        try data.write(to: url, options: .atomic)
    }

    public func hasCachedPose(session: ClimbSession, video: VideoRef, source: PoseSource) -> Bool {
        FileManager.default.fileExists(atPath: poseURL(session: session, video: video, source: source).path)
    }

    /// Which sources already have pose cached for every video in a session, so
    /// the picker can say which switches are instant and which mean waiting.
    public func cachedSources(session: ClimbSession) -> Set<PoseSource> {
        var out: Set<PoseSource> = []
        for source in PoseSource.allCases {
            let videos = session.allVideos
            if !videos.isEmpty, videos.allSatisfy({ hasCachedPose(session: session, video: $0, source: source) }) {
                out.insert(source)
            }
        }
        return out
    }

    // MARK: Wall backdrop cache (task 10.3)

    /// Sidecar for the plate PNG. The coverage figure has to survive a cache
    /// hit — a stage that reports "97% covered" on the first run and nothing on
    /// the second is a harness you cannot read.
    struct PlateRecord: Codable, Sendable {
        var coverage: Double
        var sampleCount: Int
        var warnings: [String]
    }

    public func cachedPlate(session: ClimbSession, video: VideoRef, config: TuningConfig) -> WallPlate? {
        let imageURL = plateURL(session: session, video: video, config: config, extension: "png")
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let recordURL = plateURL(session: session, video: video, config: config, extension: "json")
        let record = (try? Data(contentsOf: recordURL)).flatMap { try? JSONDecoder().decode(PlateRecord.self, from: $0) }
        return WallPlate(
            image: image,
            coverage: record?.coverage ?? 1,
            sampleCount: record?.sampleCount ?? 0,
            warnings: record?.warnings ?? []
        )
    }

    public func cachePlate(_ plate: WallPlate, session: ClimbSession, video: VideoRef, config: TuningConfig) throws {
        let imageURL = plateURL(session: session, video: video, config: config, extension: "png")
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw StoreError.ioFailed("Could not write the wall backdrop.")
        }
        CGImageDestinationAddImage(destination, plate.image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StoreError.ioFailed("Could not encode the wall backdrop.")
        }
        let record = PlateRecord(coverage: plate.coverage, sampleCount: plate.sampleCount, warnings: plate.warnings)
        try JSONEncoder().encode(record).write(
            to: plateURL(session: session, video: video, config: config, extension: "json"), options: .atomic
        )
    }

    public func hasCachedPlate(session: ClimbSession, video: VideoRef, config: TuningConfig) -> Bool {
        FileManager.default.fileExists(atPath: plateURL(session: session, video: video, config: config, extension: "png").path)
    }

    // MARK: Placemark book (task 12.3)

    /// **Not per session.** The whole point of the cache is that a gym is
    /// resolved once and every later session there is offline, so it lives at
    /// the store root alongside the saved configs.
    var placemarksURL: URL { root.appendingPathComponent("placemarks.json") }

    public func placemarks() -> PlacemarkBook {
        guard let data = try? Data(contentsOf: placemarksURL) else { return PlacemarkBook() }
        return (try? JSONDecoder().decode(PlacemarkBook.self, from: data)) ?? PlacemarkBook()
    }

    public func savePlacemarks(_ book: PlacemarkBook) throws {
        try JSONEncoder().encode(book).write(to: placemarksURL, options: .atomic)
    }

    /// Records a name against a coordinate. Used by the geocode path and by
    /// renaming — the second is what makes a corrected name stick for the next
    /// visit, so `confirmedByUser` is the difference that matters.
    public func rememberPlacemark(name: String, at coordinate: Coordinate2D, confirmedByUser: Bool) {
        var book = placemarks()
        book.remember(name: name, at: coordinate, confirmedByUser: confirmedByUser)
        try? savePlacemarks(book)
    }

    // MARK: Saved tuning configs

    var configsURL: URL { root.appendingPathComponent("configs.json") }

    public func savedConfigs() -> [NamedTuningConfig] {
        guard let data = try? Data(contentsOf: configsURL) else { return [] }
        return (try? JSONDecoder().decode([NamedTuningConfig].self, from: data)) ?? []
    }

    public func saveConfig(_ config: NamedTuningConfig) throws {
        var all = savedConfigs().filter { $0.id != config.id }
        all.append(config)
        try JSONEncoder().encode(all).write(to: configsURL, options: .atomic)
    }

    public func deleteConfig(id: UUID) throws {
        let all = savedConfigs().filter { $0.id != id }
        try JSONEncoder().encode(all).write(to: configsURL, options: .atomic)
    }
}
