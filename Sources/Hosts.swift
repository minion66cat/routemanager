import Foundation
import CryptoKit
import Darwin

/// Одна строка /etc/hosts. Комментарии и пустые строки хранятся как есть (`isEntry == false`),
/// записи — разобранными; неизменённые строки записываются обратно байт в байт.
struct HostsLine: Identifiable, Hashable {
    let id = UUID()
    var isEntry: Bool
    var raw: String
    var modified = false
    var enabled = true
    var ip = ""
    var names = ""
    var comment = ""

    static func text(_ raw: String) -> HostsLine { HostsLine(isEntry: false, raw: raw) }

    static func entry(ip: String, names: String, comment: String = "", enabled: Bool = true) -> HostsLine {
        HostsLine(isEntry: true, raw: "", modified: true, enabled: enabled, ip: ip, names: names, comment: comment)
    }

    var rendered: String {
        guard isEntry, modified else { return raw }
        var s = (enabled ? "" : "# ") + ip + "\t" + names
        if !comment.isEmpty { s += "\t# " + comment }
        return s
    }

    var nameList: [String] { names.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }

    /// localhost / broadcasthost — системные записи, их не трогаем.
    var isSystem: Bool {
        isEntry && nameList.contains { $0 == "localhost" || $0 == "broadcasthost" }
    }

    var isValid: Bool {
        HostsFile.isValidIP(ip) && !nameList.isEmpty && nameList.allSatisfy(HostsFile.isValidName)
    }

    /// Ключ для поиска дубликатов.
    var dedupKey: String { "\(enabled)|\(ip)|\(nameList.joined(separator: " "))" }
}

enum HostsFile {
    static let path = "/etc/hosts"

    static func isValidIP(_ s: String) -> Bool {
        if IPv4(s) != nil { return true }
        let addr = s.split(separator: "%", maxSplits: 1).first.map(String.init) ?? s
        var a6 = in6_addr()
        return addr.contains(":") && inet_pton(AF_INET6, addr, &a6) == 1
    }

    static func isValidName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 253 && s.first != "-" && s.first != "."
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }
    }

    static func read() -> String {
        if Demo.enabled { return Demo.hostsText }
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ text: String) -> [HostsLine] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { parseLine($0.hasSuffix("\r") ? String($0.dropLast()) : $0) }
    }

    static func parseLine(_ raw: String) -> HostsLine {
        var body = raw.trimmingCharacters(in: .whitespaces)
        var enabled = true
        if body.hasPrefix("#") {
            enabled = false
            body = String(body.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
        }
        var comment = ""
        if let hashIdx = body.firstIndex(of: "#") {
            comment = body[body.index(after: hashIdx)...].trimmingCharacters(in: .whitespaces)
            body = body[..<hashIdx].trimmingCharacters(in: .whitespaces)
        }
        let toks = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard toks.count >= 2, isValidIP(toks[0]), toks.dropFirst().allSatisfy(isValidName) else {
            return .text(raw)
        }
        return HostsLine(isEntry: true, raw: raw, enabled: enabled, ip: toks[0],
                         names: toks.dropFirst().joined(separator: " "), comment: comment)
    }

    static func serialize(_ lines: [HostsLine]) -> String {
        lines.map(\.rendered).joined(separator: "\n") + "\n"
    }

    // MARK: Резервные копии

    static var backupDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RouteManager/hosts-backups", isDirectory: true)
    }

    @discardableResult
    static func backup(_ content: String) -> URL? {
        if Demo.enabled { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = backupDir.appendingPathComponent("hosts_\(f.string(from: Date()))")
        guard (try? Data(content.utf8).write(to: url)) != nil else { return nil }
        // Оставляем 30 последних копий.
        if let files = try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.hasPrefix("hosts_") })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }), files.count > 30 {
            for old in files.dropFirst(30) { try? fm.removeItem(at: old) }
        }
        return url
    }

    // MARK: Запись с правами root

    struct WriteResult { var ok = false; var cancelled = false; var error: String? }

    /// Содержимое кладётся во временный файл пользователя; root копирует его к себе, сверяет SHA-256
    /// (защита от подмены файла между проверкой и копированием) и атомарно заменяет /etc/hosts.
    /// После записи сбрасывается DNS-кэш системы.
    static func write(_ content: String) -> WriteResult {
        var result = WriteResult()
        if Demo.enabled { Demo.hostsText = content; result.ok = true; return result }
        let data = Data(content.utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("routemanager-hosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try data.write(to: tmp) } catch {
            result.error = "не удалось записать временный файл: \(error.localizedDescription)"
            return result
        }
        let src = tmp.path
        guard src.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) }) else {
            result.error = "неожиданный путь временного файла"
            return result
        }
        let sh = writeScript(src: src, hash: hash)
        let r = Shell.run("/usr/bin/osascript", ["-e", Privileged.appleScript(sh, prompt: "RouteManager хочет сохранить файл /etc/hosts.")])
        let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out == "OK" {
            result.ok = true
        } else if out.hasPrefix("ERR|") {
            result.error = String(out.dropFirst(4))
        } else if r.err.contains("-128") {
            result.cancelled = true
        } else {
            result.error = r.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "неизвестная ошибка" : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func writeScript(src: String, hash: String) -> String {
        """
        w() {
          t=$(/usr/bin/mktemp /private/etc/hosts.routemanager.XXXXXX) || { echo "ERR|mktemp"; return; }
          /bin/cat -- '\(src)' > "$t" || { /bin/rm -f "$t"; echo "ERR|не удалось скопировать"; return; }
          h=$(/usr/bin/shasum -a 256 "$t" | /usr/bin/cut -d' ' -f1)
          if [ "$h" != "\(hash)" ]; then /bin/rm -f "$t"; echo "ERR|контрольная сумма не совпала"; return; fi
          /bin/chmod 644 "$t" && /usr/sbin/chown root:wheel "$t" && /bin/mv -f "$t" /private/etc/hosts || { /bin/rm -f "$t"; echo "ERR|не удалось заменить файл"; return; }
          /usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder 2>/dev/null
          echo "OK"
        }
        w
        """
    }
}
