import SwiftUI
import AppKit

struct HostsView: View {
    @Environment(Store.self) private var store
    @State private var filter = ""
    @State private var selection = Set<HostsLine.ID>()
    @State private var newIP = ""
    @State private var newNames = ""
    @State private var newComment = ""
    @State private var addError: String?
    @State private var resolving = false
    @State private var confirmOverwrite = false
    @State private var alertText: String?

    private var rows: [HostsLine] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let entries = store.hostsEntries
        guard !f.isEmpty else { return entries }
        return entries.filter { $0.ip.contains(f) || $0.names.lowercased().contains(f) || $0.comment.lowercased().contains(f) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.hostsTextMode {
                textEditor
            } else {
                addBar
                table
            }
        }
        .task { store.loadHosts() }
        .confirmationDialog("Файл hosts изменился на диске после загрузки", isPresented: $confirmOverwrite) {
            Button("Перезаписать моими изменениями", role: .destructive) { Task { await save(overwrite: true) } }
            Button("Перечитать с диска (мои правки пропадут)") { store.loadHosts(force: true) }
        } message: {
            Text("Похоже, его поменяла другая программа (например, VPN-клиент).")
        }
        .alert("Не удалось сохранить", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("OK") { alertText = nil }
        } message: {
            Text(alertText ?? "")
        }
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Режим", selection: Binding(get: { store.hostsTextMode }, set: { store.setHostsTextMode($0) })) {
                Text("Записи").tag(false)
                Text("Текст").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)

            if !store.hostsTextMode {
                TextField("Фильтр", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            Spacer()
            if store.hostsDirty {
                Label("Не сохранено", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .imageScale(.small)
            }
            Menu {
                Button("Убрать дубликаты") { store.removeHostDuplicates() }
                    .disabled(store.hostsTextMode)
                Divider()
                Button("Перечитать с диска") { store.loadHosts(force: true) }
                Button("Открыть резервную копию…") { openBackup() }
                Button("Показать копии в Finder") {
                    try? FileManager.default.createDirectory(at: HostsFile.backupDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(HostsFile.backupDir)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Ещё")

            Button("Отменить правки") { store.loadHosts(force: true) }
                .disabled(!store.hostsDirty)
            Button("Сохранить") { Task { await save() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s")
                .disabled(!store.hostsDirty || store.busy != nil)
                .help("Сохранить /etc/hosts (⌘S) — попросит пароль администратора и сбросит DNS-кэш")
        }
        .padding(12)
    }

    // MARK: Добавление

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("IP (0.0.0.0 — заблокировать)", text: $newIP)
                    .frame(width: 210)
                Button {
                    resolveIP()
                } label: {
                    if resolving { ProgressView().controlSize(.small) } else { Image(systemName: "wand.and.stars") }
                }
                .buttonStyle(.borderless)
                .disabled(newNames.trimmingCharacters(in: .whitespaces).isEmpty || resolving)
                .help("Подставить текущий IP первого домена (через DNS из настроек)")
                TextField("домены через пробел", text: $newNames)
                TextField("комментарий", text: $newComment)
                    .frame(width: 170)
                Button("Добавить") { add() }
                    .disabled(newIP.isEmpty || newNames.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { add() }
            if let addError {
                Text(addError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func add() {
        if let err = store.addHost(ip: newIP, names: newNames, comment: newComment) {
            addError = err
        } else {
            addError = nil
            newNames = ""
            newComment = ""
        }
    }

    private func resolveIP() {
        guard let first = newNames.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) else { return }
        resolving = true
        let dns = store.dnsServer
        Task {
            let ips = await Task.detached { Resolver.resolve(first, dns: dns) }.value
            resolving = false
            if let ip = ips.first(where: { !$0.isFakeIP }) {
                newIP = ip.description
                addError = nil
            } else if let fake = ips.first {
                addError = "DNS вернул fake-IP \(fake) — укажите внешний DNS в настройках (⌘,)"
            } else {
                addError = "Не удалось разрезолвить \(first)"
            }
        }
    }

    // MARK: Таблица

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("") { l in
                Toggle("", isOn: store.hostsEnabledBinding(l.id))
                    .labelsHidden()
                    .disabled(l.isSystem)
                    .help(l.isSystem ? "Системная запись" : (l.enabled ? "Выключить (закомментировать)" : "Включить"))
            }
            .width(24)
            TableColumn("IP") { l in
                cell(l, \.ip, mono: true, invalid: l.modified && !HostsFile.isValidIP(l.ip))
            }
            .width(min: 110, ideal: 150)
            TableColumn("Домены") { l in
                cell(l, \.names, mono: false, invalid: l.modified && l.nameList.isEmpty)
            }
            .width(min: 160, ideal: 320)
            TableColumn("Комментарий") { l in
                cell(l, \.comment, mono: false, invalid: false)
            }
            .width(min: 80, ideal: 180)
            TableColumn("") { l in
                if l.isSystem {
                    Image(systemName: "lock.fill").foregroundStyle(.tertiary).help("Системная запись — не редактируется")
                }
            }
            .width(20)
        }
        .contextMenu(forSelectionType: HostsLine.ID.self) { ids in
            Button("Включить") { store.setHostsEnabled(ids, true) }
            Button("Выключить") { store.setHostsEnabled(ids, false) }
            Divider()
            Button("Скопировать") {
                let text = store.hostsLines.filter { ids.contains($0.id) }.map(\.rendered).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            Divider()
            Button("Удалить", role: .destructive) { store.deleteHosts(ids); selection.subtract(ids) }
        }
        .onDeleteCommand {
            store.deleteHosts(selection)
            selection.removeAll()
        }
        .overlay {
            if store.hostsEntries.isEmpty {
                ContentUnavailableView("Записей нет", systemImage: "doc.text", description: Text("Добавьте первую строкой выше"))
            }
        }
    }

    private func cell(_ l: HostsLine, _ kp: WritableKeyPath<HostsLine, String>, mono: Bool, invalid: Bool) -> some View {
        TextField("", text: store.hostsBinding(l.id, kp))
            .textFieldStyle(.plain)
            .font(mono ? .system(.body, design: .monospaced) : .body)
            .foregroundStyle(invalid ? Color.red : (l.enabled ? Color.primary : Color.secondary))
            .strikethrough(!l.enabled, color: .secondary)
            .disabled(l.isSystem)
    }

    // MARK: Текст

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: store.hostsDraftBinding)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            Text("Формат: IP, затем домены через пробел. Строка с # в начале — выключена. Не удаляйте записи localhost.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding([.horizontal, .bottom], 12)
    }

    // MARK: Действия

    private func save(overwrite: Bool = false) async {
        switch await store.saveHosts(overwrite: overwrite) {
        case .conflict: confirmOverwrite = true
        case .invalid(let msg): alertText = msg
        case .saved, .failed, .cancelled: break
        }
    }

    private func openBackup() {
        let panel = NSOpenPanel()
        try? FileManager.default.createDirectory(at: HostsFile.backupDir, withIntermediateDirectories: true)
        panel.directoryURL = HostsFile.backupDir
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Выберите копию hosts — она откроется как несохранённые правки"
        if panel.runModal() == .OK, let url = panel.url {
            store.loadHostsBackup(url)
        }
    }
}
