import Foundation

/// The APP_SANDBOX_GROUP_ID that QEMU gets. UTM's virglrenderer
/// (anon_file.c) names Venus blob memory "<group>/<slot><nonce>" and creates
/// it with shm_open(); IDSharedMemoryFallback turns refused calls into files.
enum ShmGroup {
    /// anon_file.c refuses longer group names before it calls shm_open
    /// ("APP_SANDBOX_GROUP_ID is 30 chars, at most 28 fit"), so the stand-in
    /// never sees the call. POSIX shared memory names are at most 31 bytes.
    static let maxLength = 28

    /// Used with the file fallback. No signature contains it, so every
    /// shm_open under it is refused (EPERM) and the stand-in opens a file.
    static let fallback = "group.ideck"

    /// `usable`: the app group under which the shm_open probe worked, if any.
    /// Device run of build 30 (iloader, paid team): the profile's group was
    /// group.com.ideck.app.<team ID>, 30 characters; passing it made every
    /// Venus blob allocation fail, so Linux saw no Vulkan device.
    static func forQEMU(usable: String?, fileFallback: Bool) -> String? {
        if let usable, !usable.isEmpty, usable.count <= maxLength { return usable }
        return fileFallback ? fallback : nil
    }
}
