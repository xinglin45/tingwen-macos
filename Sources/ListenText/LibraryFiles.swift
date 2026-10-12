import Foundation

enum LibraryFiles {
    static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenText", isDirectory: true).appendingPathComponent("library.json")
    }

    static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    static func identity(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }

    static func bookmark(_ url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                              includingResourceValuesForKeys: nil, relativeTo: nil)) ??
        (try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    static func resolve(bookmark: Data?, path: String) -> URL {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
        }
        return URL(fileURLWithPath: path)
    }
}
