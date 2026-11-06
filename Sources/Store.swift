import SwiftUI
import Network

enum SidebarItem: Hashable {
    case list(UUID)
    case routes
    case hosts
}

/// Через что направлять адреса списка.
enum GatewaySpec: Codable, Hashable {
    /// Роутер текущей «физической» сети (Wi‑Fi / Ethernet / iPhone) — каким бы он ни был сейчас.
    case currentRouter
    /// Конкретный IP шлюза.
    case router(String)
    /// Интерфейс (VPN-туннель).
    case interface(String)
}

struct IPList: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var text: String
    var gateway: GatewaySpec = .currentRouter
    var autoApply = false
}

extension IPList {
    /// Совместимость со старым форматом lists.json (без gateway/autoApply).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Список"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        gateway = (try? c.decodeIfPresent(GatewaySpec.self, forKey: .gateway)) ?? .currentRouter
        autoApply = try c.decodeIfPresent(Bool.self, forKey: .autoApply) ?? false
    }
}

struct AutoStatus {
    enum State { case ok, missing, waitingNetwork, needsSudo, failed, empty }
    var state: State
    var total = 0
    var missing = 0
    var gateway: String?
    var date = Date()
    var message: String?
}

struct CheckResult {
    var entries: [ParsedEntry]
    var probes: [RouteTarget: RouteProbe]
    var date = Date()
}

struct LogLine: Identifiable {
    enum Kind { case info, ok, warn, error }
    let id = UUID()
    let date = Date()
    let text: String
    let kind: Kind

    var color: Color {
        switch kind {
        case .info: .secondary
        case .ok: .green
        case .warn: .orange
        case .error: .red
        }
    }
}

@MainActor @Observable
final class Store {
    static let shared = Store()

    var gateways: [Gateway] = []
    var interfaceNames: [String: String] = [:]
    var dnsServer: String = Demo.enabled ? "" : (UserDefaults.standard.string(forKey: "dnsServer") ?? "") {
        didSet { if !Demo.enabled { UserDefaults.standard.set(dnsServer, forKey: "dnsServer") } }
    }
    var lists: [IPList] = [] {
        didSet { saveLists() }
    }
    var selection: SidebarItem?
    var routes: [RouteRow] = []
    var showAllRoutes = false
    var checks: [UUID: CheckResult] = [:]
    var logLines: [LogLine] = []
    var busy: String?

    // /etc/hosts
    var hostsLines: [HostsLine] = []
    var hostsDisk = ""
    var hostsDraft = ""
    var hostsDirty = false
    var hostsTextMode = false

    // Автоприменение
    var autoStatus: [UUID: AutoStatus] = [:]
    var autoRunning = false
    var launchAtLogin = false
    var sudoEnabled: Bool?
    @ObservationIgnored var autoAgain = false
    @ObservationIgnored var autoAgainPrompt = false
    @ObservationIgnored var warnedNeedsSudo = false
    @ObservationIgnored var periodicTask: Task<Void, Never>?
    @ObservationIgnored var editTask: Task<Void, Never>?
    /// Открыть главное окно (задаётся из SwiftUI, где есть openWindow).
    @ObservationIgnored var openMainWindow: (() -> Void)?

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    private init() {
        var loaded = Demo.enabled ? Demo.lists : Self.loadLists()
        launchAtLogin = Demo.enabled
        if loaded.isEmpty { loaded = [IPList(name: "Мой список", text: "")] }
        lists = loaded
        selection = loaded.first.map { .list($0.id) }
    }

    // MARK: Жизненный цикл

    func start() async {
        guard !started else { return }
        started = true
        await refreshAll()
        refreshLoginState()
        await refreshSudoState()
        await runAutoApply(reason: "запуск")
        startPeriodicCheck()
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        m.start(queue: DispatchQueue(label: "routemanager.path"))
        monitor = m
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await refreshAll()
            await runAutoApply(reason: "сеть изменилась")
        }
    }

    func refreshAll() async {
        await refreshGateways()
        await refreshRoutes()
        loadHosts()
    }

    func refreshGateways() async {
        let snap = await Task.detached { NetworkInfo.snapshot() }.value
        let before = gateways.map(\.id)
        gateways = snap.gateways
        interfaceNames = snap.interfaceNames
        if before != snap.gateways.map(\.id) {
            let names = snap.gateways.map(\.title).joined(separator: "; ")
            log(before.isEmpty ? "Шлюзы: \(names)" : "Сеть изменилась. Шлюзы: \(names.isEmpty ? "нет" : names)", .info)
        }
    }

    func refreshRoutes() async {
        routes = await Task.detached { NetworkInfo.routes() }.value
    }

    func interfaceName(_ dev: String) -> String { interfaceNames[dev] ?? dev }

    // MARK: Списки

    func list(_ id: UUID) -> IPList? { lists.first { $0.id == id } }

    func binding(_ id: UUID, _ keyPath: WritableKeyPath<IPList, String>) -> Binding<String> {
        Binding(
            get: { self.list(id)?[keyPath: keyPath] ?? "" },
            set: { newValue in
                if let i = self.lists.firstIndex(where: { $0.id == id }), self.lists[i][keyPath: keyPath] != newValue {
                    self.lists[i][keyPath: keyPath] = newValue
                    if keyPath == \IPList.text && self.lists[i].autoApply { self.scheduleAutoApplyAfterEdit() }
                }
            }
        )
    }

    func addList(name: String = "Новый список", text: String = "") {
        let l = IPList(name: name, text: text)
        lists.append(l)
        selection = .list(l.id)
    }

    func duplicateList(_ id: UUID) {
        guard let l = list(id) else { return }
        addList(name: l.name + " (копия)", text: l.text)
        if let i = lists.indices.last { lists[i].gateway = l.gateway }
    }

    func deleteList(_ id: UUID) {
        lists.removeAll { $0.id == id }
        checks[id] = nil
        autoStatus[id] = nil
        if selection == .list(id) { selection = lists.first.map { .list($0.id) } ?? .routes }
    }

    // MARK: Операции

    func check(_ id: UUID) async {
        guard let l = list(id), busy == nil else { return }
        busy = "Проверяю…"
        defer { busy = nil }
        let entries = await expand(l)
        await probe(id, entries: entries)
    }

    func applyRoutes(_ id: UUID) async {
        guard let l = list(id), busy == nil else { return }
        guard let gw = gateway(for: l.gateway) else {
            log("«\(l.name)»: шлюз сейчас недоступен — \(gatewayLabel(l.gateway))", .error)
            return
        }
        busy = "Разбираю список…"
        defer { busy = nil }
        let entries = await expand(l)
        let targets = entries.compactMap(\.target)
        guard !targets.isEmpty else {
            log("«\(l.name)»: нет адресов для добавления", .warn)
            checks[id] = CheckResult(entries: entries, probes: [:])
            return
        }
        busy = "Добавляю маршруты (\(targets.count))…"
        let cmds = targets.map { ["a"] + $0.routeArgs + gw.routeArgs }
        let res = await Task.detached { Privileged.execute(cmds) }.value
        report(res, title: "«\(l.name)» → \(gw.shortTitle)")
        busy = "Проверяю…"
        await probe(id, entries: entries)
        await refreshRoutes()
        updateAutoStatus(l, entries: entries, gw: gw)
    }

    func removeRoutes(_ id: UUID) async {
        guard let l = list(id), busy == nil else { return }
        busy = "Разбираю список…"
        defer { busy = nil }
        let entries = await expand(l)
        let targets = entries.compactMap(\.target)
        guard !targets.isEmpty else { return }
        busy = "Удаляю маршруты (\(targets.count))…"
        let cmds = targets.map { ["d"] + $0.routeArgs }
        let res = await Task.detached { Privileged.execute(cmds) }.value
        report(res, title: "«\(l.name)»: удаление")
        busy = "Проверяю…"
        await probe(id, entries: entries)
        await refreshRoutes()
    }

    func deleteRoutes(_ rows: [RouteRow]) async {
        guard !rows.isEmpty, busy == nil else { return }
        busy = "Удаляю маршруты (\(rows.count))…"
        defer { busy = nil }
        let cmds = rows.map { ["d"] + $0.deleteArgs }
        let res = await Task.detached { Privileged.execute(cmds) }.value
        report(res, title: "Удаление из таблицы")
        await refreshRoutes()
    }

    func expand(_ l: IPList, quiet: Bool = false) async -> [ParsedEntry] {
        let text = l.text
        let dns = dnsServer
        let entries = await Task.detached { EntryParser.expand(text, dns: dns) }.value
        let errors = entries.filter { $0.error != nil }
        if !errors.isEmpty && !quiet {
            log("«\(l.name)»: пропущено \(errors.count) — " + errors.prefix(5).map { "\($0.source): \($0.error!)" }.joined(separator: "; "), .warn)
        }
        return entries
    }

    private func probe(_ id: UUID, entries: [ParsedEntry]) async {
        let targets = entries.compactMap(\.target)
        let probes = await Task.detached {
            Dictionary(targets.map { ($0, NetworkInfo.probe($0.probeAddress)) }, uniquingKeysWith: { a, _ in a })
        }.value
        checks[id] = CheckResult(entries: entries, probes: probes)
    }

    func report(_ r: PrivilegedResult, title: String) {
        if r.cancelled { log("\(title): отменено", .warn); return }
        if let f = r.fatal { log("\(title): ошибка — \(f)", .error); return }
        var parts: [String] = []
        if r.added > 0 { parts.append("добавлено \(r.added)") }
        if r.changed > 0 { parts.append("заменено \(r.changed)") }
        if r.deleted > 0 { parts.append("удалено \(r.deleted)") }
        if !r.failures.isEmpty { parts.append("ошибок \(r.failures.count)") }
        log("\(title): " + (parts.isEmpty ? "ничего не изменилось" : parts.joined(separator: ", ")), r.failures.isEmpty ? .ok : .warn)
        for f in r.failures.prefix(30) { log("   \(f.dest): \(f.message)", .error) }
        if r.failures.count > 30 { log("   … и ещё \(r.failures.count - 30)", .error) }
    }

    func log(_ text: String, _ kind: LogLine.Kind = .info) {
        logLines.append(LogLine(text: text, kind: kind))
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    // MARK: Хранение

    private static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RouteManager", isDirectory: true)
            .appendingPathComponent("lists.json")
    }

    private static func loadLists() -> [IPList] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([IPList].self, from: data)) ?? []
    }

    private func saveLists() {
        guard !Demo.enabled else { return }
        let url = Self.storeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(lists) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - /etc/hosts

enum HostsSaveOutcome { case saved, conflict, invalid(String), failed, cancelled }

extension Store {
    var hostsEntries: [HostsLine] { hostsLines.filter(\.isEntry) }

    /// Перечитать файл с диска. Без `force` не трогает несохранённые правки.
    func loadHosts(force: Bool = false) {
        guard force || !hostsDirty else { return }
        let text = HostsFile.read()
        hostsDisk = text
        hostsDraft = text
        hostsLines = HostsFile.parse(text)
        hostsDirty = false
    }

    func setHostsTextMode(_ on: Bool) {
        guard on != hostsTextMode else { return }
        if on {
            hostsDraft = HostsFile.serialize(hostsLines)
        } else {
            hostsLines = HostsFile.parse(hostsDraft)
        }
        hostsTextMode = on
    }

    var hostsDraftBinding: Binding<String> {
        Binding(get: { self.hostsDraft }, set: { v in
            if v != self.hostsDraft { self.hostsDraft = v; self.hostsDirty = true }
        })
    }

    func hostsBinding(_ id: UUID, _ kp: WritableKeyPath<HostsLine, String>) -> Binding<String> {
        Binding(
            get: { self.hostsLines.first { $0.id == id }?[keyPath: kp] ?? "" },
            set: { v in self.updateHost(id) { $0[keyPath: kp] = v } }
        )
    }

    func hostsEnabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { self.hostsLines.first { $0.id == id }?.enabled ?? false },
            set: { v in self.updateHost(id) { $0.enabled = v } }
        )
    }

    func updateHost(_ id: UUID, _ change: (inout HostsLine) -> Void) {
        guard let i = hostsLines.firstIndex(where: { $0.id == id }) else { return }
        var l = hostsLines[i]
        change(&l)
        guard l != hostsLines[i] else { return }
        l.modified = true
        hostsLines[i] = l
        hostsDirty = true
    }

    func setHostsEnabled(_ ids: Set<UUID>, _ on: Bool) {
        for i in hostsLines.indices where ids.contains(hostsLines[i].id) && hostsLines[i].isEntry
            && !hostsLines[i].isSystem && hostsLines[i].enabled != on {
            hostsLines[i].enabled = on
            hostsLines[i].modified = true
            hostsDirty = true
        }
    }

    func deleteHosts(_ ids: Set<UUID>) {
        let before = hostsLines.count
        hostsLines.removeAll { ids.contains($0.id) && !$0.isSystem }
        if hostsLines.count != before { hostsDirty = true }
    }

    /// Возвращает текст ошибки или nil, если запись добавлена.
    func addHost(ip rawIP: String, names rawNames: String, comment rawComment: String) -> String? {
        let ip = rawIP.trimmingCharacters(in: .whitespaces)
        let names = rawNames.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" || $0 == "\t" })
            .map { String($0).lowercased() }
        let comment = rawComment.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\n", with: " ")
        guard HostsFile.isValidIP(ip) else { return "Неверный IP-адрес" }
        guard !names.isEmpty else { return "Укажите хотя бы один домен" }
        if let bad = names.first(where: { !HostsFile.isValidName($0) }) { return "Неверное имя: \(bad)" }

        let existing = Set(hostsEntries.filter(\.enabled).flatMap(\.nameList))
        let dup = names.filter(existing.contains)
        // Вставляем после последней записи, а не после хвостовых пустых строк.
        let insertAt = (hostsLines.lastIndex(where: \.isEntry).map { $0 + 1 }) ?? hostsLines.count
        hostsLines.insert(.entry(ip: ip, names: names.joined(separator: " "), comment: comment), at: insertAt)
        hostsDirty = true
        if !dup.isEmpty {
            log("hosts: \(dup.joined(separator: ", ")) уже есть в файле — проверьте, какая запись нужна", .warn)
        }
        return nil
    }

    @discardableResult
    func removeHostDuplicates() -> Int {
        var seen = Set<String>()
        var removed = 0
        hostsLines = hostsLines.filter { l in
            guard l.isEntry else { return true }
            if seen.insert(l.dedupKey).inserted { return true }
            removed += 1
            return false
        }
        if removed > 0 { hostsDirty = true }
        log(removed > 0 ? "hosts: убрано дубликатов — \(removed) (не забудьте сохранить)" : "hosts: дубликатов нет", .info)
        return removed
    }

    func loadHostsBackup(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { log("Не удалось прочитать \(url.lastPathComponent)", .error); return }
        let text = String(decoding: data, as: UTF8.self)
        hostsDraft = text
        hostsLines = HostsFile.parse(text)
        hostsDirty = true
        log("Загружена копия \(url.lastPathComponent) — проверьте и нажмите «Сохранить»", .info)
    }

    func saveHosts(overwrite: Bool = false) async -> HostsSaveOutcome {
        guard busy == nil else { return .failed }
        let content: String
        if hostsTextMode {
            content = hostsDraft.hasSuffix("\n") ? hostsDraft : hostsDraft + "\n"
        } else {
            if let hit = hostsLines.enumerated().first(where: { $0.element.isEntry && $0.element.modified && !$0.element.isValid }) {
                return .invalid("Строка \(hit.offset + 1): «\(hit.element.rendered)» — неверный IP или имя хоста")
            }
            content = HostsFile.serialize(hostsLines)
        }
        let disk = HostsFile.read()
        if !overwrite && disk != hostsDisk { return .conflict }
        if content == disk {
            loadHosts(force: true)
            log("hosts: изменений нет", .info)
            return .saved
        }
        busy = "Сохраняю hosts…"
        defer { busy = nil }
        let r = await Task.detached { HostsFile.write(content) }.value
        if r.cancelled { log("hosts: сохранение отменено", .warn); return .cancelled }
        if let e = r.error { log("hosts: ошибка — \(e)", .error); return .failed }
        let backup = HostsFile.backup(disk)
        log("hosts сохранён, DNS-кэш сброшен" + (backup.map { " · прошлая версия: \($0.lastPathComponent)" } ?? ""), .ok)
        loadHosts(force: true)
        return .saved
    }
}
