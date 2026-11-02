#!/usr/bin/env swift
//
// clipboard-sync-daemon
// macOS clipboard event daemon for clipboard-sync (push architecture).
//
// Watches NSPasteboard and pushes events to a FIFO (and optional Unix socket)
// so the Linux side can apply content immediately:
//   TEXT:<base64>
//   IMGFILE:/tmp/clipboard-sync-push.png
//
// Usage:
//   clipboard-sync-daemon [--fifo-path <path>] [--socket-path <path>]
//                         [--image-path <path>]
//

import AppKit
import Foundation
import Darwin

struct Config {
    var fifoPath: String = "/tmp/clipboard-sync.fifo"
    var socketPath: String? = nil
    var imagePath: String = "/tmp/clipboard-sync-push.png"
}

func parseArguments() -> Config {
    var config = Config()
    var i = 1
    while i < CommandLine.arguments.count {
        let arg = CommandLine.arguments[i]
        switch arg {
        case "--fifo-path":
            i += 1
            if i < CommandLine.arguments.count { config.fifoPath = CommandLine.arguments[i] }
        case "--socket-path":
            i += 1
            if i < CommandLine.arguments.count { config.socketPath = CommandLine.arguments[i] }
        case "--image-path":
            i += 1
            if i < CommandLine.arguments.count { config.imagePath = CommandLine.arguments[i] }
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            break
        }
        i += 1
    }
    return config
}

func printUsage() {
    print("Usage: clipboard-sync-daemon [options]")
    print("Options:")
    print("  --fifo-path <path>     Event FIFO (default: /tmp/clipboard-sync.fifo)")
    print("  --socket-path <path>   Also broadcast on a Unix domain socket")
    print("  --image-path <path>    Where to write PNG for IMGFILE events")
    print("  -h, --help             Show this help")
}

func log(_ level: String, _ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] [\(level)] \(message)\n".utf8))
}

final class IPCChannel {
    private let fifoPath: String
    private var fifoWriter: FileHandle?
    private var socketClients: [Int32] = []
    private let queue = DispatchQueue(label: "clipboard-sync.ipc")

    init(fifoPath: String, socketPath: String?) {
        self.fifoPath = fifoPath
        setupFIFO()
        if let socketPath = socketPath {
            setupSocket(path: socketPath)
        }
    }

    private func setupFIFO() {
        var st = stat()
        if lstat(fifoPath, &st) == 0 {
            // Reuse the existing inode. Removing and recreating the FIFO on a
            // daemon restart orphaned the Linux-side `ssh cat` reader on the
            // old inode, so events silently queued for seconds.
            guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFIFO) else {
                log("ERROR", "\(fifoPath) exists but is not a FIFO - refusing to replace it")
                return
            }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: fifoPath)
                let fileOwner = attrs[.ownerAccountID] as? NSNumber
                let currentUser = getuid()
                if fileOwner?.uint32Value != currentUser {
                    log("ERROR", "FIFO exists but is not owned by current user - refusing to use it")
                    return
                }
            } catch {
                log("ERROR", "Failed to inspect existing FIFO: \(error)")
                return
            }
            log("INFO", "reusing existing FIFO at \(fifoPath)")
        } else if errno == ENOENT {
            let rc = mkfifo(fifoPath, 0o600)
            if rc != 0 {
                log("ERROR", "mkfifo failed: \(errno)")
                return
            }
        } else {
            log("ERROR", "lstat failed for \(fifoPath): \(errno)")
            return
        }

        // O_RDWR so writes never block when no Linux reader is attached yet.
        let fd = open(fifoPath, O_RDWR | O_NONBLOCK)
        if fd < 0 {
            log("ERROR", "failed to open FIFO: \(errno)")
        } else {
            fifoWriter = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            log("INFO", "FIFO ready at \(fifoPath)")
        }
    }

    private func setupSocket(path: String) {
        unlink(path)
        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout.size(ofValue: addr))
        addr.sun_family = sa_family_t(AF_UNIX)
        let len = min(path.utf8.count, MemoryLayout.size(ofValue: addr.sun_path) - 1)
        _ = path.utf8CString.withUnsafeBufferPointer { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                memcpy(dst, src.baseAddress!, len)
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("ERROR", "socket creation failed: \(errno)")
            return
        }

        let bindRc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRc == 0 else {
            log("ERROR", "socket bind failed: \(errno)")
            close(fd)
            return
        }
        listen(fd, 5)
        log("INFO", "Unix socket ready at \(path)")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self = self {
                var clientAddr = sockaddr_un()
                var clientLen: socklen_t = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        accept(fd, sa, &clientLen)
                    }
                }
                if clientFd < 0 { continue }
                self.queue.async {
                    self.socketClients.append(clientFd)
                    log("INFO", "client connected (fd \(clientFd))")
                }
            }
        }
    }

    func broadcast(event: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var payload = event
            payload.append(Data("\n".utf8))

            if let writer = self.fifoWriter {
                writer.write(payload)
                // Best-effort; fsync on FIFOs often returns EINVAL — ignore.
                _ = Darwin.fsync(writer.fileDescriptor)
            }

            var alive: [Int32] = []
            for fd in self.socketClients {
                var wrote = 0
                payload.withUnsafeBytes { ptr in
                    wrote = send(fd, ptr.baseAddress!, payload.count, Int32(MSG_NOSIGNAL))
                }
                if wrote < 0 && (errno == EPIPE || errno == ECONNRESET) {
                    close(fd)
                } else {
                    alive.append(fd)
                }
            }
            self.socketClients = alive
        }
    }
}

final class ClipboardMonitor {
    /// NSPasteboard has no change notification; 50ms bounds the added latency
    /// while keeping the changeCount check cheap.
    private let pollInterval: TimeInterval = 0.05
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var pendingChangeCount = -1
    private var pendingSince: TimeInterval = 0
    private let ipc: IPCChannel
    private let imagePath: String
    private var timer: Timer?
    private var activity: NSObjectProtocol?

    init(ipc: IPCChannel, imagePath: String) {
        self.ipc = ipc
        self.imagePath = imagePath
    }

    func start() {
        // App Nap can coalesce a background agent's timers to seconds. Keep the
        // monitor exempt so the 50ms poll actually fires while the Mac is idle.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "clipboard-sync event latency"
        )
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common keeps the timer alive during tracking/modal run-loop modes.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        RunLoop.main.run()
    }

    private func tick() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }

        // changeCount can advance when the pasteboard is cleared, before the
        // owner has written the new representation. Retry the same count for up
        // to a second instead of dropping the event (which only the 30s
        // safety-net poll would repair).
        let now = Date().timeIntervalSince1970
        if current != pendingChangeCount {
            pendingChangeCount = current
            pendingSince = now
        }

        if handleChange(pb) {
            lastChangeCount = current
            pendingChangeCount = -1
        } else if now - pendingSince >= 1.0 {
            lastChangeCount = current
            pendingChangeCount = -1
            log("DEBUG", "clipboard change has no supported content; skipping")
        }
    }

    private func handleChange(_ pb: NSPasteboard) -> Bool {
        // Prefer text when present (common for mixed pasteboards).
        if let text = pb.string(forType: .string), !text.isEmpty {
            let b64 = Data(text.utf8).base64EncodedString()
            let payload = "TEXT:\(b64)"
            ipc.broadcast(event: Data(payload.utf8))
            log("INFO", "pushed TEXT (\(text.utf8.count) bytes)")
            return true
        }

        // Images: write PNG to a stable path and signal IMGFILE (avoids huge FIFO lines).
        if let png = pngData(from: pb) {
            do {
                try png.write(to: URL(fileURLWithPath: imagePath), options: .atomic)
                let payload = "IMGFILE:\(imagePath)"
                ipc.broadcast(event: Data(payload.utf8))
                log("INFO", "pushed IMGFILE \(imagePath) (\(png.count) bytes)")
                return true
            } catch {
                log("ERROR", "failed to write image: \(error)")
            }
        }

        return false
    }

    private func pngData(from pb: NSPasteboard) -> Data? {
        if let data = pb.data(forType: .png) {
            return data
        }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        if let objects = pb.readObjects(forClasses: [NSImage.self], options: nil),
           let img = objects.first as? NSImage,
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }
}

NSSetUncaughtExceptionHandler { exception in
    log("ERROR", "Uncaught exception: \(exception)")
    log("ERROR", exception.callStackSymbols.joined(separator: "\n"))
    exit(1)
}

let config = parseArguments()
let ipc = IPCChannel(fifoPath: config.fifoPath, socketPath: config.socketPath)
let monitor = ClipboardMonitor(ipc: ipc, imagePath: config.imagePath)
log("INFO", "clipboard-sync-daemon started (push protocol TEXT/IMGFILE)")
monitor.start()
