import Cocoa
import SwiftUI

/// Authorship and version, shown as the last page of Settings.
enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–" }
    static let repositoryURL = URL(string: "https://github.com/hespinoza01/Nexo")!
    static let authorHandle = "hespinoza01"
    static let authorGitHubURL = URL(string: "https://github.com/hespinoza01")!
    /// The year it is now, not the year it was built.
    static var currentYear: Int { Calendar.current.component(.year, from: Date()) }
}

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 2) {
                Text("Nexo").font(.system(size: 18, weight: .semibold))
                Text(L("Version %@ (build %@)", AppInfo.version, AppInfo.build))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(L("Your macOS utilities in one menu bar app: window switcher, system monitor, processes and more."))
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(width: 280)
            Divider().frame(width: 280)
            VStack(spacing: 6) {
                Link(destination: AppInfo.repositoryURL) {
                    SwiftUI.Label(L("GitHub repository"), systemImage: "chevron.left.forwardslash.chevron.right").font(.system(size: 11))
                }
                Link(destination: AppInfo.authorGitHubURL) {
                    SwiftUI.Label("@\(AppInfo.authorHandle)", systemImage: "person.circle").font(.system(size: 11))
                }
            }
            Text(L("© %@ %@. Open source under GPL-3.0.", String(AppInfo.currentYear), AppInfo.authorHandle))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
    }
}
