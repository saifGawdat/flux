import Combine
import Foundation
import Observation
import Sparkle

/// In-app updates through Sparkle. Updates are read from the feed in Info.plist
/// (`SUFeedURL`) and must carry an EdDSA signature made with the key whose public half is
/// `SUPublicEDKey`. Sparkle asks the user on the second launch whether to check
/// automatically; nothing is checked before that.
@MainActor @Observable
final class Updater {
    private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: AnyCancellable?
    private(set) var canCheckForUpdates = false

    init(bundle: Bundle = .main) {
        // A bare executable (`swift run`) or a build without a feed or key can't update:
        // starting Sparkle there would only show an error.
        let info = bundle.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        // Developer instances on a scratch database don't check (unless FLUX_UPDATES=1).
        let developerInstance = env["FLUX_DATABASE"] != nil && env["FLUX_UPDATES"] != "1"
        let configured = bundle.bundleIdentifier != nil && !developerInstance
            && (info["SUFeedURL"] as? String).map { !$0.isEmpty } == true
            && (info["SUPublicEDKey"] as? String).map { !$0.isEmpty } == true
        controller = configured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        observation = controller?.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { access(keyPath: \.automaticallyChecks); return controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            withMutation(keyPath: \.automaticallyChecks) { controller?.updater.automaticallyChecksForUpdates = newValue }
        }
    }

    var automaticallyDownloads: Bool {
        get { access(keyPath: \.automaticallyDownloads); return controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            withMutation(keyPath: \.automaticallyDownloads) { controller?.updater.automaticallyDownloadsUpdates = newValue }
        }
    }

    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }
}
