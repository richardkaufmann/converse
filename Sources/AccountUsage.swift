import Foundation
import SwiftUI

// Provider observations, never estimates from accumulated billing tokens or
// model-name guesses. Optional fields keep existing session archives readable.
struct ContextUsage: Codable, Equatable {
    var tokens: Int
    var capacity: Int
    var observedAt: Date
    var percent: Int { Int(min(999, (Double(tokens) / Double(capacity) * 100).rounded())) }
}
struct AccountLimit: Codable, Equatable {
    var name: String
    var usedPercent: Double
    var resetsAt: Date?
}
struct AccountUsage: Codable, Equatable {
    var context: ContextUsage?
    var contextCompactedAt: Date? = nil
    var limits: [AccountLimit] = []
    var observedAt: Date?
    var notice: String?

    static func context(tokens: Any?, capacity: Any?, at: Date) -> ContextUsage? {
        guard let used = tokens as? Int, let maximum = capacity as? Int,
              used >= 0, maximum > 0 else { return nil }
        return ContextUsage(tokens: used, capacity: maximum, observedAt: at)
    }
    static func codexContext(_ record: [String: Any]) -> ContextUsage? {
        let payload = record["payload"] as? [String: Any] ?? [:]
        guard record["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any],
              let time = record["timestamp"] as? String, let date = parseDate(time) else { return nil }
        return context(tokens: last["total_tokens"], capacity: info["model_context_window"], at: date)
    }
    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func codexLimits(_ response: [String: Any], at: Date = Date()) -> AccountUsage {
        var result = AccountUsage(observedAt: at)
        let buckets = response["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        let rows = buckets.isEmpty ? [response["rateLimits"] as? [String: Any] ?? [:]] : buckets.keys.sorted().compactMap { buckets[$0] }
        for row in rows {
            let label = row["limitName"] as? String ?? row["limitId"] as? String ?? "Account"
            for key in ["primary", "secondary"] {
                guard let window = row[key] as? [String: Any], let used = (window["usedPercent"] as? NSNumber)?.doubleValue,
                      used.isFinite, used >= 0, used <= 100 else { continue }
                let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
                let period: String
                if let minutes, minutes > 0 {
                    period = minutes % 10080 == 0 ? "\(minutes / 10080)w" : minutes % 1440 == 0 ? "\(minutes / 1440)d" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
                } else { period = key }
                let reset = ((window["resetsAt"] as? NSNumber)?.doubleValue).flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                result.limits.append(AccountLimit(name: label + " · " + period, usedPercent: used, resetsAt: reset))
            }
            if row["spendControlReached"] as? Bool == true || row["rateLimitReachedType"] is String {
                result.notice = "Provider reports an account limit reached."
            }
        }
        return result
    }
    // Claude Code reports the same subscription windows two ways: the
    // `get_usage` control request (percent, ISO reset) and each turn's
    // `rate_limit_event` (fraction, epoch reset). API-key logins report none.
    static let claudeWindows = [("five_hour", "Claude · 5h"), ("seven_day", "Claude · 1w"), ("seven_day_opus", "Opus · 1w"), ("seven_day_sonnet", "Sonnet · 1w")]
    static func claudeLimits(_ usage: [String: Any], at: Date = Date()) -> AccountUsage? {
        guard usage["rate_limits_available"] as? Bool == true, let windows = usage["rate_limits"] as? [String: Any] else { return nil }
        var result = AccountUsage(observedAt: at)
        for (key, name) in claudeWindows {
            guard let window = windows[key] as? [String: Any], let limit = claudeLimit(name, percent: window["utilization"], reset: window["resets_at"]) else { continue }
            result.limits.append(limit)
            if window["locked_reason"] is String { result.notice = "Provider reports an account limit reached." }
        }
        for scoped in windows["model_scoped"] as? [[String: Any]] ?? [] {
            guard let model = scoped["display_name"] as? String, !result.limits.contains(where: { $0.name == model + " · 1w" }),
                  let limit = claudeLimit(model + " · 1w", percent: scoped["utilization"], reset: scoped["resets_at"]) else { continue }
            result.limits.append(limit)
        }
        return result
    }
    static func claudeRateLimitEvent(_ info: [String: Any], at: Date = Date()) -> AccountUsage {
        var result = AccountUsage(observedAt: at)
        let windows = info["unifiedWindows"] as? [String: Any] ?? [:]
        for (key, name) in claudeWindows {
            guard let window = windows[key] as? [String: Any], let fraction = (window["utilization"] as? NSNumber)?.doubleValue,
                  let limit = claudeLimit(name, percent: fraction * 100, reset: window["resetsAt"]) else { continue }
            result.limits.append(limit)
        }
        // Older CLIs report only the window nearest its limit.
        if result.limits.isEmpty, let type = info["rateLimitType"] as? String, let name = claudeWindows.first(where: { $0.0 == type })?.1,
           let fraction = (info["utilization"] as? NSNumber)?.doubleValue, let limit = claudeLimit(name, percent: fraction * 100, reset: info["resetsAt"]) {
            result.limits.append(limit)
        }
        if info["status"] as? String == "rejected" { result.notice = "Provider reports an account limit reached." }
        return result
    }
    private static func claudeLimit(_ name: String, percent: Any?, reset: Any?) -> AccountLimit? {
        guard let used = (percent as? NSNumber)?.doubleValue ?? (percent as? Double), used.isFinite, used >= 0 else { return nil }
        let resetsAt: Date?
        if let seconds = (reset as? NSNumber)?.doubleValue { resetsAt = seconds.isFinite && seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil }
        else if let text = reset as? String {
            // Python-style microseconds; the system parser accepts milliseconds.
            resetsAt = parseDate(text.replacingOccurrences(of: "(\\.\\d{3})\\d+", with: "$1", options: .regularExpression))
        } else { resetsAt = nil }
        return AccountLimit(name: name, usedPercent: min(100, used), resetsAt: resetsAt)
    }
    // A newer observation replaces only the windows it reports; turn context
    // and the windows it omits stay as last measured.
    func merging(_ newer: AccountUsage) -> AccountUsage {
        var result = self
        result.limits = limits.map { old in newer.limits.first { $0.name == old.name } ?? old } + newer.limits.filter { new in !limits.contains { $0.name == new.name } }
        result.observedAt = newer.observedAt; result.notice = newer.notice
        return result
    }
    // The existing Muse CLI observer retains the original reset/observation text.
    // Only the numeric percentages are summarized; the full source stays visible.
    static func museLimits(_ text: String) -> [AccountLimit] {
        guard let regex = try? NSRegularExpression(pattern: "(?i)(current|window|weekly)\\s+(\\d+(?:\\.\\d+)?)% used") else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap {
            guard let used = Double(source.substring(with: $0.range(at: 2))), used >= 0, used <= 100 else { return nil }
            return AccountLimit(name: source.substring(with: $0.range(at: 1)).capitalized, usedPercent: used, resetsAt: nil)
        }
    }
    func warning(now: Date = Date()) -> Bool {
        notice != nil || limits.contains { $0.usedPercent >= 90 && ($0.resetsAt == nil || $0.resetsAt! > now) }
    }
}

struct AccountStatusView: View {
    var status: ToolStatus
    var refreshing: Bool
    var compact: Bool = false
    var refresh: () -> Void
    @State private var showing = false
    private var usage: AccountUsage { status.accountUsage ?? AccountUsage() }
    private var limits: [AccountLimit] { usage.limits.isEmpty ? AccountUsage.museLimits(status.quota ?? "") : usage.limits }
    private var summary: String {
        guard let highest = limits.max(by: { $0.usedPercent < $1.usedPercent }) else { return "Limits ?" }
        return "Limits \(Int(highest.usedPercent.rounded()))%"
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let old = usage.observedAt.map { timeline.date.timeIntervalSince($0) > 600 } ?? true
            let reset = limits.contains { $0.resetsAt.map { $0 <= timeline.date } ?? false }
            let warning = usage.notice != nil || limits.contains { $0.usedPercent >= 90 }
            Button { showing.toggle() } label: {
                HStack(spacing: 4) {
                    if !compact { Text("Account") }
                    Image(systemName: "circle.lefthalf.filled")
                    if !compact { Text(usage.context.map { "\($0.percent)%" } ?? "?") }
                    Image(systemName: warning ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.50percent")
                        .foregroundStyle(warning ? Color.orange : Color.secondary)
                    if !compact { Text(summary) }
                    if old || reset { Image(systemName: "clock").foregroundStyle(.secondary) }
                }
            }.buttonStyle(.plain).fixedSize()
                .accessibilityLabel("Account status. Context \(usage.context.map { "\($0.percent) percent" } ?? "unknown"). \(summary).")
                .help("Context utilization and account limits used. Click for observations, reset times, and refresh. ? means the provider has not reported this data; the clock marks old, unknown-age, or expired observations.")
                .popover(isPresented: $showing, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Account status").font(.headline)
                        if let context = usage.context {
                            Text("Context: \(context.percent)% · \(context.tokens.formatted()) / \(context.capacity.formatted()) tokens")
                            Text("Last model call observed \(context.observedAt.formatted(date: .abbreviated, time: .shortened)). Context may compact between calls.").foregroundStyle(.secondary)
                        } else { Text("Context usage: not reported by this provider.") }
                        Divider()
                        if limits.isEmpty { Text("Account limits: not reported. This does not mean unlimited.") }
                        ForEach(Array(limits.enumerated()), id: \.offset) { _, limit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(limit.name): \(Int(limit.usedPercent.rounded()))% used")
                                if let reset = limit.resetsAt {
                                    Text(reset <= timeline.date ? "Reset time has passed — refresh needed." : "Resets \(reset.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let notice = usage.notice { Text(notice).foregroundStyle(.orange) }
                        if let quota = status.quota, !quota.isEmpty { Text(quota).foregroundStyle(.secondary) }
                        if let observed = usage.observedAt { Text("Quota checked \(observed.formatted(date: .abbreviated, time: .shortened))\(old ? " · may be stale" : "")").foregroundStyle(.secondary) }
                        Text("Allowances can be shared by other sessions on this account. Only reported limits are shown.").foregroundStyle(.secondary)
                        Button(refreshing ? "Refreshing…" : "Refresh account status", action: refresh).disabled(refreshing)
                    }.font(.system(size: 12)).padding(14).frame(width: 360).fixedSize(horizontal: false, vertical: true)
                        .lineLimit(nil).textSelection(.enabled)
                }
        }
    }
}

func accountUsageSelfTests(_ check: (Bool, String) -> Void) {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let record: [String: Any] = ["type": "event_msg", "timestamp": "2026-10-29T21:00:00.123Z", "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 9_000_000], "last_token_usage": ["total_tokens": 50_000], "model_context_window": 200_000]]]
    let context = AccountUsage.codexContext(record)
    check(context?.percent == 25 && context?.tokens == 50_000, "Account context uses last call, never cumulative billed tokens")
    check(AccountUsage.context(tokens: 1, capacity: 0, at: now) == nil && AccountUsage.context(tokens: -1, capacity: 100, at: now) == nil && AccountUsage.codexContext(["text": record]) == nil, "Account context rejects missing capacity, invalid counts and message-authored telemetry")
    let limits = AccountUsage.codexLimits(["rateLimitsByLimitId": ["codex": ["limitName": "Codex", "primary": ["usedPercent": 92.5, "windowDurationMins": 300, "resetsAt": now.timeIntervalSince1970 + 600], "secondary": ["usedPercent": 41, "windowDurationMins": 10080]]]], at: now)
    check(limits.limits.count == 2 && limits.limits[0].name == "Codex · 5h" && limits.limits[1].name == "Codex · 1w" && limits.warning(now: now), "Account limits preserve independent hourly/weekly windows and near-limit warning")
    check(limits.limits[0].resetsAt == now.addingTimeInterval(600) && !limits.warning(now: now.addingTimeInterval(601)), "Expired account observation cannot claim a currently exhausted allowance")
    let fallback = AccountUsage.codexLimits(["rateLimits": ["primary": ["usedPercent": 100, "windowDurationMins": 1440], "spendControlReached": true]], at: now)
    check(fallback.limits.first?.name == "Account · 1d" && fallback.notice != nil, "Account limits accept legacy single bucket and explicit spend-control restriction")
    check(AccountUsage.codexLimits([:]).limits.isEmpty && AccountUsage.codexLimits(["rateLimits": ["primary": ["usedPercent": -5]]]).limits.isEmpty, "Missing or invalid quota stays unknown, not zero percent")
    let muse = AccountUsage.museLimits("Current 86% used · resets tomorrow\nWeekly 97% used · resets Friday\nas of Thursday (Muse)")
    check(muse.map(\.usedPercent) == [86, 97] && AccountUsage.museLimits("Muse has no observed account quota").isEmpty, "Muse account summary preserves current and weekly percentages; unavailable stays unknown")
    // Claude Code 2.1 shapes: get_usage percent windows; rate_limit_event fractions.
    let report: [String: Any] = ["rate_limits_available": true, "rate_limits": ["five_hour": NSNull(), "seven_day": ["utilization": 30, "resets_at": "2026-11-07T07:00:00.404638+00:00", "locked_reason": NSNull()], "seven_day_opus": ["utilization": 100, "resets_at": "2026-11-07T07:00:00+00:00", "locked_reason": "limit"], "model_scoped": [["display_name": "Opus", "utilization": 5], ["display_name": "Fable", "utilization": 0, "resets_at": "2026-11-07T07:00:00+00:00"]]]]
    let claude = AccountUsage.claudeLimits(report, at: now)
    check(claude?.limits.map(\.name) == ["Claude · 1w", "Opus · 1w", "Fable · 1w"] && claude?.limits.first?.usedPercent == 30 && claude?.limits.first?.resetsAt != nil && claude?.notice != nil,
          "Claude usage report keeps weekly, per-model and locked windows with microsecond reset times")
    check(AccountUsage.claudeLimits(["rate_limits_available": false, "rate_limits": [:]]) == nil && AccountUsage.claudeLimits([:]) == nil, "Claude API-key logins without subscription windows stay unknown")
    let event = AccountUsage.claudeRateLimitEvent(["status": "allowed", "unifiedWindows": ["five_hour": ["utilization": 0.925, "resetsAt": now.timeIntervalSince1970 + 600], "seven_day": ["utilization": 0.29, "resetsAt": now.timeIntervalSince1970 + 9000]]], at: now)
    check(event.limits.map(\.name) == ["Claude · 5h", "Claude · 1w"] && abs(event.limits[0].usedPercent - 92.5) < 0.01 && event.warning(now: now) && event.notice == nil, "Claude turn rate-limit fractions become percent windows with near-limit warning")
    let legacyEvent = AccountUsage.claudeRateLimitEvent(["status": "rejected", "rateLimitType": "five_hour", "utilization": 1.0, "resetsAt": now.timeIntervalSince1970 + 60], at: now)
    check(legacyEvent.limits.map(\.name) == ["Claude · 5h"] && legacyEvent.limits[0].usedPercent == 100 && legacyEvent.notice != nil, "Claude single-window rate-limit events and rejections are reported")
    var held = AccountUsage(context: context, limits: claude?.limits ?? [], observedAt: now)
    held = held.merging(event)
    check(held.context == context && held.limits.map(\.name) == ["Claude · 1w", "Opus · 1w", "Fable · 1w", "Claude · 5h"] && held.limits[0].usedPercent.rounded() == 29 && held.notice == nil,
          "A newer Claude observation replaces only its windows and keeps context and omitted windows")
    let legacy = try? JSONDecoder().decode(ToolStatus.self, from: Data("{\"model\":\"m\",\"effort\":\"e\",\"access\":\"a\",\"usage\":\"1 in / 2 out\"}".utf8))
    check(legacy != nil && legacy?.accountUsage == nil, "Account status opens older archives without telemetry")
    var status = ToolStatus(); status.accountUsage = limits; status.accountUsage?.context = context
    let encoded = try? JSONEncoder().encode(status)
    let decoded = encoded.flatMap { try? JSONDecoder().decode(ToolStatus.self, from: $0) }
    check(decoded?.accountUsage == status.accountUsage, "Account context and quota observation times survive persistence")
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("converse-account-" + UUID().uuidString + ".jsonl")
    defer { try? FileManager.default.removeItem(at: path) }
    try? (try? JSONSerialization.data(withJSONObject: record))?.write(to: path)
    let snapshot = ProviderStatus.resolveCodex(catalog: [:], config: [:], thread: ["path": path.path])
    check(snapshot.status.accountUsage?.context?.percent == 25, "Provider status loads context from the reported thread path")
}

struct CompactionPolicy {
    // A recommendation, not a hard model limit. Stale and pre-compaction
    // observations cannot trigger it; billing totals are never inputs.
    static func recommends(_ context: ContextUsage?, after lastCompacted: Date?, now: Date = Date()) -> Bool {
        guard let context, context.capacity > 0, context.tokens >= 0,
              context.observedAt <= now, now.timeIntervalSince(context.observedAt) <= 600,
              lastCompacted.map({ context.observedAt > $0 && now.timeIntervalSince($0) >= 600 }) ?? true else { return false }
        return Double(context.tokens) / Double(context.capacity) >= 0.8
    }
}

struct CompactionControl: View {
    var state: DeviceCompactionState
    var action: () -> Void
    var body: some View {
        if state.visible {
            Button(state.title, action: action).buttonStyle(.borderedProminent)
                .tint(state.phase == "available" ? .yellow : .gray).foregroundStyle(.black)
                .font(.system(size: 12, weight: .medium)).disabled(state.phase == "running")
                .help(state.detail).accessibilityHint(state.detail)
        }
    }
}
