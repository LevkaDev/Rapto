//
//  DebugLog.swift
//  Rapto
//
//  Debug logging utility that outputs to console in DEBUG builds
//  and optionally to file when user enables debug logging.
//

import Foundation

/// Debug logging function that outputs in DEBUG builds and to file when enabled
@inline(__always)
func debugLog(
    _ message: @autoclosure () -> String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    // Called from per-event paths (mouse drags), so skip building the string when nobody reads it
    #if !DEBUG
    guard FileLogger.shared.isEnabled else { return }
    #endif
    let msg = message()
    let filename = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
    
    #if DEBUG
    print("[\(filename)] \(msg)")
    #endif
    
    // Also write to file if file logging is enabled (works in Release too)
    FileLogger.shared.log(filename, msg)
}

@inline(__always)
func debugLog(
    _ category: String,
    _ message: @autoclosure () -> String
) {
    #if !DEBUG
    guard FileLogger.shared.isEnabled else { return }
    #endif
    let msg = message()
    
    #if DEBUG
    print("[\(category)] \(msg)")
    #endif
    
    // Also write to file if file logging is enabled (works in Release too)
    FileLogger.shared.log(category, msg)
}

