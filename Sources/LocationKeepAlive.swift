import CoreLocation

/// Second keep-alive layer: continuous (coarse) location updates keep the process scheduled in the
/// background even when the audio session is interrupted (call, Siri, another non-mixable app).
/// Costs almost nothing at 3 km accuracy; iOS shows the location indicator while it runs.
final class LocationKeepAlive: NSObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    private var wanted = false

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        mgr.distanceFilter = 1000
        mgr.pausesLocationUpdatesAutomatically = false
        mgr.showsBackgroundLocationIndicator = false
    }

    func start() {
        wanted = true
        StatusProbe.shared.setLocation(mgr.authorizationStatus)
        switch mgr.authorizationStatus {
        case .notDetermined: mgr.requestAlwaysAuthorization()
        default: begin()
        }
    }

    func stop() {
        wanted = false
        mgr.stopUpdatingLocation()
        Diag.log("location: stopped")
    }

    private func begin() {
        StatusProbe.shared.setLocation(mgr.authorizationStatus)
        guard wanted else { return }
        let st = mgr.authorizationStatus
        guard st == .authorizedAlways || st == .authorizedWhenInUse else { Diag.log("location: not authorized (\(st.rawValue))"); return }
        mgr.allowsBackgroundLocationUpdates = true
        mgr.startUpdatingLocation()
        Diag.log("location: updating (auth \(st.rawValue))")
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { begin() }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) { Diag.log("location: error \(e.localizedDescription)") }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {}
}
