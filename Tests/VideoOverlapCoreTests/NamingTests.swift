import Testing
import Foundation
@testable import VideoOverlapCore

// Task 12 — session naming from place.
//
// The rule these tests exist to defend is **cache, then network, then date**.
// Network-first would work perfectly on a desk and fail on almost every real
// visit, because gyms are windowless warehouses — so the ordering cannot be
// checked by using the app, and has to be checked here.

/// Counts calls, so "did not touch the network" is an assertion rather than an
/// assumption.
private actor CountingGeocoder: ReverseGeocoder {
    private(set) var calls = 0
    private let result: String?

    init(returning result: String?) { self.result = result }

    func placeName(for coordinate: Coordinate2D) async -> String? {
        calls += 1
        return result
    }

    func callCount() -> Int { calls }
}

private let rockIsland = Coordinate2D(latitudeDegrees: 51.5074, longitudeDegrees: -0.1278)
/// ~90 m away: the spread of two GPS fixes taken at the same building.
private let rockIslandCarPark = Coordinate2D(latitudeDegrees: 51.5082, longitudeDegrees: -0.1278)
/// ~1.4 km away: a different place by any measure.
private let otherGym = Coordinate2D(latitudeDegrees: 51.5200, longitudeDegrees: -0.1278)

@Suite("Session naming")
struct NamingTests {

    // MARK: Ordering

    @Test("A known gym is named without touching the network")
    func cacheBeatsNetwork() async {
        let geocoder = CountingGeocoder(returning: "Should Never Be Asked")
        let namer = SessionNamer(geocoder: geocoder)
        var book = PlacemarkBook()
        book.remember(name: "Rock Island", at: rockIsland, confirmedByUser: true)

        let resolution = await namer.resolve(coordinate: rockIslandCarPark, capturedAt: .now, book: book)

        #expect(resolution.name.name == "Climb at Rock Island")
        #expect(resolution.name.source == .cache)
        #expect(resolution.updatedBook == nil)
        #expect(await geocoder.callCount() == 0)
    }

    @Test("A new gym is geocoded once, then never again")
    func geocodesOnlyOnCacheMiss() async {
        let geocoder = CountingGeocoder(returning: "Rock Island")
        let namer = SessionNamer(geocoder: geocoder)

        let first = await namer.resolve(coordinate: rockIsland, capturedAt: .now, book: PlacemarkBook())
        #expect(first.name.source == .network)
        #expect(first.name.name == "Climb at Rock Island")
        #expect(await geocoder.callCount() == 1)

        // The second visit is the one that matters: same gym, different fix.
        let book = try! #require(first.updatedBook)
        let second = await namer.resolve(coordinate: rockIslandCarPark, capturedAt: .now, book: book)
        #expect(second.name.source == .cache)
        #expect(await geocoder.callCount() == 1)
    }

    @Test("A genuinely different place is not served the cached name")
    func radiusSeparatesPlaces() async {
        let geocoder = CountingGeocoder(returning: "Somewhere Else")
        let namer = SessionNamer(geocoder: geocoder)
        var book = PlacemarkBook()
        book.remember(name: "Rock Island", at: rockIsland, confirmedByUser: true)

        let resolution = await namer.resolve(coordinate: otherGym, capturedAt: .now, book: book)

        #expect(resolution.name.name == "Climb at Somewhere Else")
        #expect(resolution.name.source == .network)
        #expect(await geocoder.callCount() == 1)
        #expect(resolution.updatedBook?.entries.count == 2)
    }

    // MARK: The offline case, which is the normal one

    @Test("No coordinate means a date name and no lookup")
    func noCoordinateNamesByDate() async {
        let geocoder = CountingGeocoder(returning: "Rock Island")
        let namer = SessionNamer(geocoder: geocoder)

        let resolution = await namer.resolve(coordinate: nil, capturedAt: .now, book: PlacemarkBook())

        #expect(resolution.name.source == .date)
        #expect(await geocoder.callCount() == 0)
    }

    @Test("An unreachable geocoder falls through to the date, leaving no entry")
    func offlineFallsThroughToDate() async {
        let namer = SessionNamer(geocoder: CountingGeocoder(returning: nil))

        let resolution = await namer.resolve(coordinate: rockIsland, capturedAt: .now, book: PlacemarkBook())

        #expect(resolution.name.source == .date)
        // Nothing learned, so the next visit with signal still resolves.
        #expect(resolution.updatedBook == nil)
    }

    @Test("No geocoder at all behaves exactly like being offline")
    func noGeocoderIsNotAnError() async {
        let namer = SessionNamer(geocoder: nil)
        let resolution = await namer.resolve(coordinate: rockIsland, capturedAt: .now, book: PlacemarkBook())
        #expect(resolution.name.source == .date)
    }

    @Test("The date name is locale-formatted, not dd/MM/yyyy")
    func dateNameIsNotHardcoded() {
        let name = SessionNamer.dateName(Date(timeIntervalSince1970: 1_787_000_000)).name
        // A hardcoded numeric format is the specific regression being guarded:
        // it reads as the wrong month in the United States and as nonsense in
        // ISO-ordered locales.
        #expect(!name.contains("/"))
        #expect(name.hasPrefix("Climb on "))
    }

    // MARK: The book

    @Test("A user's name is never overwritten by a geocode")
    func userNameWins() {
        var book = PlacemarkBook()
        book.remember(name: "Rock Island", at: rockIsland, confirmedByUser: true)
        book.remember(name: "12 Industrial Way", at: rockIslandCarPark, confirmedByUser: false)

        #expect(book.entries.count == 1)
        #expect(book.entries[0].name == "Rock Island")
    }

    @Test("A correction replaces a geocoded name and sticks")
    func correctionReseedsTheEntry() {
        var book = PlacemarkBook()
        book.remember(name: "12 Industrial Way", at: rockIsland, confirmedByUser: false)
        book.remember(name: "Rock Island", at: rockIslandCarPark, confirmedByUser: true)

        #expect(book.entries.count == 1)
        #expect(book.entries[0].name == "Rock Island")
        #expect(book.entries[0].confirmedByUser)
    }

    @Test("Repeat visits fold into one entry rather than piling up")
    func repeatVisitsDoNotAccumulate() {
        var book = PlacemarkBook()
        for _ in 0..<5 {
            book.remember(name: "Rock Island", at: rockIslandCarPark, confirmedByUser: false)
        }
        #expect(book.entries.count == 1)
    }

    @Test("An implausible coordinate is not learned")
    func rejectsNonsense() {
        var book = PlacemarkBook()
        book.remember(
            name: "Nowhere",
            at: Coordinate2D(latitudeDegrees: 5130.44, longitudeDegrees: -7.66),
            confirmedByUser: true
        )
        #expect(book.entries.isEmpty)
    }

    @Test("The book round-trips through JSON")
    func bookRoundTrips() throws {
        var book = PlacemarkBook()
        book.remember(name: "Rock Island", at: rockIsland, confirmedByUser: true)
        let data = try JSONEncoder().encode(book)
        let decoded = try JSONDecoder().decode(PlacemarkBook.self, from: data)
        #expect(decoded.nearest(to: rockIslandCarPark)?.name == "Rock Island")
    }

    @Test("A renamed session re-seeds the book without doubling the prefix")
    func renameStripsThePrefix() {
        // Typing over "Climb at 12 Industrial Way" is the expected correction
        // gesture, so the whole displayed string comes back — prefix included.
        #expect(SessionNamer.placeComponent(of: "Climb at Rock Island") == "Rock Island")
        #expect(SessionNamer.placeComponent(of: "Rock Island") == "Rock Island")
        #expect(SessionNamer.placeName(SessionNamer.placeComponent(of: "Climb at Rock Island"))
            == "Climb at Rock Island")
    }

    // MARK: Distance

    @Test("Haversine agrees with a known separation")
    func distanceIsSane() {
        // One degree of latitude is ~111.2 km anywhere on the sphere.
        let a = Coordinate2D(latitudeDegrees: 51.0, longitudeDegrees: 0)
        let b = Coordinate2D(latitudeDegrees: 52.0, longitudeDegrees: 0)
        #expect(abs(a.distanceMeters(to: b) - 111_195) < 500)
        #expect(a.distanceMeters(to: a) == 0)
    }

    // MARK: ISO 6709

    @Test("ISO 6709 decimal-degree strings parse")
    func parsesISO6709() {
        #expect(ISO6709.parse("+51.5074-000.1278+015.000/")
            .map { abs($0.latitudeDegrees - 51.5074) < 1e-6 && abs($0.longitudeDegrees + 0.1278) < 1e-6 } == true)
        #expect(ISO6709.parse("+51.5074-000.1278/") != nil)
        #expect(ISO6709.parse("-33.8688+151.2093/") != nil)
    }

    @Test("The degrees-and-minutes form is rejected, not silently misread")
    func rejectsDegreesMinutes() {
        // +5130.44 is 51°30.44', not 5130 degrees. Parsing it as decimal would
        // put the gym in the North Sea with no warning at all.
        #expect(ISO6709.parse("+5130.44-00007.66/") == nil)
        #expect(ISO6709.parse("") == nil)
        #expect(ISO6709.parse("not a coordinate") == nil)
    }

    @Test("Writing then reading a coordinate is lossless enough to match a gym")
    func iso6709RoundTrips() {
        let written = ISO6709.string(for: rockIsland, altitudeMeters: 15)
        let read = try! #require(ISO6709.parse(written))
        #expect(read.distanceMeters(to: rockIsland) < 1)
    }

    // MARK: Session model

    @Test("A session carries its coordinate through JSON")
    func sessionRoundTripsCoordinate() throws {
        let session = ClimbSession(
            name: "Climb at Rock Island",
            coordinate: rockIsland,
            nameSource: .network
        )
        let decoded = try JSONDecoder().decode(ClimbSession.self, from: JSONEncoder().encode(session))
        #expect(decoded.coordinate == rockIsland)
        #expect(decoded.nameSource == .network)
        #expect(!decoded.hasUserName)
    }

    @Test("Sessions written before naming existed keep their names")
    func legacySessionsAreTreatedAsUserNamed() throws {
        // The failure this prevents is a silent mass rename on upgrade: every
        // old session re-resolving and coming back as a date.
        let session = ClimbSession(name: "Blue V4 overhang")
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(session)
        ) as! [String: Any]
        object.removeValue(forKey: "nameSource")
        object.removeValue(forKey: "coordinate")

        let decoded = try JSONDecoder().decode(
            ClimbSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.name == "Blue V4 overhang")
        #expect(decoded.hasUserName)
        #expect(decoded.coordinate == nil)
    }
}
