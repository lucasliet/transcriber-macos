import Foundation

#if os(Linux)
/// Searches for an executable in common system paths
/// - Parameter name: The name of the executable to find
/// - Returns: URL to the executable if found, nil otherwise
public func findExecutable(_ name: String) -> URL? {
    let paths = ["/usr/bin", "/usr/local/bin", "/bin"]
    for path in paths {
        let url = URL(fileURLWithPath: path).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
    }
    return nil
}
#endif
