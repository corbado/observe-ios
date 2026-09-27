import CorbadoObserve
import SwiftUI

@main
struct ObserveExampleApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

/// Host state: which situation screen is showing, whether its flow is active, devbar settings.
/// The screen-independent flow choreography (start / reset / mid-flow navigation / success)
/// lives here so screens only emit their own situation's events.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tracker: ObserveTracker?
    @Published private(set) var screen: SituationScreen
    @Published private(set) var flowActive = false
    @Published var autoStartFlow = ObserveEnv.autoStartFlow { didSet { ObserveEnv.autoStartFlow = autoStartFlow } }
    @Published var rpId = ObserveEnv.rpId { didSet { ObserveEnv.rpId = rpId } }
    @Published var offerEnrollment = ObserveEnv.offerEnrollment {
        didSet { ObserveEnv.offerEnrollment = offerEnrollment }
    }
    @Published var devBarOpen = false
    /// Bumped when the tracker is replaced so the current screen is rebuilt on the new one.
    @Published private(set) var trackerGeneration = 0
    @Published private(set) var lastLoginIdentifier: String?

    let backend = FakeAuthBackend()
    let webAuthn = FakeWebAuthn()
    private var lastStartScreenId = ScreenRegistry.default.id

    init() {
        tracker = ObserveEnv.initTracker()
        LifecycleProbe.shared.install()
        screen = ScreenRegistry.byId(ObserveEnv.currentScreenId)
        Probe.currentScreen = screen.id
        tracker?.setScreen(screen.id)
        Probe.log("app_launch")
    }

    /// Remembered-identifier screens use the first account; the enrollment offer belongs to
    /// whoever just logged in.
    var rememberedIdentifier: String {
        if screen.id == "enrollment-offer", let lastLoginIdentifier { return lastLoginIdentifier }
        return backend.accounts().first ?? "user@example.com"
    }

    func context() -> ScreenContext {
        ScreenContext(
            tracker: tracker,
            backend: backend,
            webAuthn: webAuthn,
            rpId: rpId,
            flowActive: flowActive,
            rememberedIdentifier: rememberedIdentifier,
            navigate: { [weak self] in self?.navigateWithinFlow($0) },
            loginSuccess: { [weak self] in self?.onLoginSuccess($0) },
            lastLoginIdentifier: lastLoginIdentifier,
            restartFlow: { [weak self] in self?.restartFlow() })
    }

    func startFlow(_ target: SituationScreen) {
        guard let tracker, let flowName = target.flowName else { return }
        tracker.setScreen(target.id)
        lastStartScreenId = target.id
        // Remembered-identifier screens: the user is known on flow_started.
        let options: StepOptions? =
            target.rememberedIdentifier
            ? StepOptions(
                userReference: UserReference(
                    userId: backend.userIdFor(rememberedIdentifier), identifier: rememberedIdentifier))
            : nil
        tracker.flowStarted(flowName, touchpoint: target.id, options: options)
        Probe.log("flow_start", ["flow": flowName])
        flowActive = true
    }

    func switchScreen(_ target: SituationScreen) {
        if flowActive, let flowName = screen.flowName {
            tracker?.flowReset(flowName)
        }
        flowActive = false
        show(target)
        if autoStartFlow { startFlow(target) }
    }

    /// Mid-flow navigation: same flow, no reset, no new flow start.
    func navigateWithinFlow(_ screenId: String) {
        let target = ScreenRegistry.byId(screenId)
        show(target)
        Probe.log("navigate", ["to": target.id])
    }

    /// Login completed (flow_finished already emitted): land on the success screen or, when the
    /// "server" decides so, on the post-login enrollment offer first (a NEW enrollment flow
    /// auto-starts there). Coming FROM the offer always ends on the success screen.
    func onLoginSuccess(_ identifier: String?) {
        lastLoginIdentifier = identifier
        flowActive = false
        if screen.id != "enrollment-offer", let identifier, offerEnrollment, !rpId.isEmpty,
            !webAuthn.hasPasskey(identifier)
        {
            let offer = ScreenRegistry.byId("enrollment-offer")
            show(offer)
            startFlow(offer)
            return
        }
        show(ScreenRegistry.byId("login-success"))
    }

    /// Success screen's "Run again": back to the finished flow's start screen, fresh flow.
    func restartFlow() {
        switchScreen(ScreenRegistry.byId(lastStartScreenId))
    }

    /// Swaps the tracker; an open flow restarts on the new one (its screen is rebuilt, so the
    /// operations bound to the destroyed tracker go with it).
    func applyEnv(apiBaseUrl: String, projectId: String) {
        tracker = ObserveEnv.apply(apiBaseUrl: apiBaseUrl, projectId: projectId)
        tracker?.setScreen(screen.id)
        trackerGeneration += 1
        if flowActive { startFlow(screen) }
    }

    private func show(_ target: SituationScreen) {
        screen = target
        ObserveEnv.currentScreenId = target.id
        tracker?.setScreen(target.id)
        Probe.currentScreen = target.id
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            model.screen.content(model.context())
                .id("\(model.screen.id)#\(model.trackerGeneration)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                model.devBarOpen = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Theme.ink, in: Circle())
            }
            .padding(20)
            .accessibilityLabel("Devbar")
        }
        .sheet(isPresented: $model.devBarOpen) { DevBarSheet(model: model) }
        .task {
            // Auto-start the persisted screen's flow on a cold start.
            if model.autoStartFlow, !model.flowActive { model.startFlow(model.screen) }
        }
    }
}
