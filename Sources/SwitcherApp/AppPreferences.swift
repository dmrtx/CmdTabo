import Foundation
import SwitcherCore

enum MinimizedAppsMode: String, CaseIterable {
    case hide, recentOrder, atEnd

    var title: String {
        switch self {
        case .hide: return "Hide"
        case .recentOrder: return "Show in recent order"
        case .atEnd: return "Show at the end"
        }
    }
}

struct ExcludedApplication: Codable, Equatable {
    let bundleIdentifier: String?
    let path: String
    let name: String

    var key: String { bundleIdentifier.map { "bundle:\($0)" } ?? "path:\(path)" }

    init(bundleIdentifier: String?, url: URL, name: String) {
        self.bundleIdentifier = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        path = Self.normalizedPath(url)
        self.name = name
    }

    init?(url: URL) {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url) else { return nil }
        self.init(bundleIdentifier: bundle.bundleIdentifier, url: url,
                  name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent)
    }

    func matches(bundleIdentifier: String?, bundleURL: URL?) -> Bool {
        if let saved = self.bundleIdentifier, let current = bundleIdentifier, !current.isEmpty { return saved == current }
        return bundleURL.map { Self.normalizedPath($0) == path } ?? false
    }

    private static func normalizedPath(_ url: URL) -> String {
        // Keep filesystem lookups out of catalog filtering on the main thread.
        var parts: [Substring] = []
        for part in url.path.split(separator: "/") {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else if part != "." { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
}

final class AppPreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var minimizedAppsMode: MinimizedAppsMode {
        get {
            if let raw = defaults.string(forKey: "minimizedAppsMode"), let mode = MinimizedAppsMode(rawValue: raw) { return mode }
            // Preserve the old independent filter when upgrading existing prefs.
            return (defaults.object(forKey: "excludeMinimized") as? Bool ?? true) ? .hide : .recentOrder
        }
        set {
            defaults.set(newValue.rawValue, forKey: "minimizedAppsMode")
            defaults.set(newValue == .hide, forKey: "excludeMinimized")
        }
    }

    var filterOptions: FilterOptions {
        FilterOptions(excludeMinimized: minimizedAppsMode == .hide,
                      excludeHidden: defaults.object(forKey: "excludeHidden") as? Bool ?? true,
                      excludeWindowless: defaults.object(forKey: "excludeWindowless") as? Bool ?? true)
    }

    var excludedApplications: [ExcludedApplication] {
        guard let data = defaults.data(forKey: "excludedApplications"),
              let apps = try? JSONDecoder().decode([ExcludedApplication].self, from: data) else { return [] }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func addExcludedApplications(_ apps: [ExcludedApplication]) {
        var saved = excludedApplications
        for app in apps {
            if let index = saved.firstIndex(where: {
                $0.key == app.key || $0.matches(bundleIdentifier: app.bundleIdentifier, bundleURL: URL(fileURLWithPath: app.path))
            }) {
                saved[index] = ExcludedApplication(bundleIdentifier: app.bundleIdentifier ?? saved[index].bundleIdentifier,
                                                  url: URL(fileURLWithPath: app.path), name: app.name)
            }
            else { saved.append(app) }
        }
        save(saved)
    }

    func removeExcludedApplications(keys: Set<String>) {
        save(excludedApplications.filter { !keys.contains($0.key) })
    }

    private func save(_ apps: [ExcludedApplication]) {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        defaults.set(data, forKey: "excludedApplications")
    }
}
