//
//  Logging.swift
//  FieldForge
//
//  One place for every logger, and one rule: donor names, addresses, amounts,
//  and note text never enter a log line. Unified logging is readable from a
//  connected Mac and persists in the system log, so anything logged here is
//  effectively disclosed. Structure and identifiers only.
//

import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "org.example.fieldforge"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let documents = Logger(subsystem: subsystem, category: "documents")
    static let payments = Logger(subsystem: subsystem, category: "payments")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let location = Logger(subsystem: subsystem, category: "location")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let outbox = Logger(subsystem: subsystem, category: "outbox")
    static let store = Logger(subsystem: subsystem, category: "storekit")
}
