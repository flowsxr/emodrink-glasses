//
// HermesGlassesApp.swift
// Hermes Glasses - Talk to Hermes AI from Meta Ray-Ban glasses
//
// Main entry point. Configures the Meta Wearables DAT SDK, sets up
// audio capture from the glasses, and connects to Hermes Agent for
// real-time voice conversation.
//

import MWDATCore
import SwiftUI
import os

#if DEBUG
import MWDATMockDevice
#endif

private let logger = Logger(subsystem: "com.flowsxr.emodrink", category: "startup")

@main
struct HermesGlassesApp: App {
    /// The one path to the glasses (session, display, camera), proven on
    /// device by the Glasses basics tests and shared by everything else.
    @State private var glassesLink: GlassesLink
    /// Settings › Glasses › Developer › Glasses basics (the three tests).
    @State private var basicsViewModel: GlassesBasicsViewModel
    @State private var wearablesViewModel: WearablesViewModel
    @State private var hermesSessionViewModel: HermesSessionViewModel
    @State private var emoDrinkViewModel: EmoDrinkViewModel
    /// The showcase autopilot (Taka's Start), driven by the root screen.
    @State private var showcaseViewModel: ShowcaseViewModel
    @State private var permissions = PermissionsCoordinator()

    /// First launch runs the three-step wizard (glasses → permissions →
    /// ready) so nobody meets a bare system dialog with no explanation.
    @AppStorage("onboarding_complete") private var onboardingComplete = false

    // Light/dark override, applied to the whole window (see AppearanceMode).
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw =
        AppearanceMode.system.rawValue
    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    init() {
        // Step 0: the gift build's bundled assistant key. First, so the
        // session view model created below reads the seeded provider,
        // model and key in its reloadDirectProviderState(). Never
        // overwrites a key the user typed.
        BundledAIKey.seedIfNeeded()

        // Step 1: Configure the DAT SDK once at launch
        do {
            try Wearables.configure()
        } catch {
            // Unconditional: a release build with a broken SDK config should
            // still leave a breadcrumb, not just the DEBUG console.
            logger.error("Failed to configure Wearables SDK: \(error.localizedDescription, privacy: .public)")
            NSLog("[Basics] Wearables.configure() failed: %@", error.localizedDescription)
        }

        #if DEBUG
        // Enable MockDeviceKit for testing without physical glasses
        if ProcessInfo.processInfo.arguments.contains("--mock-device") {
            MockDeviceKit.shared.enable(
                config: MockDeviceKitConfig(initiallyRegistered: false)
            )
        }
        #endif

        let wearables = Wearables.shared
        let link = GlassesLink(wearables: wearables)
        self._glassesLink = State(wrappedValue: link)
        self._basicsViewModel = State(wrappedValue: GlassesBasicsViewModel(link: link))
        self._wearablesViewModel = State(
            wrappedValue: WearablesViewModel(wearables: wearables)
        )
        let session = HermesSessionViewModel(wearables: wearables, glassesLink: link)
        self._hermesSessionViewModel = State(wrappedValue: session)
        let emoDrink = EmoDrinkViewModel(hermesVM: session)
        self._emoDrinkViewModel = State(wrappedValue: emoDrink)
        let showcaseDirectory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("showcase", isDirectory: true)
        self._showcaseViewModel = State(wrappedValue: ShowcaseViewModel(
            hermesVM: session,
            catalog: DrinkCatalog.bundled(),
            store: MachineStore(directory: showcaseDirectory),
            stopLiveDrinkMode: { [weak emoDrink] in emoDrink?.stopForShowcase() }))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                ContentView(
                    wearablesVM: wearablesViewModel,
                    hermesVM: hermesSessionViewModel,
                    emoDrinkVM: emoDrinkViewModel,
                    showcaseVM: showcaseViewModel,
                    basicsVM: basicsViewModel
                )
                // Handle Meta AI URL callback after registration
                .onOpenURL { url in
                    Task {
                        _ = try? await Wearables.shared.handleUrl(url)
                    }
                }
                .alert("EmoDrink Error", isPresented: $hermesSessionViewModel.showError) {
                    Button("OK") { hermesSessionViewModel.dismissError() }
                } message: {
                    Text(hermesSessionViewModel.errorMessage)
                }
                // Separate surface, deliberately not titled as a fault: a
                // fallback that worked ("using the iPhone mic") is news, not
                // an error, and the Error alert said otherwise.
                .alert("EmoDrink", isPresented: $hermesSessionViewModel.showNotice) {
                    if let action = hermesSessionViewModel.noticeAction {
                        Button(action.title) { hermesSessionViewModel.performNoticeAction() }
                    }
                    Button("OK") { hermesSessionViewModel.dismissNotice() }
                } message: {
                    Text(hermesSessionViewModel.noticeMessage)
                }
            }
            // A cover, not a sibling: as a sibling it laid out UNDER the
            // session screen, leaving half the app visible above it.
            //
            // Gated on `onboardingComplete`: onboarding's own glasses step
            // can also drive `registrationState` to `.registering` (its
            // "Connect Glasses" button), and it already shows its own
            // inline waiting state (OnboardingView.swift:75-82) for exactly
            // that. Without the gate, two full-screen covers wanted to
            // present at once.
            .fullScreenCover(isPresented: Binding(
                get: {
                    onboardingComplete
                        && wearablesViewModel.registrationState == .registering
                },
                set: { _ in }
            )) {
                RegistrationInProgressView(viewModel: wearablesViewModel)
            }
            // Force light/dark for the whole window (sheets included).
            .preferredColorScheme(appearance.colorScheme)
            .fullScreenCover(isPresented: Binding(
                get: { !onboardingComplete },
                set: { onboardingComplete = !$0 }
            )) {
                OnboardingView(
                    wearablesVM: wearablesViewModel,
                    hermesVM: hermesSessionViewModel,
                    permissions: permissions
                ) { _ in
                    // Onboarding lands on the showcase home with nothing
                    // running: Taka starts a run with Start, and live drink
                    // mode starts when its own screen opens (Ruling 3).
                    onboardingComplete = true
                }
            }
        }
    }
}
