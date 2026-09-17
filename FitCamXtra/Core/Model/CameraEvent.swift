import Foundation

/// A clip the camera protected: either the physical button or the G-sensor.
public struct CameraEvent: Sendable, Identifiable, Equatable {
    public enum Trigger: Sendable, Equatable {
        case buttonPress
        case gSensor

        public var label: String {
            switch self {
            case .buttonPress: return "Button press"
            case .gSensor: return "G-sensor"
            }
        }
    }

    public let id: String
    public let recordedAt: Date
    public let duration: TimeInterval
    public let trigger: Trigger
    public let path: String
    public let note: String?
    public var isLocked: Bool

    public init(
        id: String,
        recordedAt: Date,
        duration: TimeInterval,
        trigger: Trigger,
        path: String,
        note: String? = nil,
        isLocked: Bool = true
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.duration = duration
        self.trigger = trigger
        self.path = path
        self.note = note
        self.isLocked = isLocked
    }

    public var title: String {
        switch trigger {
        case .buttonPress: return "Button press"
        case .gSensor: return "G-sensor - hard brake"
        }
    }
}

/// A file on the card: loop clip, locked clip or still.
public struct MediaFile: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        case video
        case photo
    }

    public let id: String
    public let path: String
    public let recordedAt: Date
    public let byteCount: Int64
    public let kind: Kind
    public let duration: TimeInterval?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public var isLocked: Bool

    public init(
        id: String,
        path: String,
        recordedAt: Date,
        byteCount: Int64,
        kind: Kind,
        duration: TimeInterval? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        isLocked: Bool = false
    ) {
        self.id = id
        self.path = path
        self.recordedAt = recordedAt
        self.byteCount = byteCount
        self.kind = kind
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isLocked = isLocked
    }
}

/// An incident is never one file. Loop recording writes roughly one-minute
/// chunks and the button only locks the chunk it landed in, so the start or
/// the aftermath often sits in a neighbour.
public struct IncidentBundle: Sendable, Equatable {
    public enum Range: Int, Sendable, CaseIterable {
        case lockedOnly = 0
        case plusMinusOne = 1
        case plusMinusTwo = 2

        public var label: String {
            switch self {
            case .lockedOnly: return "Locked only"
            case .plusMinusOne: return "+/-1 min"
            case .plusMinusTwo: return "+/-2 min"
            }
        }

        public var neighbourCount: Int { rawValue }
    }

    public struct Segment: Sendable, Identifiable, Equatable {
        public enum Role: Sendable, Equatable {
            case before
            case locked
            case after

            public var label: String {
                switch self {
                case .before: return "before"
                case .locked: return "locked"
                case .after: return "after"
                }
            }
        }

        public let id: String
        public let startedAt: Date
        public let duration: TimeInterval
        public let role: Role
        public let file: MediaFile?

        public init(id: String, startedAt: Date, duration: TimeInterval, role: Role, file: MediaFile? = nil) {
            self.id = id
            self.startedAt = startedAt
            self.duration = duration
            self.role = role
            self.file = file
        }
    }

    public let event: CameraEvent
    public let segments: [Segment]

    public init(event: CameraEvent, segments: [Segment]) {
        self.event = event
        self.segments = segments
    }

    public var totalDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    /// Builds the bundle around the locked clip from the card's file list.
    /// Neighbours are matched by start time, so a gap in the loop simply
    /// yields fewer segments rather than a wrong pairing.
    public static func build(
        event: CameraEvent,
        range: Range,
        files: [MediaFile],
        segmentLength: TimeInterval = 60
    ) -> IncidentBundle {
        var segments: [Segment] = [
            Segment(
                id: event.id,
                startedAt: event.recordedAt,
                duration: event.duration,
                role: .locked,
                file: files.first { $0.path == event.path }
            )
        ]

        let tolerance = segmentLength / 2

        for step in 1...max(range.neighbourCount, 1) where range.neighbourCount >= step {
            let beforeStart = event.recordedAt.addingTimeInterval(-segmentLength * Double(step))
            if let match = nearest(to: beforeStart, in: files, tolerance: tolerance) {
                segments.insert(
                    Segment(id: match.id, startedAt: match.recordedAt, duration: match.duration ?? segmentLength, role: .before, file: match),
                    at: 0
                )
            }

            let afterStart = event.recordedAt.addingTimeInterval(segmentLength * Double(step))
            if let match = nearest(to: afterStart, in: files, tolerance: tolerance) {
                segments.append(
                    Segment(id: match.id, startedAt: match.recordedAt, duration: match.duration ?? segmentLength, role: .after, file: match)
                )
            }
        }

        return IncidentBundle(event: event, segments: segments)
    }

    private static func nearest(to date: Date, in files: [MediaFile], tolerance: TimeInterval) -> MediaFile? {
        files
            .filter { $0.kind == .video }
            .min { abs($0.recordedAt.timeIntervalSince(date)) < abs($1.recordedAt.timeIntervalSince(date)) }
            .flatMap { abs($0.recordedAt.timeIntervalSince(date)) <= tolerance ? $0 : nil }
    }
}
