import Foundation
import WhispCore

/// A single push-to-talk turn. All mutable state lives on queue. Synchronous
/// append calls preserve the recorder's order, including while TLS connects.
final class OpenAIRealtimeTranscriber: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.busqueneil.whisp.openai-realtime", qos: .userInitiated)
    private let apiKey: String
    private let vocabulary: [String]
    private let model: String
    private let onPartial: @Sendable (String) -> Void
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var started = false
    private var configured = false
    private var sending = false
    private var finishing = false
    private var commitSent = false
    private var pending: [Data] = []
    private var pendingIndex = 0
    private var audioBytes = 0
    private var turn = RealtimeTranscriptionProtocol.Turn()
    private var lastPartial: String?
    private var terminal: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?
    private var connectionDeadline: DispatchWorkItem?
    private var finishDeadline: DispatchWorkItem?

    init(apiKey: String, vocabulary: [String] = [], model: String = RealtimeTranscriptionProtocol.model,
         onPartial: @escaping @Sendable (String) -> Void = { _ in }) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.vocabulary = vocabulary
        self.model = model
        self.onPartial = onPartial
    }

    /// Returns immediately; microphone capture need not wait for connection.
    func begin() {
        queue.async { self.connect() }
    }

    /// Ordered little-endian PCM16, mono, 24 kHz. Call only until recorder.stop
    /// has drained its final callback, then call finish exactly once.
    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        queue.async {
            guard self.terminal == nil else { return }
            guard self.started, !self.finishing, pcm.count.isMultiple(of: 2) else {
                self.fail("The microphone stream arrived out of order.")
                return
            }
            // The UI caps recordings at five minutes. Bound memory as well.
            guard self.audioBytes + pcm.count <= 24_000 * 2 * 305 else {
                self.fail("This recording exceeded Whisp's streaming limit.")
                return
            }
            self.audioBytes += pcm.count
            self.pending.append(pcm)
            self.pump()
        }
    }

    func finish(timeout: TimeInterval = 10) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let terminal = self.terminal {
                        continuation.resume(with: terminal)
                        return
                    }
                    guard self.started, !self.finishing else {
                        continuation.resume(throwing: RealtimeTranscriptionProtocol.Failure(
                            "This transcription session cannot be finished twice."))
                        return
                    }
                    self.finishing = true
                    self.continuation = continuation
                    let bounded = timeout.isFinite ? min(30, max(0.1, timeout)) : 10
                    let deadline = DispatchWorkItem { [weak self] in
                        self?.fail("OpenAI transcription timed out. Please try again.")
                    }
                    self.finishDeadline = deadline
                    self.queue.asyncAfter(deadline: .now() + bounded, execute: deadline)
                    guard self.audioBytes > 0 else {
                        self.resolve(.success(""))
                        return
                    }
                    self.pump()
                }
            }
        } onCancel: { self.abort() }
    }

    func abort() {
        queue.async { self.resolve(.failure(CancellationError())) }
    }

    private func connect() {
        guard !started, terminal == nil else { return }
        started = true
        guard !apiKey.isEmpty else { fail("Add an OpenAI API key in Whisp Settings."); return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 330
        let session = URLSession(configuration: configuration)
        self.session = session
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_048_576
        self.socket = socket
        let deadline = DispatchWorkItem { [weak self] in
            self?.fail("Could not connect to OpenAI. Check your connection and API key.")
        }
        connectionDeadline = deadline
        queue.asyncAfter(deadline: .now() + 12, execute: deadline)
        socket.resume()
        receive()
        do {
            let data = try RealtimeTranscriptionProtocol.sessionUpdate(vocabulary: vocabulary, model: model)
            socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                guard let self, let error else { return }
                self.queue.async { self.resolve(.failure(self.networkFailure(error))) }
            }
        } catch { resolve(.failure(error)) }
    }

    private func receive() {
        guard terminal == nil, let socket else { return }
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.terminal == nil else { return }
                do {
                    let data: Data
                    switch try result.get() {
                    case .string(let string): data = Data(string.utf8)
                    case .data(let binary): data = binary
                    @unknown default: throw RealtimeTranscriptionProtocol.Failure("OpenAI returned an unsupported event.")
                    }
                    let event = try RealtimeTranscriptionProtocol.event(from: data)
                    if event == .configured {
                        self.configured = true
                        self.connectionDeadline?.cancel()
                        self.connectionDeadline = nil
                        self.pump()
                    }
                    if let transcript = try self.turn.accept(event), self.commitSent {
                        self.resolve(.success(transcript.trimmingCharacters(in: .whitespacesAndNewlines)))
                        return
                    }
                    if let partial = self.turn.partialTranscript, partial != self.lastPartial {
                        self.lastPartial = partial
                        // Runs on the serial receive queue. Consumers schedule
                        // speculative work and must not insert preview text.
                        self.onPartial(partial)
                    }
                    self.receive()
                } catch { self.resolve(.failure(self.networkFailure(error))) }
            }
        }
    }

    /// One send in flight prevents an actor reentrancy race between append and
    /// commit. Bytes queued before finish are always sent before the commit.
    private func pump() {
        guard terminal == nil, configured, !sending, let socket else { return }
        let message: Data
        do {
            if pendingIndex < pending.count {
                let pcm = pending[pendingIndex]
                pendingIndex += 1
                message = try RealtimeTranscriptionProtocol.append(pcm)
                // Release already sent chunks periodically without O(n) work on
                // every tap, including during slow or reconnecting networks.
                if pendingIndex >= 64 {
                    pending.removeFirst(pendingIndex)
                    pendingIndex = 0
                }
            } else if finishing, !commitSent {
                pending.removeAll(keepingCapacity: false)
                pendingIndex = 0
                // Very short taps need a minimum audio turn. Pad only silence;
                // never manufacture spoken output or insert a partial result.
                let minimumBytes = 4_800
                if audioBytes < minimumBytes {
                    let padding = Data(repeating: 0, count: minimumBytes - audioBytes)
                    audioBytes = minimumBytes
                    pending.append(padding)
                    pump()
                    return
                }
                commitSent = true
                message = RealtimeTranscriptionProtocol.commit()
            } else { return }
        } catch { resolve(.failure(error)); return }
        sending = true
        socket.send(.string(String(decoding: message, as: UTF8.self))) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sending = false
                if let error { self.resolve(.failure(self.networkFailure(error))) }
                else { self.pump() }
            }
        }
    }

    private func fail(_ message: String) {
        resolve(.failure(RealtimeTranscriptionProtocol.Failure(message)))
    }

    private func networkFailure(_ error: Error) -> Error {
        if error is CancellationError || error is RealtimeTranscriptionProtocol.Failure { return error }
        return RealtimeTranscriptionProtocol.Failure("OpenAI transcription connection failed. Check your connection and API key.")
    }

    private func resolve(_ result: Result<String, Error>) {
        guard terminal == nil else { return }
        terminal = result
        connectionDeadline?.cancel(); connectionDeadline = nil
        finishDeadline?.cancel(); finishDeadline = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        pending.removeAll(keepingCapacity: false)
        continuation?.resume(with: result)
        continuation = nil
    }

    deinit {
        connectionDeadline?.cancel()
        finishDeadline?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }
}
