import Foundation

/// The Corbado Observe tracker. Obtain via `CorbadoObserve.initialize`; one instance per process.
///
/// Every public method is main-safe and non-blocking (fire-and-forget into the SDK's ordered
/// mailbox, consumed by a single task — call order is recording order) and guaranteed never to
/// throw into the host app — failures are logged and reported to the diagnostic telemetry
/// stream instead.
public final class ObserveTracker: Sendable {
    typealias Job = @Sendable (isolated TrackerCore) async -> Void

    private let options: ObserveOptions
    private let logger: ObserveLogger
    private let core: TrackerCore
    private let jobs: AsyncStream<Job>.Continuation
    private let pump: Task<Void, Never>

    private let configBox = Locked<SdkConfig>(.default)
    private let sessionIdBox = Locked<String?>(nil)
    private let currentScreenBox = Locked<String?>(nil)
    private let collectionEnabledBox = Locked(true)
    private let destroyedBox = Locked(false)
    private let lifecycleWatcher = Locked<AppLifecycleWatcher?>(nil)

    let autofillEngine = AutofillEngine()

    init(
        options: ObserveOptions, transport: (any Transporting)? = nil,
        configTransport: (any ConfigTransporting)? = nil
    ) {
        self.options = options
        let logger = ObserveLogger(debug: options.debug)
        self.logger = logger

        let (stream, continuation) = AsyncStream<Job>.makeStream()
        jobs = continuation

        let core = TrackerCore(
            options: options,
            logger: logger,
            transport: transport
                ?? HttpTransport(url: options.eventsURL!, logger: logger),  // validated at initialize
            configTransport: configTransport,
            configBox: configBox,
            sessionIdBox: sessionIdBox,
            signal: { queueSignal in
                continuation.yield { core in core.handleQueueSignal(queueSignal) }
            })
        self.core = core

        // The single mailbox consumer: FIFO order across all public calls.
        pump = Task {
            for await job in stream {
                await job(core)
            }
        }
    }

    func start(after previousShutdown: Task<Void, Never>? = nil) {
        autofillEngine.attach(self)
        post { core in
            // A replacement can accept calls immediately, but must wait for the prior
            // owner's retries before opening the shared preferences and outbox.
            await previousShutdown?.value
            core.start()
        }

        // Registered synchronously (NotificationCenter registration is thread-safe and cheap)
        // so destroy() can always unregister — a deferred registration would race it.
        let watcher = AppLifecycleWatcher(
            onForeground: { [weak self] in self?.post { core in core.checkRotation() } },
            onBackground: { [weak self] in self?.handleBackground() },
            onResignActive: { [weak self] in self?.autofillEngine.windowBlur() },
            onBecomeActive: { [weak self] in self?.autofillEngine.windowFocus() })
        lifecycleWatcher.value = watcher
        watcher.register()

        Task { @MainActor [weak self] in
            guard let self, !destroyedBox.value else { return }
            let deviceInfo = DeviceInfoCollector.collect()
            post { core in core.setDeviceInfo(deviceInfo) }
        }
    }

    @MainActor
    private func handleBackground() {
        if destroyedBox.value { return }
        autofillEngine.flushBatches()
        guard options.flushOnBackground, configBox.value.flushOnBackground else { return }
        let finish = beginBackgroundGrace()
        post { core in
            core.flush(.background, onFinished: finish)
        }
    }

    // MARK: - Flow-level events

    /// Application tag, attached to flow-starting events (web parity: `applicationId` rides as a
    /// lowercased tag so several apps reporting into one project stay distinguishable).
    private func applicationTag() -> [String: String] {
        options.applicationId.map { ["applicationId": $0.lowercased()] } ?? [:]
    }

    public func flowStarted(
        _ flowName: String,
        touchpoint: String? = nil,
        tags: [String: String]? = nil,
        options: StepOptions? = nil
    ) {
        var data: [String: JSONValue] = ["flowName": .string(flowName)]
        data.putIfPresent("touchpoint", touchpoint)
        let merged = applicationTag().merging(tags ?? [:]) { _, explicit in explicit }
        track(.flowStarted, data, tags: merged.isEmpty ? nil : merged, stepOptions: options)
    }

    /// Multi-flow variant for touchpoints where the user can choose between flows.
    public func flowStartedMulti(
        _ flowNames: [String],
        defaultFlowName: String? = nil,
        touchpoint: String? = nil,
        tags: [String: String]? = nil,
        options: StepOptions? = nil
    ) {
        var data: [String: JSONValue] = ["flowNames": .array(flowNames.map(JSONValue.string))]
        data.putIfPresent("defaultFlowName", defaultFlowName)
        data.putIfPresent("touchpoint", touchpoint)
        let merged = applicationTag().merging(tags ?? [:]) { _, explicit in explicit }
        track(.flowStarted, data, tags: merged.isEmpty ? nil : merged, stepOptions: options)
    }

    public func flowDecided(_ flowName: String, tags: [String: String]? = nil, options: StepOptions? = nil) {
        track(.flowDecided, ["flowName": .string(flowName)], tags: tags, stepOptions: options)
    }

    public func flowFinished(
        _ flowName: String,
        explicitOutcome: String? = nil,
        tags: [String: String]? = nil,
        options: StepOptions? = nil
    ) {
        var data: [String: JSONValue] = ["flowName": .string(flowName)]
        data.putIfPresent("explicitOutcome", explicitOutcome)
        putUserReference(&data, options?.userReference)
        track(.flowFinished, data, tags: tags, stepOptions: options, finishedFlowName: flowName)
    }

    public func flowReset(_ flowName: String? = nil, tags: [String: String]? = nil, options: StepOptions? = nil) {
        var data: [String: JSONValue] = [:]
        data.putIfPresent("flowName", flowName)
        track(.flowReset, data, tags: tags, stepOptions: options, endsFlow: true)
    }

    public func flowAutoFinished(
        _ flowName: String,
        finishedByFlowName: String,
        tags: [String: String]? = nil,
        options: StepOptions? = nil
    ) {
        var data: [String: JSONValue] = [
            "flowName": .string(flowName),
            "finishedByFlowName": .string(finishedByFlowName),
        ]
        putUserReference(&data, options?.userReference)
        track(.flowAutoFinished, data, tags: tags, stepOptions: options, finishedFlowName: flowName)
    }

    // MARK: - Decision events

    public func authMethodDecisionStarted(
        _ decisionName: String,
        decisionOptions: [String],
        explicitDecisionValue: String? = nil,
        options: StepOptions? = nil
    ) {
        track(
            .authMethodDecisionStarted,
            decisionData(decisionName, decisionOptions, explicitDecisionValue),
            stepOptions: options)
    }

    /// Omitting options completes the retained offer with the same decision name. An explicit
    /// empty array means no offered choices and does not inherit the earlier offer.
    public func authMethodDecisionFinished(
        _ decisionName: String,
        decisionOptions: [String]? = nil,
        explicitDecisionValue: String? = nil,
        options: StepOptions? = nil
    ) {
        track(
            .authMethodDecisionFinished,
            decisionData(decisionName, decisionOptions, explicitDecisionValue),
            stepOptions: options)
    }

    public func authDecisionStarted(
        _ decisionName: String,
        decisionOptions: [String],
        options: StepOptions? = nil
    ) {
        track(.authDecisionStarted, decisionData(decisionName, decisionOptions, nil), stepOptions: options)
    }

    public func authDecisionFinished(
        _ decisionName: String,
        decisionOptions: [String],
        explicitDecisionValue: String? = nil,
        options: StepOptions? = nil
    ) {
        track(
            .authDecisionFinished,
            decisionData(decisionName, decisionOptions, explicitDecisionValue),
            stepOptions: options)
    }

    private func decisionData(
        _ decisionName: String, _ decisionOptions: [String]?, _ explicitDecisionValue: String?
    ) -> [String: JSONValue] {
        var data: [String: JSONValue] = [
            "decisionName": .string(decisionName)
        ]
        if let decisionOptions {
            data["options"] = .array(decisionOptions.map(JSONValue.string))
        }
        data.putIfPresent("explicitDecisionValue", explicitDecisionValue)
        return data
    }

    // MARK: - Subflow events (used by operations)

    func trackSubflowStarted(_ subflowType: SubflowType, data: [String: JSONValue], options: StepOptions?) {
        var payload = data
        payload["subflowType"] = .string(subflowType.rawValue)
        track(.subflowStarted, payload, stepOptions: options)
    }

    func trackSubflowStepStarted(
        _ subflowType: SubflowType,
        stepName: String,
        data: [String: JSONValue],
        options: StepOptions?,
        ignoreAsInteraction: Bool?
    ) {
        // A step starting implies any typing stretch ended — flush the field input batches.
        autofillEngine.flushBatches()
        var payload: [String: JSONValue] = [
            "subflowType": .string(subflowType.rawValue),
            "stepName": .string(stepName),
            "stepData": .object(data),
        ]
        if let ignoreAsInteraction { payload["ignoreAsInteraction"] = .bool(ignoreAsInteraction) }
        track(.subflowStepStarted, payload, stepOptions: options)
    }

    func trackSubflowStepFinished(
        _ subflowType: SubflowType, stepName: String, data: [String: JSONValue], options: StepOptions?
    ) {
        track(
            .subflowStepFinished,
            [
                "subflowType": .string(subflowType.rawValue),
                "stepName": .string(stepName),
                "stepData": .object(data),
            ],
            stepOptions: options)
    }

    func trackSubflowStepError(
        _ subflowType: SubflowType, stepName: String, data: [String: JSONValue], options: StepOptions?
    ) {
        track(
            .subflowStepError,
            [
                "subflowType": .string(subflowType.rawValue),
                "stepName": .string(stepName),
                "stepData": .object(data),
            ],
            stepOptions: options)
    }

    func trackSubflowFinished(_ subflowType: SubflowType, data: [String: JSONValue], options: StepOptions?) {
        track(
            .subflowFinished,
            ["subflowType": .string(subflowType.rawValue), "stepData": .object(data)],
            stepOptions: options)
    }

    func trackSubflowError(_ subflowType: SubflowType, data: [String: JSONValue], options: StepOptions?) {
        track(
            .subflowError,
            ["subflowType": .string(subflowType.rawValue), "stepData": .object(data)],
            stepOptions: options)
    }

    // MARK: - Custom events, telemetry

    public func trackCustom(_ name: String, data: [String: JSONValue] = [:], options: StepOptions? = nil) {
        track(nil, data, customName: name, stepOptions: options)
    }

    /// Record a diagnostic telemetry entry (level `"info"` or `"error"`). Never an auth event.
    public func telemetry(level: String, message: String) {
        if !collectionEnabledBox.value || destroyedBox.value {
            logger.debug("Skipping telemetry: collection is disabled.")
            return
        }
        post { core in core.reportTelemetry(level: level, message: message) }
    }

    public func logInfo(_ message: String) { telemetry(level: "info", message: message) }

    public func logError(_ message: String) { telemetry(level: "error", message: message) }

    // MARK: - Low events

    /// Record a low event: high-volume ambient UI evidence (autofill affordances, bulk fills)
    /// that rides in the `lows` array of the next batch and never participates in flow
    /// classification directly. Never put field values (or anything that reconstructs them) into
    /// a low.
    ///
    /// - Parameter fieldType: Semantic field the low relates to, named by subflow-type vocabulary
    ///   (`provide-identifier`, `password-login`, `sms-otp`, ...), when field-scoped.
    /// - Parameter actor: Who caused the observed effect, when known (`password-manager`, `app`).
    /// - Parameter explicitTimestamp: Event time override for lows describing a past stretch
    ///   (e.g. a batched typing run).
    public func low(
        _ lowType: String,
        fieldType: String? = nil,
        actor: String? = nil,
        durationMs: Int64? = nil,
        explicitTimestamp: Int64? = nil
    ) {
        if !collectionEnabledBox.value || destroyedBox.value {
            logger.debug("Skipping low event \"\(lowType)\": collection is disabled.")
            return
        }
        let low = WireLowEvent(
            lowType: lowType,
            ts: explicitTimestamp ?? Int64(Date().timeIntervalSince1970 * 1000),
            durationMs: durationMs,
            fieldType: fieldType,
            actor: actor)
        post { core in core.reportLow(low) }
    }

    /// Field-observation handles are obtained from the operations (e.g. `passwordField`).
    func fieldObserver(_ fieldType: String) -> FieldObserver {
        FieldObserver(engine: autofillEngine, fieldType: fieldType)
    }

    // MARK: - Session & lifecycle

    /// Current session id; nil until initialization completed on the SDK actor.
    public func getSessionId() -> String? { sessionIdBox.value }

    /// Rotate to a fresh session (asynchronous; observe the new id via `getSessionId`).
    public func resetSession() {
        if destroyedBox.value { return }
        post { core in core.resetSession() }
    }

    /// Set the current screen name, attached to subsequent events as `meta.trackingSourcePath`
    /// (the native counterpart of the web SDK's page path). Pass nil to stop attaching.
    public func setScreen(_ screenName: String?) {
        currentScreenBox.value = screenName
    }

    /// Flush pending events now (e.g. before an expected process kill).
    public func flush() {
        if destroyedBox.value { return }
        post { core in core.flush(.manual) }
    }

    /// Pause/resume event collection. While disabled, every tracking call (flow, decision,
    /// subflow/operation, custom, telemetry) is silently dropped at the source — nothing new is
    /// recorded anywhere, not even into the durable outbox. Events collected earlier still ship
    /// normally; use `setTransportEnabled` to control sending independently.
    ///
    /// The switch is runtime-only and not persisted — the host re-applies its consent/kill state
    /// after init on each launch.
    public func setCollectionEnabled(_ enabled: Bool) {
        collectionEnabledBox.value = enabled
    }

    /// Pause/resume transmission. While disabled, events keep collecting into the durable outbox
    /// (bounded) but nothing is sent — for networkless modes or host-controlled quiet phases.
    public func setTransportEnabled(_ enabled: Bool) {
        if destroyedBox.value { return }
        post { core in core.setTransportEnabled(enabled) }
    }

    // MARK: - Operations

    public func passwordLoginOperation() -> PasswordLoginOperation { PasswordLoginOperation(tracker: self) }

    /// Operation for the system credential chooser (`ASAuthorizationController`
    /// with several request types). Passkey-only ceremonies belong to the passkey-login
    /// operation instead.
    public func systemCredentialOperation() -> SystemCredentialOperation {
        SystemCredentialOperation(tracker: self)
    }

    /// Operation for passkey-only assertion ceremonies.
    public func passkeyLoginOperation() -> PasskeyLoginOperation { PasskeyLoginOperation(tracker: self) }

    /// Operation for passkey registration ceremonies.
    public func passkeyEnrollmentOperation() -> PasskeyEnrollmentOperation {
        PasskeyEnrollmentOperation(tracker: self)
    }

    /// Operation for the identifier form (email/phone entry).
    public func provideIdentifierOperation() -> ProvideIdentifierOperation {
        ProvideIdentifierOperation(tracker: self)
    }

    /// Operation for dedicated social provider button flows.
    public func socialLoginOperation() -> SocialLoginOperation { SocialLoginOperation(tracker: self) }

    /// Operation for email OTP verification.
    public func emailOtpOperation() -> EmailOtpOperation { EmailOtpOperation(tracker: self) }

    /// Operation for SMS OTP verification.
    public func smsOtpOperation() -> SmsOtpOperation { SmsOtpOperation(tracker: self) }

    /// Operation for non-credential data submissions (signup form fields, profile data).
    public func provideDataOperation() -> ProvideDataOperation { ProvideDataOperation(tracker: self) }

    /// Operation for setting a new password (signup or recovery/reset).
    public func passwordEnrollmentOperation() -> PasswordEnrollmentOperation {
        PasswordEnrollmentOperation(tracker: self)
    }

    /// Untyped operation for subflow types without a dedicated operation class yet. Step names
    /// are the caller's responsibility — they must match the vocabulary the backend classifier
    /// knows.
    public func operation(_ subflowType: SubflowType) -> GenericOperation {
        GenericOperation(tracker: self, subflowType: subflowType)
    }

    func destroy() {
        if destroyedBox.withLock({ destroyed -> Bool in
            let already = destroyed
            destroyed = true
            return already
        }) {
            return
        }
        lifecycleWatcher.value?.unregister()
        // Work posted before destroy still runs first (FIFO) — that's the "flushes pending
        // events" contract; the destroy job is the mailbox's last element.
        jobs.yield { core in await core.destroyCore() }
        jobs.finish()
    }

    /// Completes when the mailbox has fully drained after `destroy()` (test hook — production
    /// code never needs to wait on the pump).
    func awaitTermination() async {
        await pump.value
    }

    // MARK: - Core

    private func post(_ job: @escaping Job) {
        jobs.yield(job)
    }

    private func track(
        _ name: AuthEventName?,
        _ data: [String: JSONValue],
        customName: String? = nil,
        tags: [String: String]? = nil,
        stepOptions: StepOptions? = nil,
        finishedFlowName: String? = nil,
        endsFlow: Bool = false
    ) {
        // Dropped before a seq is minted, so the switch never creates server-visible gaps.
        // `destroyed` is checked HERE, not in the posted job: work posted before destroy() must
        // still run before destroy's final flush (FIFO); only calls made after destroy no-op.
        if !collectionEnabledBox.value || destroyedBox.value {
            logger.debug("Skipping event \"\(customName ?? name?.rawValue ?? "?")\": collection is disabled.")
            return
        }

        // Flow finished or reset: the auth surface is done — flush field evidence.
        if finishedFlowName != nil || endsFlow { autofillEngine.flushBatches() }

        // Capture at call site so ordering reflects call order, not scheduling order.
        let timestamp = stepOptions?.explicitTimestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
        let id = Uuid.v7()
        let screen = currentScreenBox.value
        let merged = options.defaultTags.merging(tags ?? [:]) { _, explicit in explicit }
        let eventName = customName ?? name?.rawValue ?? ""
        let type = customName != nil ? "custom" : "predefined"
        let user = stepOptions?.userReference

        post { core in
            core.record(
                id: id,
                timestamp: timestamp,
                type: type,
                name: eventName,
                data: data,
                user: user,
                tags: merged.isEmpty ? nil : merged,
                screen: screen,
                finishedFlowName: finishedFlowName)
        }
    }

    private func putUserReference(_ data: inout [String: JSONValue], _ user: UserReference?) {
        guard let user else { return }
        data.putIfPresent("userId", user.userId)
        data.putIfPresent("identifier", user.identifier)
        data.putIfPresent("crossEnvironmentTransactionID", user.crossEnvironmentTransactionID)
    }
}
