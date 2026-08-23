#if os(iOS)
import Foundation
import CoreLocation

/// A single coarse fix at the moment of recording, so the clip this app records
/// carries a location — `AVCaptureMovieFileOutput` writes none by itself.
///
/// Built for the case that actually happens: **indoors, with no fix**. Two
/// things follow from that.
///
/// - `desiredAccuracy` is a hundred metres. A gym is matched within two
///   hundred, so a better fix would only cost time and battery for precision
///   nothing reads.
/// - A live fix is raced against a short timeout, and a timeout falls back to
///   the manager's **last known** location. In a windowless warehouse the live
///   request will never return, and the last fix — taken in the car park on the
///   way in — is exactly the coordinate wanted. This is the mechanism that
///   turns one lucky fix into a permanent gym name.
@MainActor
final class CaptureLocationProvider: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private var fixContinuations: [CheckedContinuation<Coordinate2D?, Never>] = []
    private var authorizationContinuations: [CheckedContinuation<CLAuthorizationStatus, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Whether a fix is even worth asking for. Used by the capture screen to
    /// say what it will and will not know, rather than silently doing nothing.
    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    var isDenied: Bool {
        manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    /// Best available coordinate, or nil. **Nil is an ordinary outcome** —
    /// denied permission, no signal and no previous fix all land here, and all
    /// of them mean the session gets a date name.
    func currentCoordinate(timeout: Duration = .seconds(3)) async -> Coordinate2D? {
        let status = await authorizationStatus()
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }

        if let fix = await liveFix(timeout: timeout) { return fix }
        // The indoor path: no live fix, but the walk in from the car park left
        // one behind.
        return manager.location.map(Self.coordinate)
    }

    // MARK: Authorization

    private func authorizationStatus() async -> CLAuthorizationStatus {
        let current = manager.authorizationStatus
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            authorizationContinuations.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined else { return }
            let waiting = self.authorizationContinuations
            self.authorizationContinuations = []
            for continuation in waiting { continuation.resume(returning: status) }
        }
    }

    // MARK: Fix

    /// One `requestLocation`, with a deadline.
    ///
    /// The deadline is not a nicety. Indoors the delegate never fires at all,
    /// so without it the caller waits for ever on a fix that is not coming —
    /// and every path here funnels through `releaseWaiters`, which drains the
    /// array, so whichever of the two arrives first resumes the continuation
    /// and the other finds nothing left to do.
    private func liveFix(timeout: Duration) async -> Coordinate2D? {
        let deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.releaseWaiters(with: nil)
        }
        defer { deadline.cancel() }
        return await withCheckedContinuation { continuation in
            fixContinuations.append(continuation)
            manager.requestLocation()
        }
    }

    private func releaseWaiters(with coordinate: Coordinate2D?) {
        let waiting = fixContinuations
        fixContinuations = []
        for continuation in waiting { continuation.resume(returning: coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Converted here, before crossing actors: `Coordinate2D` is `Sendable`
        // and `CLLocation` is a reference type from a framework that predates
        // the concept.
        let coordinate = locations.last.map(Self.coordinate)
        Task { @MainActor in self.releaseWaiters(with: coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.releaseWaiters(with: nil) }
    }

    nonisolated private static func coordinate(_ location: CLLocation) -> Coordinate2D {
        Coordinate2D(
            latitudeDegrees: location.coordinate.latitude,
            longitudeDegrees: location.coordinate.longitude
        )
    }
}
#endif
