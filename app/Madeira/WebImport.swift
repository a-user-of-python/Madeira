import SwiftUI
import Foundation

// MARK: - Web server file import
//
// "Import from Web" in the game loader: point the app at a web server on
// your own network (for example `python3 -m http.server 8000` in a folder
// of game files on your Mac), browse what it serves, and download straight
// into the Wine prefix's C:\Games folder. Zip and .tar.gz archives are
// extracted automatically; every downloaded .exe then shows up under
// "Downloaded games" with a Run button that launches it through the
// normal Wine sequence.
//
// Server listing: the app first tries <server>/index.json:
//     [ {"name":"My Game.zip", "path":"games/mygame.zip", "size":1234567890}, ... ]
// ("path" may be relative to the server root or a full URL; "size" is
// optional.) If that fails it falls back to parsing a plain HTML directory
// listing, which is what `python3 -m http.server` produces.
//
// Network note: Info.plist sets NSAllowsLocalNetworking so plain-HTTP works
// against a server on your own Wi-Fi/LAN (e.g. the python one-liner above).
// ATS stays enforced for everything else.

/// One file offered by the web server.
struct WebImportFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let size: Int64?
}

/// A downloaded .exe found under C:\Games, launchable through the loader.
struct InstalledGame: Identifiable, Hashable {
    let id = UUID()
    let name: String        // "Stray/game.exe" (relative to Games)
    let windowsPath: String // "C:\Games\Stray\game.exe"
}

/// Progress for one in-flight download.
struct WebDownloadState {
    var fileName: String
    var fraction: Double?  // nil = indeterminate
    var phase: String
}

/// Identifiable row wrapper for rendering the downloads dictionary.
struct WebDownloadRow: Identifiable {
    let id: UUID
    let state: WebDownloadState
}

/// Delegate-based downloader: URLSessionDownloadTask streams big game files
/// to disk instead of RAM, and the delegate reports progress.
final class WebDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var task: URLSessionDownloadTask?
    var onProgress: ((Double?) -> Void)?
    var onDone: ((URL?, Error?) -> Void)?
    private var finished = false

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let f: Double? = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        let cb = onProgress
        DispatchQueue.main.async { cb?(f) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        finished = true
        // The system may delete `location` after this returns; take our own copy.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("webimport-" + UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: location, to: tmp)
            let cb = onDone
            DispatchQueue.main.async { cb?(tmp, nil) }
        } catch {
            let cb = onDone
            DispatchQueue.main.async { cb?(nil, error) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if !finished {
            let cb = onDone
            DispatchQueue.main.async { cb?(nil, error) }
        }
    }
}

@MainActor
final class WebImportStore: ObservableObject {
    static let shared = WebImportStore()

    @Published var serverURL = ""
    @Published var files: [WebImportFile] = []
    @Published var isLoadingList = false
    @Published var listError: String?
    @Published var statusMessage: String?
    @Published var downloads: [UUID: WebDownloadState] = [:]
    @Published var installedGames: [InstalledGame] = []

    // Retained for the life of each download (session keeps its delegate alive
    // only weakly in some configurations; this dictionary owns both).
    private var downloaders: [UUID: (URLSession, WebDownloadDelegate)] = [:]

    private init() { loadSettings() }

    // MARK: paths

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    /// Wine's C: drive inside the app container: C:\Games == wine/drive_c/Games.
    static var gamesDir: URL {
        documents.appendingPathComponent("wine/drive_c/Games", isDirectory: true)
    }
    private static var settingsURL: URL {
        documents.appendingPathComponent("madeira-webimport.json")
    }

    private func loadSettings() {
        guard let d = try? Data(contentsOf: Self.settingsURL),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return }
        serverURL = j["serverURL"] ?? ""
    }

    func saveSettings() {
        guard let d = try? JSONSerialization.data(withJSONObject: ["serverURL": serverURL]) else { return }
        try? d.write(to: Self.settingsURL, options: .atomic)
    }

    // MARK: listing

    private func normalizedBase() -> URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") { s = "http://" + s }
        guard var parts = URLComponents(string: s), parts.host != nil else { return nil }
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        return parts.url
    }

    func refreshListing() async {
        guard let base = normalizedBase() else {
            listError = "Enter your server's address first."
            return
        }
        isLoadingList = true
        listError = nil
        statusMessage = nil
        files = []
        defer { isLoadingList = false }

        // 1) Structured listing: <server>/index.json
        do {
            let jsonURL = base.appendingPathComponent("index.json")
            let (data, resp) = try await URLSession.shared.data(from: jsonURL)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let items = arr.compactMap { entry -> WebImportFile? in
                    guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
                    let rawPath = entry["path"] as? String ?? name
                    let url: URL?
                    if rawPath.lowercased().hasPrefix("http://") || rawPath.lowercased().hasPrefix("https://") {
                        url = URL(string: rawPath)
                    } else {
                        url = URL(string: rawPath, relativeTo: base)?.absoluteURL
                    }
                    guard let u = url else { return nil }
                    var size: Int64?
                    if let n = entry["size"] as? Int64 { size = n }
                    else if let n = entry["size"] as? Int { size = Int64(n) }
                    else if let n = entry["size"] as? Double { size = Int64(n) }
                    return WebImportFile(name: name, url: u, size: size)
                }
                if !items.isEmpty {
                    files = items
                    statusMessage = "Found \(items.count) file(s)."
                    return
                }
            }
        } catch {
            // fall through to the HTML listing
        }

        // 2) Plain HTML directory listing (what `python3 -m http.server` serves).
        do {
            let (data, _) = try await URLSession.shared.data(from: base)
            let items = parseHTMLListing(data: data, base: base)
            if items.isEmpty {
                listError = "No files found. Serve an index.json, or a browsable folder (try: python3 -m http.server 8000)."
            } else {
                files = items
                statusMessage = "Found \(items.count) file(s)."
            }
        } catch {
            listError = "Could not reach the server: \(error.localizedDescription)"
        }
    }

    private func parseHTMLListing(data: Data, base: URL) -> [WebImportFile] {
        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return [] }
        let pattern = #"<a\s[^>]*href\s*=\s*"([^"]+)"[^>]*>(.*?)</a>"#
        guard let re = try? NSRegularExpression(pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        var out: [WebImportFile] = []
        var seen = Set<String>()
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            var href = ns.substring(with: m.range(at: 1))
            var text = ns.substring(with: m.range(at: 2))
            text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if href.hasPrefix("?") || href.hasPrefix("#") { continue }
            if href == "../" || href == ".." { continue }
            if href.hasPrefix("/") { continue }
            if let q = href.firstIndex(of: "?") { href = String(href[..<q]) }
            if href.isEmpty || href.hasSuffix("/") { continue }
            guard let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }
            var name = text.isEmpty ? href : text
            name = name.removingPercentEncoding ?? name
            out.append(WebImportFile(name: name, url: url, size: nil))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: downloads

    func download(_ file: WebImportFile) {
        let id = UUID()
        downloads[id] = WebDownloadState(fileName: file.name, fraction: 0, phase: "Starting…")
        let delegate = WebDownloadDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloaders[id] = (session, delegate)
        delegate.onProgress = { [weak self] f in
            guard let self else { return }
            Task { @MainActor in
                self.downloads[id]?.fraction = f
                self.downloads[id]?.phase = "Downloading…"
            }
        }
        delegate.onDone = { [weak self] location, error in
            guard let self else { return }
            Task { @MainActor in
                self.finishDownload(id: id, file: file, location: location, error: error)
            }
        }
        let task = session.downloadTask(with: file.url)
        delegate.task = task
        task.resume()
        LogStore.shared.log("Web import: downloading \(file.name)")
    }

    private func finishDownload(id: UUID, file: WebImportFile, location: URL?, error: Error?) {
        defer { downloaders.removeValue(forKey: id) }
        guard error == nil, let location else {
            let msg = (error as? LocalizedError)?.errorDescription
                ?? error?.localizedDescription ?? "unknown error"
            downloads[id]?.phase = "Failed"
            downloads[id]?.fraction = 0
            listError = "Download failed: \(msg)"
            LogStore.shared.log("Web import failed (\(file.name)): \(msg)", level: .error)
            return
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.gamesDir, withIntermediateDirectories: true)
            var diskName = file.url.lastPathComponent
            diskName = diskName.removingPercentEncoding ?? diskName
            if diskName.isEmpty { diskName = file.name }
            let dest = Self.gamesDir.appendingPathComponent(diskName)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
            LogStore.shared.log("Web import: saved \(diskName)", level: .success)

            let lower = diskName.lowercased()
            if lower.hasSuffix(".zip") {
                downloads[id]?.phase = "Extracting…"
                let target = Self.gamesDir
                    .appendingPathComponent((diskName as NSString).deletingPathExtension)
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                let rc: Int32 = dest.path.withCString { zp in
                    target.path.withCString { dp in madeira_extract_zip(zp, dp) }
                }
                if rc == 0 {
                    try? fm.removeItem(at: dest)
                    downloads[id]?.phase = "Done"
                    downloads[id]?.fraction = 1
                    LogStore.shared.log("Web import: extracted \(diskName)", level: .success)
                } else {
                    downloads[id]?.phase = "Extract failed"
                    LogStore.shared.log("Web import: could not extract \(diskName)", level: .error)
                }
            } else if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
                downloads[id]?.phase = "Extracting…"
                var base = (diskName as NSString).deletingPathExtension
                if lower.hasSuffix(".tar.gz") { base = (base as NSString).deletingPathExtension }
                let target = Self.gamesDir.appendingPathComponent(base)
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                let rc: Int32 = dest.path.withCString { zp in
                    target.path.withCString { dp in madeira_extract_prefix_tgz(zp, dp) }
                }
                if rc == 0 {
                    try? fm.removeItem(at: dest)
                    downloads[id]?.phase = "Done"
                    downloads[id]?.fraction = 1
                    LogStore.shared.log("Web import: extracted \(diskName)", level: .success)
                } else {
                    downloads[id]?.phase = "Extract failed"
                    LogStore.shared.log("Web import: could not extract \(diskName)", level: .error)
                }
            } else {
                downloads[id]?.phase = "Done"
                downloads[id]?.fraction = 1
            }
            scanInstalledGames()
        } catch {
            downloads[id]?.phase = "Failed"
            downloads[id]?.fraction = 0
            LogStore.shared.log("Web import failed (\(file.name)): \(error.localizedDescription)",
                                level: .error)
        }
    }

    // MARK: installed games

    /// Scans C:\Games for .exe files so they can be launched from the loader.
    func scanInstalledGames() {
        var found: [InstalledGame] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.gamesDir.path),
           let enumerator = fm.enumerator(at: Self.gamesDir,
                                          includingPropertiesForKeys: [.isDirectoryKey],
                                          options: [.skipsHiddenFiles]) {
            let base = Self.gamesDir.path + "/"
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "exe" else { continue }
                guard url.path.hasPrefix(base) else { continue }
                let rel = String(url.path.dropFirst(base.count))
                if rel.components(separatedBy: "/").count > 6 { continue }
                let win = "C:\\" + rel.replacingOccurrences(of: "/", with: "\\")
                found.append(InstalledGame(name: rel, windowsPath: win))
            }
        }
        installedGames = found.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - View

private func formatBytes(_ bytes: Int64?) -> String {
    guard let b = bytes, b > 0 else { return "" }
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: b)
}

struct WebImportView: View {
    @ObservedObject private var store = WebImportStore.shared
    var onRun: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Server address, e.g. 192.168.1.5:8000", text: $store.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.title3)
                    Button(store.isLoadingList ? "Loading…" : "Load file list") {
                        Task { await store.refreshListing() }
                    }
                    .font(.title3)
                    .disabled(store.isLoadingList
                              || store.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let err = store.listError {
                        Text(err).foregroundColor(.red).font(.body)
                    }
                    if let msg = store.statusMessage {
                        Text(msg).foregroundColor(.secondary).font(.body)
                    }
                } header: {
                    Text("Web server").font(.headline)
                } footer: {
                    Text("Your own computer on the same Wi-Fi. In the folder with your game files run: python3 -m http.server 8000 — then enter this Mac's IP and port above.")
                        .font(.body)
                }

                if !store.downloads.isEmpty {
                    Section("Downloads") {
                        ForEach(sortedDownloads) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.state.fileName).font(.body)
                                if let f = item.state.fraction {
                                    ProgressView(value: f).tint(.cyan)
                                } else {
                                    ProgressView().tint(.cyan)
                                }
                                Text(item.state.phase).font(.caption).foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Files on the server") {
                    if store.files.isEmpty {
                        Text("No files listed yet.").foregroundColor(.secondary).font(.body)
                    }
                    ForEach(store.files) { file in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(.body)
                                let sz = formatBytes(file.size)
                                if !sz.isEmpty {
                                    Text(sz).font(.caption).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button("Download") { store.download(file) }
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    if store.installedGames.isEmpty {
                        Text("Nothing downloaded yet.").foregroundColor(.secondary).font(.body)
                    }
                    ForEach(store.installedGames) { game in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.name).font(.body)
                                Text(game.windowsPath).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Run") {
                                let path = game.windowsPath
                                dismiss()
                                onRun(path)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }
                        .padding(.vertical, 2)
                    }
                    Button("Rescan") { store.scanInstalledGames() }.font(.body)
                } header: {
                    Text("Downloaded games").font(.headline)
                } footer: {
                    Text("Run launches the game through the normal Wine sequence (enable JIT first).")
                        .font(.body)
                }
            }
            .navigationTitle("Import from Web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.title3)
                }
            }
            .onAppear { store.scanInstalledGames() }
            .onDisappear { store.saveSettings() }
        }
    }

    private var sortedDownloads: [WebDownloadRow] {
        store.downloads.map { WebDownloadRow(id: $0.key, state: $0.value) }
            .sorted { $0.state.fileName < $1.state.fileName }
    }
}
