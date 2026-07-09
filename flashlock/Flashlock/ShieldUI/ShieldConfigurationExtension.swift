import FlashlockCore
import ManagedSettings
import ManagedSettingsUI
import UIKit

/// Custom shield appearance (docs/02-architecture.md §2.2).
///
/// A fresh instance is created per query and the system silently falls back to
/// the default "Restricted" shield if the configuration returns too slowly —
/// so this reads one small blob from the App Group and returns synchronously.
/// Copy is deliberately generic enough to survive the known stale-cache bug
/// (shield config is not re-queried while the target app stays foregrounded);
/// exact live numbers belong in the app, not on the shield.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        flashlockConfiguration()
    }

    override func configuration(
        shielding application: Application, in category: ActivityCategory
    ) -> ShieldConfiguration {
        flashlockConfiguration()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        flashlockConfiguration()
    }

    override func configuration(
        shielding webDomain: WebDomain, in category: ActivityCategory
    ) -> ShieldConfiguration {
        flashlockConfiguration()
    }

    /// One configuration for all four cases: the shield never varies by token
    /// (tokens are opaque and can rotate; per-app copy is not worth the risk).
    private func flashlockConfiguration() -> ShieldConfiguration {
        let policy = SharedStore().unlockPolicy
        let title = ShieldConfiguration.Label(text: "Time's up", color: .white)
        let subtitle = ShieldConfiguration.Label(
            text: "Clear \(policy.cardCount) cards to earn "
                + "\(policy.minutesGranted) more minutes",
            color: .white
        )
        let primary = ShieldConfiguration.Label(text: "Practice to unlock", color: .white)

        // Static colors and an SF Symbol icon: no asset catalog dependency
        // (PDF assets in shield extensions are a known way to break the whole
        // configuration and get the default shield).
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            backgroundColor: UIColor.black.withAlphaComponent(0.5),
            icon: UIImage(systemName: "brain.head.profile"),
            title: title,
            subtitle: subtitle,
            primaryButtonLabel: primary,
            primaryButtonBackgroundColor: UIColor.systemIndigo,
            secondaryButtonLabel: nil  // nil hides the secondary button entirely
        )
    }
}
