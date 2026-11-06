import SwiftUI
import ServiceManagement

extension Gateway {
    var spec: GatewaySpec {
        switch kind {
        case .router(let ip): .router(ip.description)
        case .interface: .interface(iface)
        }
    }
}

// MARK: - Шлюзы списков

extension Store {
    /// Роутер текущей «физической» сети: основной среди Wi‑Fi/Ethernet/iPhone, иначе первый найденный.
    var currentRouter: Gateway? {
        let routers = gateways.filter {
            if case .router = $0.kind { return !NetworkInfo.isTunnel($0.iface) }
            return false
        }
        return routers.first(where: \.isPrimary) ?? routers.first
    }

    func gateway(for spec: GatewaySpec) -> Gateway? {
        switch spec {
        case .currentRouter:
            return currentRouter
        case .router(let s):
            guard let ip = IPv4(s.trimmingCharacters(in: .whitespaces)) else { return nil }
            return gateways.first { $0.kind == .router(ip) }
                ?? Gateway(kind: .router(ip), iface: "", name: "Вручную", isPrimary: false)
        case .interface(let dev):
            return gateways.first { $0.kind == .interface && $0.iface == dev }
        }
    }

    func isDetected(_ spec: GatewaySpec) -> Bool {
        spec == .currentRouter || gateways.contains { $0.spec == spec }
    }

    func gatewayLabel(_ spec: GatewaySpec) -> String {
        switch spec {
        case .currentRouter: "роутер текущей сети" + (currentRouter.map { " (\($0.shortTitle))" } ?? " — сети нет")
        case .router(let ip): ip.isEmpty ? "IP не указан" : ip
        case .interface(let dev): interfaceName(dev)
        }
    }

    /// Для фона: вручную указанный IP используем, только если он сейчас в локальной сети, иначе ждём.
    func autoGateway(for spec: GatewaySpec) async -> Gateway? {
        guard let gw = gateway(for: spec) else { return nil }
        if case .router(let ip) = gw.kind, gw.iface.isEmpty {
            let p = await Task.detached { NetworkInfo.probe(ip) }.value
            let onLink = p.gateway == nil && p.destination != "default" && !(p.interface.map(NetworkInfo.isTunnel) ?? true)
            return onLink ? gw : nil
        }
        return gw
    }

    var networkSummary: String {
        var parts: [String] = []
        if let r = currentRouter { parts.append("\(r.name) → \(r.shortTitle)") }
        for g in gateways where g.kind == .interface { parts.append(g.name + (g.isPrimary ? " (основной)" : "")) }
        return parts.isEmpty ? "Сети нет" : parts.joined(separator: " · ")
    }

    func setGateway(_ id: UUID, _ spec: GatewaySpec) {
        guard let i = lists.firstIndex(where: { $0.id == id }), lists[i].gateway != spec else { return }
        lists[i].gateway = spec
        checks[id] = nil
        if lists[i].autoApply { scheduleAutoApplyAfterEdit() }
    }
}

// MARK: - Автоприменение

extension Store {
    var keepsRunning: Bool { launchAtLogin || lists.contains(where: \.autoApply) }

    var menuBarNeedsAttention: Bool {
        lists.contains { l in
            guard l.autoApply, let s = autoStatus[l.id] else { return false }
            return s.state == .missing || s.state == .needsSudo || s.state == .failed
        }
    }

    func setAutoApply(_ id: UUID, _ on: Bool) {
        guard let i = lists.firstIndex(where: { $0.id == id }), lists[i].autoApply != on else { return }
        lists[i].autoApply = on
        if on {
            Task { await runAutoApply(reason: "включено автоприменение") }
        } else {
            autoStatus[id] = nil
        }
    }

    func scheduleAutoApplyAfterEdit() {
        editTask?.cancel()
        editTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await runAutoApply(reason: "список изменён")
        }
    }

    /// Раз в 5 минут: VPN-клиенты и переподключения иногда стирают маршруты.
    func startPeriodicCheck() {
        periodicTask?.cancel()
        periodicTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                await refreshGateways()
                await runAutoApply(reason: "плановая проверка")
            }
        }
    }

    /// Проверяет списки с галочкой «Применять автоматически» и добавляет недостающие маршруты.
    /// `allowPrompt` — можно спросить пароль, если sudo без пароля не настроен (только по явному действию пользователя).
    func runAutoApply(reason: String, allowPrompt: Bool = false) async {
        guard lists.contains(where: \.autoApply) else { return }
        if autoRunning {
            autoAgain = true
            if allowPrompt { autoAgainPrompt = true }
            return
        }
        autoRunning = true
        defer { autoRunning = false }
        var prompt = allowPrompt
        var why = reason
        repeat {
            autoAgain = false
            await autoPass(reason: why, allowPrompt: prompt)
            prompt = autoAgainPrompt
            autoAgainPrompt = false
            why = "повтор"
        } while autoAgain
    }

    private func autoPass(reason: String, allowPrompt: Bool) async {
        let autoLists = lists.filter(\.autoApply)
        guard !autoLists.isEmpty else { return }
        await refreshRoutes()
        if sudoEnabled == nil { await refreshSudoState() }

        var plan: [(IPList, [ParsedEntry], Gateway)] = []
        var cmds: [[String]] = []
        var seen = Set<RouteTarget>()
        for l in autoLists {
            guard let gw = await autoGateway(for: l.gateway) else {
                autoStatus[l.id] = AutoStatus(state: .waitingNetwork, message: "нет шлюза: \(gatewayLabel(l.gateway))")
                continue
            }
            let entries = await expand(l, quiet: true)
            let targets = entries.compactMap(\.target)
            guard !targets.isEmpty else {
                autoStatus[l.id] = AutoStatus(state: .empty, gateway: gw.shortTitle)
                continue
            }
            plan.append((l, entries, gw))
            // Если один адрес есть в нескольких списках — побеждает первый список.
            for t in targets where seen.insert(t).inserted && !routeExists(t, via: gw) {
                cmds.append(["a"] + t.routeArgs + gw.routeArgs)
            }
        }

        if !cmds.isEmpty {
            guard sudoEnabled == true || allowPrompt else {
                for (l, entries, gw) in plan { updateAutoStatus(l, entries: entries, gw: gw, needsSudo: true) }
                if !warnedNeedsSudo {
                    warnedNeedsSudo = true
                    log("Автоприменение: не хватает маршрутов — \(cmds.count). Без пароля добавить нельзя: включите sudo в настройках (⌘,) или нажмите «Применить сейчас».", .warn)
                }
                return
            }
            let res = await Task.detached { Privileged.execute(cmds) }.value
            report(res, title: "Автоприменение (\(reason))")
            await refreshRoutes()
        }
        for (l, entries, gw) in plan { updateAutoStatus(l, entries: entries, gw: gw) }
    }

    func updateAutoStatus(_ l: IPList, entries: [ParsedEntry], gw: Gateway, needsSudo: Bool = false) {
        guard lists.first(where: { $0.id == l.id })?.autoApply == true else { return }
        let targets = entries.compactMap(\.target)
        let missing = targets.filter { !routeExists($0, via: gw) }.count
        let state: AutoStatus.State = missing == 0 ? .ok : (needsSudo ? .needsSudo : .missing)
        autoStatus[l.id] = AutoStatus(state: state, total: targets.count, missing: missing, gateway: gw.shortTitle)
        if state == .ok { warnedNeedsSudo = false }
    }

    /// Есть ли в таблице статический маршрут на эту цель через этот шлюз.
    func routeExists(_ t: RouteTarget, via gw: Gateway) -> Bool {
        let dest = t.description
        return routes.contains { r in
            guard r.destination == dest, r.flags.contains("S") else { return false }
            switch gw.kind {
            case .router(let ip): return r.gateway == ip.description
            case .interface: return r.iface == gw.iface
            }
        }
    }

    func autoStatusLine(_ l: IPList) -> String {
        let name = l.name.isEmpty ? "Без названия" : l.name
        guard let s = autoStatus[l.id] else { return "\(name) — ещё не проверялся" }
        switch s.state {
        case .ok: return "✓ \(name) — \(s.total) адр. через \(s.gateway ?? "?")"
        case .missing: return "⚠︎ \(name) — не хватает \(s.missing) из \(s.total)"
        case .needsSudo: return "⚠︎ \(name) — не хватает \(s.missing), нужен пароль"
        case .waitingNetwork: return "… \(name) — ждёт сеть"
        case .empty: return "\(name) — список пуст"
        case .failed: return "⚠︎ \(name) — ошибка"
        }
    }

    // MARK: Окно

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.identifier?.rawValue.hasPrefix("main") == true }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Запуск при входе

    var loginNeedsApproval: Bool { !Demo.enabled && SMAppService.mainApp.status == .requiresApproval }

    func refreshLoginState() {
        if Demo.enabled { return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        if Demo.enabled { launchAtLogin = on; return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("Запуск при входе: \(error.localizedDescription)", .error)
        }
        refreshLoginState()
        if on && loginNeedsApproval {
            log("Разрешите RouteManager в Системных настройках → Основные → Объекты входа", .warn)
            SMAppService.openSystemSettingsLoginItems()
        } else if on && launchAtLogin {
            log("RouteManager будет запускаться при входе в систему (в строке меню)", .ok)
        }
    }

    // MARK: sudo без пароля

    func refreshSudoState() async {
        sudoEnabled = await Task.detached { Privileged.hasPasswordlessSudo }.value
    }

    func enableSudo() async {
        let r = await Task.detached { Privileged.installSudoers() }.value
        await refreshSudoState()
        if r.cancelled { log("Включение sudo отменено", .warn); return }
        if let e = r.error { log("Не удалось включить sudo: \(e)", .error); return }
        if sudoEnabled == true {
            log("sudo без пароля для /sbin/route включён", .ok)
            warnedNeedsSudo = false
            await runAutoApply(reason: "sudo включён")
        } else {
            log("Файл \(Privileged.sudoersPath) установлен, но sudo его не видит — проверьте, что в /etc/sudoers есть строка #includedir /private/etc/sudoers.d", .error)
        }
    }

    func disableSudo() async {
        let r = await Task.detached { Privileged.removeSudoers() }.value
        await refreshSudoState()
        if r.cancelled { return }
        if let e = r.error { log("Не удалось выключить sudo: \(e)", .error) } else { log("sudo без пароля выключен", .info) }
    }
}
