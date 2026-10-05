import Foundation

/// The SDK's single serialization domain. All mutable tracking state (session, buffers, outbox,
/// queue, config snapshot) lives here; the public `ObserveTracker` posts ordered jobs into it via
/// its mailbox and never blocks the caller.
actor TrackerCore {
    let logger: ObserveLogger
    private let transport: any Transporting
    private let options: ObserveOptions
    private let prefs = ObservePrefs()

    /// Boot snapshot mirror: written once in `start()`, read synchronously by the lifecycle
    /// watcher and the buffers' gate closures without hopping onto the actor.
    private let configBox: Locked<SdkConfig>
    private let sessionIdBox: Locked<String?>
    /// Live data policy code, also written synchronously by `ObserveTracker.setDataPolicy`.
    private let dataPolicyBox: Locked<Int?>

    let session: SessionManager
    let telemetryBuffer: TelemetryBuffer
    let lowBuffer: LowBuffer
    private let outbox: Outbox
    private let queue: EventQueue
    private var deliveryTask: Task<Void, Never>?
    private var deliveryCompletions: [@Sendable () -> Void] = []

    /// Device info snapshot; nil until the async collection at init completes.
    private var deviceInfoData: WireDeviceInfoDataApp?
    private var deviceInfoLastAttachedAt: Int64 = 0
    private var clientEnvHandle = ""
    private var clientEnvHandleCreatedAt: Int64 = 0

    init(
        options: ObserveOptions,
        logger: ObserveLogger,
        transport: any Transporting,
        configBox: Locked<SdkConfig>,
        sessionIdBox: Locked<String?>,
        dataPolicyBox: Locked<Int?>,
        signal: @escaping @Sendable (QueueSignal) -> Void
    ) {
        self.transport = transport
        self.options = options
        self.logger = logger
        self.configBox = configBox
        self.sessionIdBox = sessionIdBox
        self.dataPolicyBox = dataPolicyBox

        session = SessionManager(prefs: prefs, inactivityWindowMs: { configBox.value.sessionInactivityMs })
        telemetryBuffer = TelemetryBuffer(
            enabled: { configBox.value.telemetry }, currentSessionId: { sessionIdBox.value })
        lowBuffer = LowBuffer(
            enabled: { configBox.value.lows }, currentSessionId: { sessionIdBox.value })

        // Directory resolution is deferred into the closure: the constructor runs on the
        // caller's thread during init, which must stay free of disk I/O (main-safety).
        outbox = Outbox(
            directory: {
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("corbado_observe", isDirectory: true)
            },
            logger: logger)

        let prefs = prefs
        queue = EventQueue(
            transport: transport,
            outbox: outbox,
            config: { configBox.value },
            dataPolicy: { dataPolicyBox.value },
            sdkInfo: WireSdkInfo(name: Sdk.name, version: Sdk.version),
            telemetryBuffer: telemetryBuffer,
            lowBuffer: lowBuffer,
            logger: logger,
            onConfigReceived: { body in prefs.sdkConfigJson = body },
            signal: signal)
    }

    func start() {
        // First disk access of the SDK: resolve the config boot snapshot (must precede
        // everything that reads config, i.e. session rotation and the queue timer).
        configBox.value = prefs.sdkConfigJson.flatMap(SdkConfig.parse) ?? .default

        session.start()
        sessionIdBox.value = session.sessionId

        if let handle = prefs.clientEnvHandle {
            clientEnvHandle = handle
        } else {
            clientEnvHandle = Uuid.v7()
            prefs.clientEnvHandle = clientEnvHandle
            prefs.clientEnvHandleCreatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        }
        clientEnvHandleCreatedAt = prefs.clientEnvHandleCreatedAt

        // A code set since init (option or setDataPolicy) overlays the persisted one and is
        // persisted by its own job.
        let persisted = prefs.dataPolicy(projectId: options.projectId)
        dataPolicyBox.withLock { code in
            if code == nil { code = persisted }
        }

        queue.start()
    }

    /// Writes the current code, never clears it.
    func persistDataPolicy() {
        guard let code = dataPolicyBox.value else { return }
        prefs.setDataPolicy(code, projectId: options.projectId)
    }

    func setDeviceInfo(_ data: WireDeviceInfoDataApp) {
        deviceInfoData = data
    }

    // swiftlint:disable:next function_parameter_count
    func record(
        id: String,
        timestamp: Int64,
        type: String,
        name: String,
        data: [String: JSONValue],
        user: UserReference?,
        tags: [String: String]?,
        screen: String?,
        finishedFlowName: String?
    ) {
        let event = WireEvent(
            id: id,
            timestamp: timestamp,
            seq: session.nextSeq(),
            type: type,
            name: name,
            // Redact WebAuthn completion material (login signature, enrollment challenge)
            // before it can enter the event, outbox, or transport.
            data: .object(WebAuthnSanitizer.sanitize(data)),
            user: user.map {
                WireUserReference(
                    userId: $0.userId,
                    identifier: $0.identifier,
                    crossEnvironmentTransactionID: $0.crossEnvironmentTransactionID)
            },
            tags: tags,
            deviceInfo: deviceInfoForEvent(),
            // tabId rides on every event (process-incarnation marker for stream splitting and
            // seq disambiguation); the screen name only when set.
            meta: WireEventMeta(trackingSourcePath: screen, tabId: session.processId))
        logger.debug("Track: \(event.name) \(WireJson.encodeToString(event))")
        queue.enqueue(sessionId: session.sessionId, event: event, finishedFlowName: finishedFlowName)
    }

    func handleQueueSignal(_ signal: QueueSignal) {
        switch signal {
        case .timerTick: flush(.timer)
        case .recoveryFlush: flush(.recovery)
        case .flowFinishedFlush: flush(.flowFinished)
        }
    }

    /// Delivery shares this actor's state, but not the mailbox's consumer task. While HTTP
    /// suspends, ordered recording jobs can keep appending to the outbox. Overlapping flushes
    /// join the existing drain; background grace ends only when that delivery finishes.
    func flush(_ reason: FlushReason, onFinished: (@Sendable () -> Void)? = nil) {
        if let onFinished { deliveryCompletions.append(onFinished) }
        guard deliveryTask == nil else { return }
        deliveryTask = Task {
            await queue.flush(reason)
            deliveryTask = nil
            let completions = deliveryCompletions
            deliveryCompletions.removeAll()
            for completion in completions { completion() }
        }
    }

    func reportTelemetry(level: String, message: String) {
        telemetryBuffer.report(level, message)
        if configBox.value.flushOnTelemetry {
            flush(.telemetry)
        }
    }

    func reportLow(_ low: WireLowEvent) {
        lowBuffer.report(low)
    }

    func checkRotation() {
        session.checkRotation()
        sessionIdBox.value = session.sessionId
    }

    func resetSession() {
        sessionIdBox.value = session.reset()
    }

    func setTransportEnabled(_ enabled: Bool) {
        queue.transportEnabled = enabled
        if enabled { flush(.manual) }
    }

    func destroyCore() async {
        // This is the final mailbox job: all accepted events have reached the outbox.
        // The normal delivery task owns its entire retry chain, including backoff. Join it
        // if already running; otherwise start a drain for any still-pending events.
        queue.stopTimer()
        flush(.destroy)
        await deliveryTask?.value
        transport.shutdown()
    }

    /// Attach the device info snapshot at most once per attach interval.
    private func deviceInfoForEvent() -> WireDeviceInfo? {
        guard let data = deviceInfoData else { return nil }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if now - deviceInfoLastAttachedAt < Self.deviceInfoAttachIntervalMs { return nil }
        deviceInfoLastAttachedAt = now

        return WireDeviceInfo(
            clientEnvHandle: clientEnvHandle,
            clientEnvHandleMeta: WireClientEnvHandleMeta(timestamp: clientEnvHandleCreatedAt),
            tabId: session.processId,
            data: data)
    }

    private static let deviceInfoAttachIntervalMs: Int64 = 60_000
}
