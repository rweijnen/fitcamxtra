import Foundation

/// Which clips have already been copied to Photos, per camera.
///
/// Saving an 80 MB clip over the camera's wifi takes minutes, and the app gave
/// no sign afterwards which ones had been done — so the only way to be sure was
/// to save it again and wait again. A clip is immutable and uniquely named, so
/// once it is in Photos it stays saved.
///
/// This records what the app did, not what is in Photos: someone who deletes a
/// clip from their album will still see it marked here. That is the honest
/// limit of it — the app has add-only access and cannot read the library back.
enum SavedFileStore {
    private static func key(for cameraID: String) -> String {
        "saved-files-\(cameraID)"
    }

    static func load(cameraID: String) -> Set<String> {
        let stored = UserDefaults.standard.stringArray(forKey: key(for: cameraID)) ?? []
        return Set(stored)
    }

    static func save(_ ids: Set<String>, cameraID: String) {
        UserDefaults.standard.set(Array(ids), forKey: key(for: cameraID))
    }

    static func clear(cameraID: String) {
        UserDefaults.standard.removeObject(forKey: key(for: cameraID))
    }
}
