import SwiftUI
import Foundation

// MARK: - Import games: the app is the server
//
// "Import Games" in the game loader: the app runs a tiny web server on the
// iPhone/iPad and shows its address (e.g. http://192.168.1.10:8080). Open
// that address in a browser on your computer and upload through the simple
// page: pick .zip files (unzipped automatically into C:\Games) or whole
// folders of game files (copied as-is into C:\Games). Every .exe found
// under C:\Games then shows up below with a Run button that launches it
// through the normal Wine sequence.
//
// The server is a minimal single-threaded HTTP/1.1 implementation over
// POSIX sockets: GET / serves the upload page, POST /upload receives
// multipart/form-data and streams it straight to disk (no size limit beyond
// the disk itself). Uploaded names are sanitized: absolute paths and ".."
// are rejected, and webkitdirectory relative paths ("folder/sub/game.exe")
// are preserved.

/// A downloaded .exe found under C:\Games, launchable through the loader.
struct InstalledGame: Identifiable, Hashable {
    let id = UUID()
    let name: String        // "Stray/game.exe" (relative to Games)
    let windowsPath: String // "C:\Games\Stray\game.exe"
}

/// The device's IPv4 addresses (Wi-Fi first), for display in the UI.
func deviceIPAddresses() -> [String] {
    var out: [String] = []
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
        ptr = p.pointee.ifa_next
        let flags = Int32(p.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
              flags & IFF_LOOPBACK == 0 else { continue }
        guard let sa = p.pointee.ifa_addr,
              sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                       &host, socklen_t(host.count), nil, 0,
                       NI_NUMERICHOST) == 0 {
            out.append(String(cString: host))
        }
    }
    // Display order is fine as-is (usually Wi-Fi first already).
    return out
}

/// Strips anything dangerous from an uploaded filename. Keeps
/// webkitdirectory relative paths ("folder/sub/game.exe"); reduces
/// "C:\fakepath\game.zip"-style names to their basename. Nil = reject.
func sanitizedUploadPath(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    let hadForwardSlash = s.contains("/")
    s = s.replacingOccurrences(of: "\\", with: "/")
    if !hadForwardSlash {
        s = (s as NSString).lastPathComponent
    }
    if s.hasPrefix("/") { return nil }
    let parts = s.split(separator: "/").map(String.init)
        .filter { !$0.isEmpty && $0 != "." }
    if parts.isEmpty || parts.contains("..") { return nil }
    return parts.joined(separator: "/")
}

// MARK: - SocketReader: buffered, streaming socket reads

private final class SocketReader {
    private let fd: Int32
    private var buf = Data()

    init(fd: Int32) { self.fd = fd }

    private func fill() -> Bool {
        var tmp = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &tmp, tmp.count, 0)
        guard n > 0 else { return false }
        buf.append(tmp, count: n)
        return true
    }

    /// Reads up to and including `delim`; returns the bytes before it
    /// (the delimiter itself is consumed). Nil on disconnect.
    func readUntil(_ delim: Data) -> Data? {
        while true {
            if let r = buf.range(of: delim) {
                let out = buf.subdata(in: buf.startIndex..<r.lowerBound)
                buf.removeSubrange(buf.startIndex..<r.upperBound)
                return out
            }
            if !fill() { return nil }
        }
    }

    /// Streaming readUntil: chunks are handed off as they arrive instead of
    /// buffering the whole part. Returns false if the connection died first.
    func readUntilStreaming(_ delim: Data, onChunk: (Data) -> Void) -> Bool {
        while true {
            if let r = buf.range(of: delim) {
                let out = buf.subdata(in: buf.startIndex..<r.lowerBound)
                if !out.isEmpty { onChunk(out) }
                buf.removeSubrange(buf.startIndex..<r.upperBound)
                return true
            }
            // Emit everything except a tail that could hold half a delimiter.
            let keep = max(delim.count - 1, 0)
            if buf.count > keep {
                let end = buf.startIndex + (buf.count - keep)
                onChunk(buf.subdata(in: buf.startIndex..<end))
                buf.removeSubrange(buf.startIndex..<end)
            }
            if !fill() { return false }
        }
    }

    func readLine() -> Data? {
        readUntil(Data("\r\n".utf8))
    }

    func readExactly(_ count: Int) -> Data? {
        while buf.count < count {
            if !fill() { return nil }
        }
        let out = buf.subdata(in: buf.startIndex..<buf.startIndex + count)
        buf.removeSubrange(buf.startIndex..<buf.startIndex + count)
        return out
    }
}

// MARK: - UploadServer

/// Minimal HTTP/1.1 file-upload server. One connection at a time, handled on
/// a background queue; all state callbacks hop to the main actor via the
/// store.
final class UploadServer {
    var onEvent: ((String) -> Void)?
    var onBatchComplete: (() -> Void)?

    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private let lock = NSLock()

    private func withFD<T>(_ body: (Int32) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(listenFD)
    }

    var isRunning: Bool { withFD { $0 >= 0 } }

    /// Binds 0.0.0.0 on the first free port in 8080...8099. Returns the port.
    func start() throws -> UInt16 {
        if isRunning { return port }
        var lastError = "unknown"
        for p in UInt16(8080)...UInt16(8099) {
            do {
                let fd = try bindPort(p)
                lock.lock()
                listenFD = fd
                port = p
                lock.unlock()
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.serve()
                }
                return p
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw NSError(domain: "UploadServer", code: 1,
                      userInfo: [NSLocalizedDescriptionKey:
                                 "No free port in 8080-8099 (\(lastError))"])
    }

    func stop() {
        lock.lock()
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
        lock.unlock()
    }

    // MARK: internals (background thread)

    private func sockErr(_ what: String) -> NSError {
        NSError(domain: "UploadServer", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                           "\(what) failed: \(String(cString: strerror(errno)))"])
    }

    private func bindPort(_ p: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw sockErr("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = p.bigEndian
        addr.sin_addr = in_addr(s_addr: 0)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { close(fd); throw sockErr("bind :\(p)") }
        guard listen(fd, 8) == 0 else { close(fd); throw sockErr("listen") }
        return fd
    }

    private func serve() {
        while true {
            var st = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let lfd = withFD { $0 }
            let fd = withUnsafeMutablePointer(to: &st) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(lfd, $0, &len)
                }
            }
            if fd < 0 { break }  // socket closed by stop()
            handleConnection(fd)
        }
    }

    private func emit(_ line: String) {
        onEvent?(line)
    }

    private func sendResponse(_ fd: Int32, _ status: Int, _ statusText: String,
                              contentType: String, body: Data) {
        let head = "HTTP/1.1 \(status) \(statusText)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        payload.withUnsafeBytes { ptr in
            var sent = 0
            while sent < payload.count {
                let n = send(fd, ptr.baseAddress!.advanced(by: sent),
                             payload.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        let reader = SocketReader(fd: fd)
        guard let headData = reader.readUntil(Data("\r\n\r\n".utf8)),
              let head = String(data: headData, encoding: .utf8),
              let requestLine = head.components(separatedBy: "\r\n").first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let path = String(parts[1]).components(separatedBy: "?").first ?? "/"
        var headers: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<c]).lowercased()
                .trimmingCharacters(in: .whitespaces)
            headers[key] = String(line[line.index(after: c)...])
                .trimmingCharacters(in: .whitespaces)
        }
        if headers["expect"]?.lowercased() == "100-continue" {
            let cont = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
            _ = cont.withUnsafeBytes { send(fd, $0.baseAddress!, cont.count, 0) }
        }
        if method == "GET" && path == "/" {
            sendResponse(fd, 200, "OK",
                         contentType: "text/html; charset=utf-8",
                         body: Data(uploadPageHTML.utf8))
        } else if method == "POST" && path == "/upload" {
            handleUpload(fd: fd, reader: reader, headers: headers)
        } else {
            sendResponse(fd, 404, "Not Found",
                         contentType: "text/plain",
                         body: Data("not found".utf8))
        }
    }

    private func handleUpload(fd: Int32, reader: SocketReader,
                              headers: [String: String]) {
        func fail(_ code: Int, _ text: String) {
            sendResponse(fd, code, text, contentType: "text/plain",
                         body: Data(text.utf8))
        }
        guard let ct = headers["content-type"],
              ct.lowercased().contains("multipart/form-data"),
              let bRange = ct.range(of: "boundary=",
                                    options: .caseInsensitive) else {
            fail(400, "need multipart"); return
        }
        var boundary = String(ct[bRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if boundary.hasPrefix("\"") {
            boundary = String(boundary.dropFirst().prefix(while: { $0 != "\"" }))
        }
        if let semi = boundary.firstIndex(of: ";") {
            boundary = String(boundary[..<semi])
        }
        guard !boundary.isEmpty else { fail(400, "no boundary"); return }

        let gamesDir = WebImportStore.gamesDir
        try? FileManager.default.createDirectory(at: gamesDir,
                                                withIntermediateDirectories: true)

        let firstDelim = Data(("--" + boundary).utf8)
        guard reader.readLine() == firstDelim else {
            fail(400, "bad body"); return
        }

        var received: [String] = []
        var zips: [URL] = []
        let partDelim = Data(("\r\n--" + boundary).utf8)

        uploadLoop: while true {
            guard let partHead = reader.readUntil(Data("\r\n\r\n".utf8)),
                  let partHeadStr = String(data: partHead, encoding: .utf8) else { break }
            var filename: String?
            for line in partHeadStr.components(separatedBy: "\r\n") {
                if let fr = line.range(of: "filename=",
                                       options: .caseInsensitive) {
                    var fn = String(line[fr.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if fn.hasPrefix("\"") {
                        fn = String(fn.dropFirst().prefix(while: { $0 != "\"" }))
                    }
                    filename = fn
                }
            }
            if let filename, let safe = sanitizedUploadPath(filename) {
                let dest = gamesDir.appendingPathComponent(safe)
                do {
                    try FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    FileManager.default.createFile(atPath: dest.path,
                                                   contents: nil)
                    let fh = try FileHandle(forWritingTo: dest)
                    let found = reader.readUntilStreaming(partDelim) { chunk in
                        try? fh.write(contentsOf: chunk)
                    }
                    try? fh.close()
                    if found {
                        received.append(safe)
                        if safe.lowercased().hasSuffix(".zip") {
                            zips.append(dest)
                        }
                    } else {
                        try? FileManager.default.removeItem(at: dest)
                        break uploadLoop  // truncated upload
                    }
                } catch {
                    break uploadLoop
                }
            } else {
                // Not a file part: discard.
                guard reader.readUntilStreaming(partDelim, onChunk: { _ in }) else {
                    break uploadLoop
                }
            }
            guard let trailer = reader.readExactly(2) else { break uploadLoop }
            if trailer == Data("--".utf8) {
                break uploadLoop  // final boundary
            } else if trailer != Data("\r\n".utf8) {
                break uploadLoop  // malformed
            }
        }

        for zip in zips {
            let target = gamesDir.appendingPathComponent(
                (zip.lastPathComponent as NSString).deletingPathExtension)
            try? FileManager.default.createDirectory(at: target,
                                                    withIntermediateDirectories: true)
            let rc: Int32 = zip.path.withCString { zp in
                target.path.withCString { dp in madeira_extract_zip(zp, dp) }
            }
            if rc == 0 {
                try? FileManager.default.removeItem(at: zip)
                emit("Unzipped \(zip.lastPathComponent).")
            } else {
                emit("Could not unzip \(zip.lastPathComponent).")
            }
        }
        for r in received {
            emit("Received \(r).")
        }
        onBatchComplete?()
        sendResponse(fd, 200, "OK", contentType: "text/plain",
                     body: Data("ok".utf8))
    }
}

// MARK: - Upload page (served by the app to the computer's browser)

private let uploadPageHTML = """
<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Madeira &mdash; Send games</title>
<style>
body{font-family:-apple-system,Helvetica,sans-serif;max-width:640px;margin:48px auto;padding:0 20px;color:#111}
h1{font-size:28px}p{font-size:17px;line-height:1.5}
button{font-size:20px;padding:14px 28px;margin:12px 12px 12px 0;border-radius:12px;border:none;background:#0a84ff;color:#fff}
button:active{background:#0066cc}
progress{width:100%;height:24px;margin-top:16px}
#msg{font-size:18px;margin-top:16px;min-height:28px}
input[type=file]{font-size:17px;margin:8px 0;max-width:100%}
.card{border:1px solid #ddd;border-radius:16px;padding:20px;margin:20px 0}
</style></head>
<body>
<h1>Send games to Madeira</h1>
<div class="card">
<p><b>Zip files</b> &mdash; picked zips are unzipped automatically into the game folder.</p>
<input type="file" id="zips" accept=".zip,application/zip" multiple><br>
<button onclick="upload('zips')">Upload zips</button>
</div>
<div class="card">
<p><b>Game folders</b> &mdash; a folder&rsquo;s files are copied as-is into the game folder.</p>
<input type="file" id="folder" webkitdirectory><br>
<button onclick="upload('folder')">Upload folder</button>
</div>
<progress id="prog" value="0" max="100"></progress>
<div id="msg"></div>
<script>
function setMsg(t){document.getElementById('msg').textContent=t;}
function upload(id){
  var input=document.getElementById(id),files=input.files;
  if(!files.length){setMsg('Pick something first.');return;}
  var fd=new FormData();
  for(var i=0;i<files.length;i++){
    fd.append('files',files[i],files[i].webkitRelativePath||files[i].name);
  }
  var xhr=new XMLHttpRequest();
  xhr.open('POST','/upload');
  xhr.upload.onprogress=function(e){
    if(e.lengthComputable){
      var p=Math.round(e.loaded/e.total*100);
      document.getElementById('prog').value=p;
      setMsg('Uploading... '+p+'%');
    }
  };
  xhr.onload=function(){
    document.getElementById('prog').value=xhr.status===200?100:0;
    setMsg(xhr.status===200?'Done - check the app.':'Upload failed.');
  };
  xhr.onerror=function(){setMsg('Upload failed - is the app still open?');};
  document.getElementById('prog').value=0;
  setMsg('Uploading...');
  xhr.send(fd);
}
</script>
</body></html>
"""

// MARK: - Store

@MainActor
final class WebImportStore: ObservableObject {
    static let shared = WebImportStore()

    @Published var isServing = false
    @Published var serverAddress = ""
    @Published var extraAddresses: [String] = []
    @Published var serverMessage: String?
    @Published var receivedFiles: [String] = []
    @Published var installedGames: [InstalledGame] = []

    private let server = UploadServer()
    private init() {}

    // MARK: paths

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    /// Wine's C: drive inside the app container: C:\Games == wine/drive_c/Games.
    static var gamesDir: URL {
        documents.appendingPathComponent("wine/drive_c/Games", isDirectory: true)
    }

    // MARK: server control

    func startServer() {
        server.onEvent = { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                self.serverMessage = line
                if line.hasPrefix("Received ") || line.hasPrefix("Unzipped ") ||
                   line.hasPrefix("Could not ") {
                    self.receivedFiles.insert(line, at: 0)
                    if self.receivedFiles.count > 50 {
                        self.receivedFiles.removeLast()
                    }
                }
                LogStore.shared.log("Import server: \(line)")
            }
        }
        server.onBatchComplete = { [weak self] in
            Task { @MainActor in self?.scanInstalledGames() }
        }
        do {
            let port = try server.start()
            let ips = deviceIPAddresses()
            let host = ips.first ?? "this-device"
            serverAddress = "http://\(host):\(port)"
            extraAddresses = ips.dropFirst().map { "http://\($0):\(port)" }
            isServing = true
            serverMessage = "Waiting for uploads..."
            LogStore.shared.log("Import server running at \(serverAddress)",
                                level: .success)
        } catch {
            serverMessage = "Could not start the server: \(error.localizedDescription)"
            LogStore.shared.log("Import server failed: \(error.localizedDescription)",
                                level: .error)
        }
    }

    func stopServer() {
        server.stop()
        isServing = false
        serverMessage = nil
        LogStore.shared.log("Import server stopped.")
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

struct WebImportView: View {
    @ObservedObject private var store = WebImportStore.shared
    var onRun: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.isServing {
                        Text("On your computer's browser, go to:")
                            .font(.headline)
                        Text(store.serverAddress)
                            .font(.system(size: 30, weight: .bold,
                                          design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                        ForEach(store.extraAddresses, id: \.self) { addr in
                            Text("Also: \(addr)")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        Button("Stop server") { store.stopServer() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .font(.title3)
                    } else {
                        Text("Start the server, then open the address it shows in your computer's browser to upload games.")
                            .font(.body)
                        Button("Start server") { store.startServer() }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                            .font(.title2)
                    }
                    if let msg = store.serverMessage {
                        Text(msg).font(.body).foregroundColor(.secondary)
                    }
                } header: {
                    Text("Upload from your computer").font(.headline)
                } footer: {
                    Text("Pick .zip files (unzipped automatically) or whole game folders (copied as-is). Everything lands in C:\\Games. Your computer must be on the same Wi-Fi. The server keeps running until you stop it. If the browser can't connect, allow Local Network access for Madeira in the Settings app.")
                        .font(.body)
                }

                if !store.receivedFiles.isEmpty {
                    Section("Received") {
                        ForEach(store.receivedFiles, id: \.self) { line in
                            Text(line).font(.body)
                        }
                    }
                }

                Section {
                    if store.installedGames.isEmpty {
                        Text("Nothing here yet — upload a game above.")
                            .foregroundColor(.secondary).font(.body)
                    }
                    ForEach(store.installedGames) { game in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.name).font(.body)
                                Text(game.windowsPath).font(.caption)
                                    .foregroundColor(.secondary)
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
                    Text("Games on this device").font(.headline)
                } footer: {
                    Text("Run launches the game through the normal Wine sequence (enable JIT first).")
                        .font(.body)
                }
            }
            .navigationTitle("Import Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.title3)
                }
            }
            .onAppear { store.scanInstalledGames() }
        }
    }
}
