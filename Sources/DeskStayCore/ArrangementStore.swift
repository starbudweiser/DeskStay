import Foundation

public enum StoreError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case readOnly

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return L("store.newer", v)
        case .readOnly:
            return L("store.readOnly")
        }
    }
}

/// Persistance JSON : écriture atomique, copie de sauvegarde `.bak`, mise de côté d'un fichier illisible.
public final class ArrangementStore {
    public enum LoadOutcome: Equatable {
        case loaded
        case created
        case recoveredFromCorrupt(backupFileName: String)
    }

    public let directory: URL
    public let fileURL: URL
    public var backupURL: URL { fileURL.appendingPathExtension("bak") }
    public var data = StoreFile()
    public private(set) var isReadOnly = false

    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("arrangements.json")
        self.fileManager = fileManager
    }

    @discardableResult
    public func load() throws -> LoadOutcome {
        do {
            return try loadUnchecked()
        } catch {
            isReadOnly = true
            throw error
        }
    }

    private func loadUnchecked() throws -> LoadOutcome {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            data = StoreFile()
            return .created
        }
        let raw = try Data(contentsOf: fileURL)
        let decoded: StoreFile
        do {
            decoded = try Self.decoder.decode(StoreFile.self, from: raw)
        } catch {
            let name = "arrangements.corrupt-\(Int(Date().timeIntervalSince1970)).json"
            try fileManager.moveItem(at: fileURL, to: directory.appendingPathComponent(name))
            data = StoreFile()
            return .recoveredFromCorrupt(backupFileName: name)
        }
        guard decoded.version <= StoreFile.currentVersion else {
            throw StoreError.unsupportedVersion(decoded.version)
        }
        data = decoded
        return .loaded
    }

    public func save() throws {
        guard !isReadOnly else { throw StoreError.readOnly }
        let encoded = try Self.encoder.encode(data)
        if fileManager.fileExists(atPath: fileURL.path) {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: fileURL, to: backupURL)
        }
        try encoded.write(to: fileURL, options: .atomic)
    }

    public func arrangement(id: UUID?) -> Arrangement? {
        guard let id else { return nil }
        return data.arrangements.first { $0.id == id }
    }

    public func upsert(_ arrangement: Arrangement) {
        if let i = data.arrangements.firstIndex(where: { $0.id == arrangement.id }) {
            data.arrangements[i] = arrangement
        } else {
            data.arrangements.append(arrangement)
        }
    }

    public func remove(id: UUID) {
        data.arrangements.removeAll { $0.id == id }
        if data.settings.activeArrangementID == id {
            data.settings.activeArrangementID = data.arrangements.first?.id
        }
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
