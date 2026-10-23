import Foundation

/// The one place glovebox writes files an agent names. Text on screen can steer
/// an agent, so its paths are untrusted: files go only under the temporary
/// folders, never over an existing file, with symlinks resolved first.
enum CapturePath {
    /// Folders a capture may be written under, symlinks resolved: this
    /// process's temp folder, the user's (in case TMPDIR points elsewhere),
    /// and /tmp.
    static var allowedRoots: [String] {
        var folder = [CChar](repeating: 0, count: Int(PATH_MAX))
        let userTemp = confstr(_CS_DARWIN_USER_TEMP_DIR, &folder, folder.count) > 0
            ? String(decoding: folder.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        return ([NSTemporaryDirectory(), "/tmp"] + (userTemp.map { [$0] } ?? [])).map(resolved)
    }

    /// The real path for writing `path`, or an error saying why it is refused.
    static func confine(_ path: String) throws -> String {
        guard path.hasPrefix("/") else {
            throw ToolError("Capture paths must be absolute, under \(NSTemporaryDirectory()) or /tmp.")
        }
        let url = URL(fileURLWithPath: path)
        let directory = resolved(url.deletingLastPathComponent().path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError("No folder at \(url.deletingLastPathComponent().path) to write the capture into.")
        }
        guard allowedRoots.contains(where: { directory == $0 || directory.hasPrefix($0 + "/") }) else {
            throw ToolError("Captures are written only under \(NSTemporaryDirectory()) or /tmp, not \(directory).")
        }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw ToolError("\(path) does not name a file.")
        }
        let target = directory + "/" + name
        // lstat, so a dangling symlink counts as existing too.
        var info = stat()
        guard lstat(target, &info) != 0 else {
            throw ToolError("\(target) already exists; captures never overwrite a file. Pick a new name.")
        }
        return target
    }

    /// Writes `data` to the confined `path`, failing if the file appeared
    /// meanwhile. `target` has no symlinks, and O_NOFOLLOW_ANY refuses one
    /// swapped into any part of it since: in /tmp, other users can do that.
    static func write(_ data: Data, to path: String) throws -> String {
        let target = try confine(path)
        let fd = open(target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY, 0o644)
        guard fd >= 0 else {
            throw ToolError("Could not create \(target): \(String(cString: strerror(errno))).")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        return target
    }

    /// `path` with every symlink resolved (realpath; NSString's version
    /// strips a leading /private, which would let /tmp checks drift).
    private static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }
}
