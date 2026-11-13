import Foundation
import MakeLORACore

/// Provider coordination and file reads never block the main actor. A stalled
/// provider can outlive cancellation; late results are discarded, never published.
enum CoordinatedFileImport {
    typealias CoordinateRead = @Sendable (NSFileCoordinator, URL, @escaping (URL) -> Void) -> Error?

    static func copy(source: URL, destination: URL, maximumBytes: Int64? = nil, timeout: TimeInterval = 120,
                     progress: @escaping @Sendable (Double?) -> Void = { _ in },
                     coordinate: CoordinateRead? = nil) async throws {
        let operation = ReadOperation(source: source, destination: destination, maximumBytes: maximumBytes, progress: progress, coordinate: coordinate)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in operation.start(continuation, timeout: timeout) }
        } onCancel: { operation.cancel(CancellationError()) }
    }

    private final class ReadOperation: @unchecked Sendable {
        private let lock = NSLock()
        private let coordinator = NSFileCoordinator()
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?
        private var timer: DispatchWorkItem?
        private let source: URL
        private let destination: URL
        private let maximumBytes: Int64?
        private let progress: @Sendable (Double?) -> Void
        private let coordinate: CoordinateRead?

        init(source: URL, destination: URL, maximumBytes: Int64?, progress: @escaping @Sendable (Double?) -> Void, coordinate: CoordinateRead?) {
            self.source = source; self.destination = destination; self.maximumBytes = maximumBytes; self.progress = progress; self.coordinate = coordinate
        }
        func start(_ continuation: CheckedContinuation<Void, Error>, timeout: TimeInterval) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result); return }
            self.continuation = continuation
            let deadline = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.cancel(ProjectError.invalid("Files did not finish providing \(self.source.lastPathComponent). Download the video to On My iPhone/iPad in Files, then import it again."))
            }
            timer = deadline
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            DispatchQueue.global(qos: .userInitiated).async { self.read() }
        }
        @discardableResult private func finish(_ value: Result<Void, Error>) -> Bool {
            lock.lock()
            guard result == nil else { lock.unlock(); return false }
            result = value
            let continuation = continuation, deadline = timer
            self.continuation = nil; timer = nil
            lock.unlock()
            deadline?.cancel(); continuation?.resume(with: value)
            return true
        }
        func cancel(_ error: Error) {
            if finish(.failure(error)) { coordinator.cancel() }
        }
        private func checkActive() throws {
            lock.lock(); let completed = result != nil; lock.unlock()
            if completed { throw CancellationError() }
        }
        private func read() {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                try checkActive()
                var copied: Result<Void, Error>?
                let accessor: (URL) -> Void = { url in
                    do { try self.checkActive(); try self.copyBytes(from: url); copied = .success(Void()) }
                    catch { copied = .failure(error) }
                }
                let error: Error?
                if let coordinate { error = coordinate(coordinator, source, accessor) }
                else {
                    var coordinationError: NSError?
                    coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError, byAccessor: accessor)
                    error = coordinationError
                }
                if let error { throw error }
                guard let copied else { throw ProjectError.invalid("Files could not provide \(source.lastPathComponent). Download it in Files and try again.") }
                try copied.get()
                if !finish(.success(Void())) { try? FileManager.default.removeItem(at: destination) }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                finish(.failure(error))
            }
        }
        private func copyBytes(from url: URL) throws {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
            if let maximumBytes, let size, size > maximumBytes { throw ProjectError.invalid("Caption files must be smaller than 1 MB.") }
            progress(size == nil ? nil : 0)
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ProjectError.invalid("Cannot store the imported file. Check device storage.") }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var count: Int64 = 0
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try checkActive(); count += Int64(data.count)
                if let maximumBytes, count > maximumBytes { throw ProjectError.invalid("Caption files must be smaller than 1 MB.") }
                try output.write(contentsOf: data)
                progress(size.flatMap { $0 > 0 ? min(1, Double(count) / Double($0)) : nil })
            }
            try checkActive()
        }
    }
}
