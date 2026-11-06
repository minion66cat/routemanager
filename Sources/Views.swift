import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Главное окно

struct ContentView: View {
    @Environment(Store.self) private var store

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch store.selection {
                    case .list(let id)?:
                        ListEditorView(listID: id).id(id)
                    case .routes?:
                        RoutesView()
                    case .hosts?:
                        HostsView()
                    case nil:
                        ContentUnavailableView("Выберите список слева", systemImage: "list.bullet.rectangle")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                LogPanel()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Label(store.networkSummary, systemImage: "network")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .help("Текущие шлюзы. Шлюз для каждого списка выбирается в самом списке.")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let busy = store.busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busy).foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                .help("Перечитать шлюзы и таблицу маршрутов")
                SettingsLink {
                    Label("Настройки", systemImage: "gearshape")
                }
                .help("Настройки (⌘,)")
            }
        }
        .task { await store.start() }
        .onAppear { NSApp.setActivationPolicy(.regular) }
    }
}

struct Sidebar: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            Section("Списки") {
                ForEach(store.lists) { list in
                    HStack {
                        Label(list.name.isEmpty ? "Без названия" : list.name, systemImage: "list.bullet.rectangle")
                        Spacer()
                        if list.autoApply { AutoBadge(status: store.autoStatus[list.id]) }
                    }
                        .tag(SidebarItem.list(list.id))
                        .contextMenu {
                            Button("Дублировать") { store.duplicateList(list.id) }
                            Divider()
                            Button("Удалить список", role: .destructive) { store.deleteList(list.id) }
                        }
                }
            }
            Section("Система") {
                Label("Таблица маршрутов", systemImage: "arrow.triangle.branch")
                    .tag(SidebarItem.routes)
                HStack {
                    Label("Файл hosts", systemImage: "doc.text")
                    Spacer()
                    if store.hostsDirty {
                        Circle().fill(.orange).frame(width: 7, height: 7).help("Есть несохранённые изменения")
                    }
                }
                .tag(SidebarItem.hosts)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    store.addList()
                } label: {
                    Label("Новый список", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
    }
}

/// Значок у списка с автоприменением в боковом меню.
struct AutoBadge: View {
    let status: AutoStatus?

    var body: some View {
        switch status?.state {
        case .ok?:
            Image(systemName: "bolt.fill").foregroundStyle(.green).help("Автоприменение: все маршруты на месте")
        case .missing?, .needsSudo?, .failed?:
            Image(systemName: "bolt.trianglebadge.exclamationmark.fill").foregroundStyle(.orange).help("Автоприменение: не все маршруты на месте")
        default:
            Image(systemName: "bolt").foregroundStyle(.secondary).help("Автоприменение включено")
        }
    }
}

/// Выбор шлюза для конкретного списка.
struct ListGatewayPicker: View {
    @Environment(Store.self) private var store
    let list: IPList

    private var isCustomIP: Bool {
        if case .router = list.gateway { return !store.isDetected(list.gateway) }
        return false
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker("Через", selection: Binding(get: { list.gateway }, set: { store.setGateway(list.id, $0) })) {
                Text("Роутер текущей сети" + (store.currentRouter.map { " (\($0.shortTitle))" } ?? " — сети нет"))
                    .tag(GatewaySpec.currentRouter)
                if !store.gateways.isEmpty { Divider() }
                ForEach(store.gateways) { g in
                    Text(g.title).tag(g.spec)
                }
                if !store.isDetected(list.gateway) {
                    switch list.gateway {
                    case .router(let ip): Text(ip.isEmpty ? "Другой IP" : "\(ip) — вручную").tag(list.gateway)
                    case .interface(let dev): Text("\(dev) — сейчас не подключён").tag(list.gateway)
                    case .currentRouter: EmptyView()
                    }
                }
                if !isCustomIP {
                    Divider()
                    Text("Другой IP…").tag(GatewaySpec.router(""))
                }
            }
            .frame(maxWidth: 360)
            .help("«Роутер текущей сети» — Wi‑Fi/Ethernet/iPhone, к которому вы сейчас подключены. Подходит для автоприменения: при смене сети маршруты пойдут через новый роутер.")
            if isCustomIP, case .router(let ip) = list.gateway {
                TextField("IP шлюза", text: Binding(get: { ip }, set: { store.setGateway(list.id, .router($0.trimmingCharacters(in: .whitespaces))) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .foregroundStyle(ip.isEmpty || IPv4(ip) != nil ? Color.primary : Color.red)
            }
        }
    }
}

// MARK: - Редактор списка

struct ListEditorView: View {
    @Environment(Store.self) private var store
    let listID: UUID
    @FocusState private var editorFocused: Bool

    private static let placeholder = """
    Вставьте адреса — по одному в строке или через пробел/запятую:

    203.0.113.19
    10.20.0.0/16
    example.com            # домен разрезолвится в IP
    https://example.org/page   # можно прямо ссылкой
    """

    var body: some View {
        if let list = store.list(listID) {
            let counts = EntryParser.quickCount(list.text)
            VStack(alignment: .leading, spacing: 12) {
                TextField("Название списка", text: store.binding(listID, \.name))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))

                HStack(spacing: 16) {
                    ListGatewayPicker(list: list)
                    Toggle("Применять автоматически", isOn: Binding(get: { list.autoApply }, set: { store.setAutoApply(listID, $0) }))
                        .help("Проверять при запуске, при смене сети и каждые 5 минут; недостающие маршруты добавлять сами")
                    if list.autoApply { autoStatusText(list) }
                    Spacer()
                }

                if list.autoApply && store.sudoEnabled == false {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill").foregroundStyle(.orange)
                        Text("Чтобы маршруты добавлялись в фоне без пароля, разрешите менять маршруты без пароля (только /sbin/route).")
                            .font(.callout)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Разрешить…") { Task { await store.enableSudo() } }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                }

                VSplitView {
                    editor(text: list.text)
                        .frame(minHeight: 140)
                        .padding(.bottom, 6)
                    if let check = store.checks[listID] {
                        EntriesTable(check: check, gw: store.gateway(for: list.gateway))
                            .frame(minHeight: 140)
                            .padding(.top, 6)
                    }
                }

                HStack(spacing: 10) {
                    Text(countsText(counts))
                        .font(.callout)
                        .foregroundStyle(counts.bad > 0 ? .orange : .secondary)
                    Spacer()
                    Button("Проверить") {
                        Task { await store.check(listID) }
                    }
                    .help("Разрезолвить домены и показать, куда сейчас идёт трафик к каждому адресу")
                    Button("Удалить маршруты", role: .destructive) {
                        Task { await store.removeRoutes(listID) }
                    }
                    .help("Удалить маршруты для всех адресов списка")
                    Button {
                        Task { await store.applyRoutes(listID) }
                    } label: {
                        Text(store.gateway(for: list.gateway).map { "Направить через \($0.shortTitle)" } ?? "Шлюз недоступен")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.gateway(for: list.gateway) == nil)
                    .help("Добавить маршруты (⌘↩). Существующие маршруты на эти адреса будут заменены.")
                }
                .disabled(store.busy != nil)
            }
            .padding(16)
            // Курсор сразу в поле адресов — можно вставлять, а название не выделяется.
            .onAppear { DispatchQueue.main.async { editorFocused = true } }
        }
    }

    private func editor(text: String) -> some View {
        TextEditor(text: store.binding(listID, \.text))
            .focused($editorFocused)
            .font(.system(size: 13, design: .monospaced))
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(Self.placeholder)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func autoStatusText(_ list: IPList) -> some View {
        if store.autoRunning {
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("проверяю…") }
                .font(.callout).foregroundStyle(.secondary)
        } else if let s = store.autoStatus[list.id] {
            let time = s.date.formatted(date: .omitted, time: .shortened)
            switch s.state {
            case .ok:
                Label("все \(s.total) на месте · \(time)", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            case .missing, .failed:
                Label("не хватает \(s.missing) из \(s.total) · см. журнал", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            case .needsSudo:
                Label("не хватает \(s.missing) — нужен пароль", systemImage: "key.fill")
                    .font(.callout).foregroundStyle(.orange)
            case .waitingNetwork:
                Label(s.message ?? "ждёт сеть", systemImage: "wifi.slash")
                    .font(.callout).foregroundStyle(.secondary)
            case .empty:
                Text("список пуст").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func countsText(_ c: EntryParser.Counts) -> String {
        var parts: [String] = []
        if c.hosts > 0 { parts.append("IP: \(c.hosts)") }
        if c.nets > 0 { parts.append("подсети: \(c.nets)") }
        if c.domains > 0 { parts.append("домены: \(c.domains)") }
        if c.bad > 0 { parts.append("не распознано: \(c.bad)") }
        return parts.isEmpty ? "Список пуст" : parts.joined(separator: " · ")
    }
}

struct EntriesTable: View {
    @Environment(Store.self) private var store
    let check: CheckResult
    let gw: Gateway?

    private enum Status { case ok, other, error }

    private func status(_ e: ParsedEntry, _ gw: Gateway?) -> Status {
        guard e.error == nil, let t = e.target else { return .error }
        guard let p = check.probes[t], let gw else { return .other }
        return gw.matches(p) ? .ok : .other
    }

    var body: some View {
        let statuses = check.entries.map { status($0, gw) }
        let ok = statuses.filter { $0 == .ok }.count
        let other = statuses.filter { $0 == .other }.count
        let bad = statuses.filter { $0 == .error }.count

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Text("Проверено в \(check.date.formatted(date: .omitted, time: .standard))")
                    .foregroundStyle(.secondary)
                Label("\(ok) через \(gw?.shortTitle ?? "шлюз")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if other > 0 {
                    Label("\(other) другим путём", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                        .foregroundStyle(.orange)
                }
                if bad > 0 {
                    Label("\(bad) с ошибкой", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.callout)

            Table(check.entries) {
                TableColumn("") { e in
                    switch status(e, gw) {
                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .other: Image(systemName: "arrow.triangle.turn.up.right.circle.fill").foregroundStyle(.orange)
                    case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                .width(20)
                TableColumn("Адрес") { e in
                    Text(e.target?.description ?? e.source).monospaced().textSelection(.enabled)
                }
                .width(min: 120, ideal: 160)
                TableColumn("Откуда") { e in
                    Text(e.target != nil && e.source != e.target!.description ? e.source : "")
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 160)
                TableColumn("Сейчас идёт через") { e in
                    if let err = e.error {
                        Text(err).foregroundStyle(.red).help(err)
                    } else if let t = e.target, let p = check.probes[t] {
                        Text(p.summary).monospaced()
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Таблица маршрутов

struct RoutesView: View {
    @Environment(Store.self) private var store
    @State private var filter = ""
    @State private var selection = Set<RouteRow.ID>()
    @State private var pendingDelete: [RouteRow] = []
    @State private var confirmDelete = false

    private var rows: [RouteRow] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return store.routes.filter { r in
            (store.showAllRoutes || r.isUser) &&
            (f.isEmpty || r.destination.contains(f) || r.gateway.lowercased().contains(f)
                || r.iface.contains(f) || store.interfaceName(r.iface).lowercased().contains(f))
        }
    }

    private func rows(for ids: Set<RouteRow.ID>) -> [RouteRow] {
        store.routes.filter { ids.contains($0.id) }
    }

    var body: some View {
        @Bindable var store = store
        let visible = rows
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Фильтр: адрес, шлюз, интерфейс", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Toggle("Показать системные", isOn: $store.showAllRoutes)
                    .help("Кроме статических маршрутов показать системные и временные (кэш)")
                Spacer()
                Text("\(visible.count) шт.").foregroundStyle(.secondary)
                Button("В новый список") {
                    copyToNewList(rows(for: selection))
                }
                .disabled(selection.isEmpty)
                .help("Создать список из выбранных адресов")
                Button("Удалить (\(selection.count))", role: .destructive) {
                    askDelete(rows(for: selection))
                }
                .disabled(selection.isEmpty || store.busy != nil)
            }
            .padding(12)

            Table(visible, selection: $selection) {
                TableColumn("Назначение") { r in
                    Text(r.destination).monospaced()
                }
                .width(min: 120, ideal: 170)
                TableColumn("Шлюз") { r in
                    Text(r.gateway).monospaced()
                }
                .width(min: 100, ideal: 140)
                TableColumn("Интерфейс") { r in
                    Text(store.interfaceName(r.iface))
                }
                .width(min: 80, ideal: 150)
                TableColumn("Флаги") { r in
                    Text(r.flags).monospaced().foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 70)
                TableColumn("") { r in
                    if !r.isUser { Text("системный").font(.caption).foregroundStyle(.tertiary) }
                }
                .width(70)
            }
            .contextMenu(forSelectionType: RouteRow.ID.self) { ids in
                Button("Удалить") { askDelete(rows(for: ids)) }
                Button("Скопировать адреса") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rows(for: ids).map(\.destination).joined(separator: "\n"), forType: .string)
                }
                Button("В новый список") { copyToNewList(rows(for: ids)) }
            }
            .onDeleteCommand { askDelete(rows(for: selection)) }
        }
        .confirmationDialog("Удалить маршруты: \(pendingDelete.count)?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) {
                let toDelete = pendingDelete
                Task {
                    await store.deleteRoutes(toDelete)
                    selection.removeAll()
                }
            }
        } message: {
            if pendingDelete.contains(where: { !$0.isUser }) {
                Text("Среди них есть системные маршруты — их удаление может сломать сеть до переподключения.")
            } else {
                Text(pendingDelete.prefix(8).map(\.destination).joined(separator: ", ") + (pendingDelete.count > 8 ? "…" : ""))
            }
        }
        .task { await store.refreshRoutes() }
    }

    private func askDelete(_ rows: [RouteRow]) {
        guard !rows.isEmpty else { return }
        pendingDelete = rows
        confirmDelete = true
    }

    private func copyToNewList(_ rows: [RouteRow]) {
        guard !rows.isEmpty else { return }
        store.addList(name: "Из таблицы маршрутов", text: rows.map(\.destination).joined(separator: "\n") + "\n")
    }
}

// MARK: - Журнал

struct LogPanel: View {
    @Environment(Store.self) private var store
    @AppStorage("logExpanded") private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Label("Журнал", systemImage: expanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                if !expanded, let last = store.logLines.last {
                    Text(last.text).lineLimit(1).foregroundStyle(last.color)
                }
                Spacer()
                if expanded && !store.logLines.isEmpty {
                    Button("Очистить") { store.logLines.removeAll() }
                        .buttonStyle(.borderless)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if expanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(store.logLines) { l in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(l.date.formatted(date: .omitted, time: .standard))
                                        .foregroundStyle(.tertiary)
                                    Text(l.text)
                                        .foregroundStyle(l.color)
                                        .textSelection(.enabled)
                                }
                                .font(.system(size: 11, design: .monospaced))
                                .id(l.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                    .frame(height: 120)
                    .onChange(of: store.logLines.count) {
                        if let id = store.logLines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
        .background(.bar)
    }
}

// MARK: - Настройки

struct SettingsView: View {
    @Environment(Store.self) private var store
    @State private var copied = false
    @State private var working = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Запускать при входе в систему", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                if store.loginNeedsApproval {
                    HStack {
                        Text("Нужно разрешить в Системных настройках → Основные → Объекты входа.")
                            .foregroundStyle(.orange)
                        Button("Открыть") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .font(.callout)
                }
            } header: {
                Text("Автоприменение")
            } footer: {
                Text("Списки с галочкой «Применять автоматически» проверяются при запуске, при смене сети и каждые 5 минут — недостающие маршруты добавляются сами. Пока такие списки есть, после закрытия окна RouteManager остаётся в строке меню. При входе в систему приложение запускается без окна.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Сейчас") {
                    switch store.sudoEnabled {
                    case true?: Text("без пароля").foregroundStyle(.green)
                    case false?: Text("пароль при каждом изменении")
                    case nil: ProgressView().controlSize(.small)
                    }
                }
                HStack {
                    if store.sudoEnabled == true {
                        Button("Выключить") { run { await store.disableSudo() } }
                    } else {
                        Button("Разрешить без пароля…") { run { await store.enableSudo() } }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Проверить снова") { run { await store.refreshSudoState() } }
                    if working { ProgressView().controlSize(.small) }
                }
                .disabled(working)
                DisclosureGroup("Сделать вручную в Терминале") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Privileged.sudoersInstallCommand)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        HStack {
                            Button(copied ? "Скопировано" : "Скопировать команду") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Privileged.sudoersInstallCommand, forType: .string)
                                copied = true
                            }
                            Text("Отключить: sudo rm \(Privileged.sudoersPath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 4)
                }
            } header: {
                Text("Права администратора")
            } footer: {
                Text("Нужно для автоприменения в фоне. Разрешается только команда /sbin/route для вашего пользователя (файл \(Privileged.sudoersPath)); любая программа под вашим пользователем сможет менять маршруты без пароля. Для сохранения hosts пароль спрашивается всегда.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("DNS-сервер для доменов", text: $store.dnsServer, prompt: Text("системный"))
            } header: {
                Text("Домены")
            } footer: {
                Text("Если VPN-клиент работает в режиме fake-IP (домены резолвятся в 198.18.x.x), укажите внешний DNS, например 77.88.8.8 или 1.1.1.1. У многих сайтов IP меняются — автоприменение подхватывает новые адреса при каждой проверке.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 580)
        .task {
            store.refreshLoginState()
            await store.refreshSudoState()
        }
    }

    private func run(_ op: @escaping () async -> Void) {
        working = true
        Task {
            await op()
            working = false
        }
    }
}
