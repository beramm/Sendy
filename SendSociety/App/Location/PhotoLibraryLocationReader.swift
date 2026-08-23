#if os(iOS)
import Foundation
import SwiftUI
import Photos
import PhotosUI

/// The location of a picked video, read from the Photos database rather than
/// from the file.
///
/// **`PHPicker` strips location from the file it exports**, so the import path
/// gets a coordinate only through here — and only with library authorization,
/// which is a second permission prompt on top of the camera's.
///
/// It is therefore asked **last**, and only when the file itself carried
/// nothing. A clip that already has a coordinate — recorded by this app, or
/// filmed on a camera that writes one — never triggers the prompt. That
/// ordering is the whole reason this is a separate type rather than a branch
/// inside the importer.
enum PhotoLibraryLocationReader {

    static func coordinate(for item: PhotosPickerItem) async -> Coordinate2D? {
        // Nil when the picker ran without library access, which is the default.
        guard let identifier = item.itemIdentifier else { return nil }
        guard await isAuthorized() else { return nil }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let location = assets.firstObject?.location else { return nil }
        return Coordinate2D(
            latitudeDegrees: location.coordinate.latitude,
            longitudeDegrees: location.coordinate.longitude
        )
    }

    /// Asks once. A denial is permanent as far as this app is concerned — iOS
    /// will not re-prompt, and pestering the user through a Settings deep link
    /// to improve a *session name* is not a trade worth making.
    private static func isAuthorized() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return status == .authorized || status == .limited
        default:
            return false
        }
    }
}
#endif
