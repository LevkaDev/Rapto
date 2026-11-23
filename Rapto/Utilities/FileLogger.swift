//
//  FileLogger.swift
//  Rapto
//
//  File-based logging utility for collecting debug logs from users.
//  Logs are written to ~/Library/Logs/Rapto/debug.log
//

import Foundation
import AppKit

/// Thread-safe file logger for debug log collection
final class FileLogger {
    
    static let shared = FileLogger()
    
    // MARK: - Properties
    
    /// Whether file logging is enabled (controlled by user setting)
    var isEnabled: Bool = false {
        didSet {
            if isEnabled && !oldValue {
                writeHeader()
            }
        }
    }
    
    /// Maximum log file size before rotation (5 MB)
    private let maxFileSize: UInt64 = 5 * 1024 * 1024
    
    private let maxRotatedFiles: Int = 3
    
    private let queue = DispatchQueue(label: "com.rapto.filelogger", qos: .utility)
    
    /// Touched only on `queue`
    private var fileHandle: FileHandle?

    private let logDirectory: URL

    private let logFilePath: URL

    /// Used only on `queue`; DateFormatter is not thread-safe
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    // MARK: - Initialization
    
    private init() {
        let libraryPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        logDirectory = libraryPath.appendingPathComponent("Logs/Rapto", isDirectory: true)
        logFilePath = logDirectory.appendingPathComponent("debug.log")
        
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }
    
    deinit {
        closeFile()
    }
    
    // MARK: - Public Methods
    
    func log(_ category: String, _ message: String) {
        guard isEnabled else { return }
        
        queue.async { [weak self] in
            self?.writeLog(category: category, message: message)
        }
    }
    
    func openLogDirectory() {
        NSWorkspace.shared.open(logDirectory)
    }
    
    func clearLogs() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.closeFile()

            if let files = try? FileManager.default.contentsOfDirectory(at: self.logDirectory, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "log" {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
    
    func totalLogSize() -> UInt64 {
        var totalSize: UInt64 = 0
        
        if let files = try? FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files where file.pathExtension == "log" {
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += UInt64(size)
                }
            }
        }
        
        return totalSize
    }
    
    // MARK: - Private Methods
    
    private func writeLog(category: String, message: String) {
        rotateIfNeeded()

        if fileHandle == nil {
            openFile()
        }

        guard let handle = fileHandle else { return }

        let timestamp = dateFormatter.string(from: Date())
        let logLine = "[\(timestamp)] [\(category)] \(message)\n"

        if let data = logLine.data(using: .utf8) {
            handle.write(data)
        }
    }
    
    private func writeHeader() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.openFile()
            guard let handle = self.fileHandle else { return }
            
            let header = """
            ================================================================================
            Rapto Debug Log
            Started: \(self.dateFormatter.string(from: Date()))
            Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
            Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
            macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            ================================================================================
            
            """
            
            if let data = header.data(using: .utf8) {
                handle.write(data)
            }
        }
    }
    
    private func openFile() {
        if !FileManager.default.fileExists(atPath: logFilePath.path) {
            FileManager.default.createFile(atPath: logFilePath.path, contents: nil)
        }
        
        fileHandle = try? FileHandle(forWritingTo: logFilePath)
        fileHandle?.seekToEndOfFile()
    }
    
    private func closeFile() {
        try? fileHandle?.close()
        fileHandle = nil
    }
    
    private func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFilePath.path),
              let fileSize = attributes[.size] as? UInt64,
              fileSize >= maxFileSize else {
            return
        }
        
        closeFile()
        
        for i in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
            let oldPath = logDirectory.appendingPathComponent("debug.\(i).log")
            let newPath = logDirectory.appendingPathComponent("debug.\(i + 1).log")
            try? FileManager.default.removeItem(at: newPath)
            try? FileManager.default.moveItem(at: oldPath, to: newPath)
        }
        
        let rotatedPath = logDirectory.appendingPathComponent("debug.1.log")
        try? FileManager.default.moveItem(at: logFilePath, to: rotatedPath)
        
        let oldestPath = logDirectory.appendingPathComponent("debug.\(maxRotatedFiles + 1).log")
        try? FileManager.default.removeItem(at: oldestPath)
    }
}
