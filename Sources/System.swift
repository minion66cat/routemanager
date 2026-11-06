import Foundation
import Darwin

// MARK: - Shell

struct ShellResult: Sendable {
    var status: Int32
    var out: String
    var err: String
    var ok: Bool { status == 0 }
}

enum Shell {
    /// Запускает бинарник напрямую (без shell), читает stdout/stderr параллельно, чтобы не словить дедлок на переполненном пайпе.
    static func run(_ path: String, _ args: [String]) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return ShellResult(status: -1, out: "", err: error.localizedDescription)
        }
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return ShellResult(status: p.terminationStatus,
                           out: String(decoding: outData, as: UTF8.self),
                           err: String(decoding: errData, as: UTF8.self))
    }
}

// MARK: - IPv4 / цели маршрутов

struct IPv4: Hashable, Comparable, CustomStringConvertible, Sendable {
    let value: UInt32

    init(value: UInt32) { self.value = value }

    init?(_ s: String) {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard (1...3).contains(p.count),
                  p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = UInt32(p), n <= 255 else { return nil }
            v = (v << 8) | n
        }
        value = v
    }

    var description: String {
        "\(value >> 24).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
    }

    static func < (a: IPv4, b: IPv4) -> Bool { a.value < b.value }

    static func mask(_ prefix: Int) -> UInt32 {
        if prefix <= 0 { return 0 }
        if prefix >= 32 { return .max }
        return ~UInt32(0) << UInt32(32 - prefix)
    }

    func isIn(_ net: IPv4, _ prefix: Int) -> Bool {
        let m = IPv4.mask(prefix)
        return value & m == net.value & m
    }

    /// 198.18.0.0/15 — диапазон, который VPN/прокси-клиенты (sing-box, Clash и т.п.) раздают в режиме fake-IP.
    var isFakeIP: Bool { isIn(IPv4(value: 0xC612_0000), 15) }

    /// 172.20.10.0/28 — сеть режима модема iPhone.
    var isIPhoneHotspot: Bool { isIn(IPv4(value: 0xAC14_0A00), 28) }
}

enum RouteTarget: Hashable, Comparable, CustomStringConvertible, Sendable {
    case host(IPv4)
    case net(IPv4, Int)

    static func make(_ ip: IPv4, prefix: Int) -> RouteTarget {
        if prefix >= 32 { return .host(ip) }
        return .net(IPv4(value: ip.value & IPv4.mask(prefix)), prefix)
    }

    var description: String {
        switch self {
        case .host(let ip): ip.description
        case .net(let ip, let p): "\(ip)/\(p)"
        }
    }

    var routeArgs: [String] {
        switch self {
        case .host(let ip): ["-host", ip.description]
        case .net(let ip, let p): ["-net", "\(ip)/\(p)"]
        }
    }

    /// Адрес, по которому спрашиваем `route get`, чтобы понять, куда пойдёт трафик.
    var probeAddress: IPv4 {
        switch self {
        case .host(let ip): ip
        case .net(let ip, let p): p < 31 ? IPv4(value: ip.value | 1) : ip
        }
    }

    private var key: (UInt32, Int) {
        switch self {
        case .host(let ip): (ip.value, 32)
        case .net(let ip, let p): (ip.value, p)
        }
    }

    static func < (a: RouteTarget, b: RouteTarget) -> Bool { a.key < b.key }
}

// MARK: - Разбор ввода

struct ParsedEntry: Identifiable, Sendable {
    let id = UUID()
    let source: String
    let target: RouteTarget?
    let error: String?
}

enum EntryParser {
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            for t in content.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == ";" }) {
                out.append(String(t))
            }
        }
        return out
    }

    /// `1.2.3.4` или `1.2.3.0/24`
    static func literal(_ raw: String) -> RouteTarget? {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let ip = IPv4(String(parts[0])) else { return nil }
        if parts.count == 1 { return .host(ip) }
        guard let p = Int(parts[1]), (1...32).contains(p) else { return nil }
        return .make(ip, prefix: p)
    }

    /// Домен, в том числе вставленный как URL (`https://example.com/path`) или с `*.`.
    static func hostname(_ raw: String) -> String? {
        var s = raw
        if s.contains("://") {
            guard let h = URL(string: s)?.host else { return nil }
            s = h
        } else if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        if let colon = s.lastIndex(of: ":") { s = String(s[..<colon]) }
        if s.hasPrefix("*.") { s.removeFirst(2) }
        s = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, s.count <= 253, s.contains(where: \.isLetter) else { return nil }
        for l in labels {
            guard (1...63).contains(l.count), l.first != "-", l.last != "-",
                  l.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" })
            else { return nil }
        }
        return s
    }

    struct Counts { var hosts = 0, nets = 0, domains = 0, bad = 0 }

    static func quickCount(_ text: String) -> Counts {
        var c = Counts()
        for t in tokens(text) {
            switch literal(t) {
            case .host?: c.hosts += 1
            case .net?: c.nets += 1
            case nil: if hostname(t) != nil { c.domains += 1 } else { c.bad += 1 }
            }
        }
        return c
    }

    /// Разворачивает текст в список целей: IP, подсети, а домены резолвит в A-записи.
    static func expand(_ text: String, dns: String) -> [ParsedEntry] {
        let toks = tokens(text)
        let hosts = Array(Set(toks.filter { literal($0) == nil }.compactMap(hostname)))
        var resolved = [[IPv4]](repeating: [], count: hosts.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: hosts.count) { i in
            let r = Resolver.resolve(hosts[i], dns: dns)
            lock.lock(); resolved[i] = r; lock.unlock()
        }
        let byHost = Dictionary(uniqueKeysWithValues: zip(hosts, resolved))

        var result: [ParsedEntry] = []
        var seen = Set<RouteTarget>()
        var seenErrors = Set<String>()
        func fail(_ src: String, _ msg: String) {
            if seenErrors.insert(src).inserted { result.append(ParsedEntry(source: src, target: nil, error: msg)) }
        }
        for t in toks {
            if let target = literal(t) {
                if seen.insert(target).inserted { result.append(ParsedEntry(source: t, target: target, error: nil)) }
            } else if let h = hostname(t) {
                let ips = byHost[h] ?? []
                let real = ips.filter { !$0.isFakeIP }
                if ips.isEmpty {
                    fail(h, "домен не разрезолвился")
                } else if real.isEmpty {
                    fail(h, "DNS вернул fake-IP \(ips[0]) от VPN-клиента — укажите внешний DNS в настройках (⌘,)")
                } else {
                    for ip in real {
                        let tg = RouteTarget.host(ip)
                        if seen.insert(tg).inserted { result.append(ParsedEntry(source: h, target: tg, error: nil)) }
                    }
                }
            } else {
                fail(t, "не похоже на IP, подсеть или домен")
            }
        }
        return result
    }
}

enum Resolver {
    static func resolve(_ host: String, dns: String) -> [IPv4] {
        if Demo.enabled { return Demo.resolve(host) }
        if let server = IPv4(dns.trimmingCharacters(in: .whitespaces)) {
            return dig(host, server: server)
        }
        return system(host)
    }

    static func system(_ host: String) -> [IPv4] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [IPv4] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                let v = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let ip = IPv4(value: v)
                if !out.contains(ip) { out.append(ip) }
            }
            p = ai.pointee.ai_next
        }
        return out
    }

    static func dig(_ host: String, server: IPv4) -> [IPv4] {
        let r = Shell.run("/usr/bin/dig", ["+short", "+time=2", "+tries=2", "A", host, "@\(server)"])
        var out: [IPv4] = []
        for line in r.out.split(whereSeparator: \.isNewline) {
            if let ip = IPv4(line.trimmingCharacters(in: .whitespaces)), !out.contains(ip) { out.append(ip) }
        }
        return out
    }
}

// MARK: - Состояние сети

struct Gateway: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case router(IPv4), interface }
    var kind: Kind
    var iface: String
    var name: String
    var isPrimary: Bool

    var id: String {
        switch kind {
        case .router(let ip): "gw:\(ip)@\(iface)"
        case .interface: "if:\(iface)"
        }
    }

    /// Аргументы `route add` после назначения.
    var routeArgs: [String] {
        switch kind {
        case .router(let ip): [ip.description]
        case .interface: ["-interface", iface]
        }
    }

    var shortTitle: String {
        switch kind {
        case .router(let ip): ip.description
        case .interface: iface
        }
    }

    var title: String {
        var s: String
        switch kind {
        case .router(let ip):
            s = iface.isEmpty ? "\(ip)" : "\(name) → \(ip)"
            if ip.isIPhoneHotspot { s += " (iPhone)" }
        case .interface:
            s = "\(name) — интерфейс"
        }
        if isPrimary { s += " · основной" }
        return s
    }

    func matches(_ p: RouteProbe) -> Bool {
        switch kind {
        case .router(let ip): p.gateway == ip.description
        case .interface: p.interface == iface
        }
    }
}

struct RouteProbe: Hashable, Sendable {
    var gateway: String?
    var interface: String?
    var destination: String?

    var summary: String {
        var s = gateway ?? ""
        if let i = interface { s += s.isEmpty ? i : " (\(i))" }
        if destination == "default" { s += " · маршрут по умолчанию" }
        return s.isEmpty ? "нет маршрута" : s
    }
}

struct RouteRow: Identifiable, Hashable, Sendable {
    let id: String
    let destination: String
    let gateway: String
    let iface: String
    let flags: String
    let isUser: Bool
    let deleteArgs: [String]
}

struct NetworkSnapshot: Sendable {
    var gateways: [Gateway]
    var interfaceNames: [String: String]
}

enum NetworkInfo {
    struct NetstatRow { var dest, gateway, flags, iface: String }

    static func netstat() -> [NetstatRow] {
        let r = Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        var rows: [NetstatRow] = []
        var inTable = false
        for line in r.out.split(whereSeparator: \.isNewline) {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if cols.first == "Destination" { inTable = true; continue }
            guard inTable, cols.count >= 4 else { continue }
            rows.append(NetstatRow(dest: cols[0], gateway: cols[1], flags: cols[2], iface: cols[3]))
        }
        return rows
    }

    /// Device → «Wi-Fi», «iPhone USB», «Ethernet Adapter (en4)» …
    static func hardwarePorts() -> [String: String] {
        let r = Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"])
        var map: [String: String] = [:]
        var port: String?
        for line in r.out.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Hardware Port: ") { port = String(line.dropFirst("Hardware Port: ".count)) }
            if line.hasPrefix("Device: "), let p = port { map[String(line.dropFirst("Device: ".count))] = p }
        }
        return map
    }

    /// Интерфейсы с активным IPv4 (как их видит система).
    static func activeInterfaces() -> [String] {
        let r = Shell.run("/usr/sbin/scutil", ["--nwi"])
        for line in r.out.split(whereSeparator: \.isNewline) where line.hasPrefix("Network interfaces:") {
            return line.dropFirst("Network interfaces:".count).split(separator: " ").map(String.init)
        }
        return []
    }

    static func isTunnel(_ dev: String) -> Bool {
        dev.hasPrefix("utun") || dev.hasPrefix("ipsec") || dev.hasPrefix("ppp") || dev.hasPrefix("tun") || dev.hasPrefix("wg")
    }

    static func displayName(_ dev: String, ports: [String: String]) -> String {
        if let p = ports[dev] { return p.contains(dev) ? p : "\(p) (\(dev))" }
        if isTunnel(dev) { return "VPN (\(dev))" }
        return dev
    }

    static func snapshot() -> NetworkSnapshot {
        if Demo.enabled { return Demo.snapshot }
        let ports = hardwarePorts()
        var list: [Gateway] = []
        func add(_ g: Gateway) {
            if let i = list.firstIndex(where: { $0.id == g.id }) {
                if g.isPrimary { list[i].isPrimary = true }
            } else {
                list.append(g)
            }
        }
        let rows = netstat()
        for row in rows where row.dest == "default" {
            let primary = !row.flags.contains("I")
            let name = displayName(row.iface, ports: ports)
            if let ip = IPv4(row.gateway) {
                add(Gateway(kind: .router(ip), iface: row.iface, name: name, isPrimary: primary))
            } else if row.gateway.hasPrefix("link#") {
                add(Gateway(kind: .interface, iface: row.iface, name: name, isPrimary: primary))
            }
        }
        let active = activeInterfaces()
        for dev in active where !isTunnel(dev) {
            let r = Shell.run("/usr/sbin/ipconfig", ["getoption", dev, "router"])
            if let ip = IPv4(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) {
                add(Gateway(kind: .router(ip), iface: dev, name: displayName(dev, ports: ports), isPrimary: false))
            }
        }
        for dev in active where isTunnel(dev) {
            add(Gateway(kind: .interface, iface: dev, name: displayName(dev, ports: ports), isPrimary: false))
        }
        // Сначала «настоящие» роутеры, потом туннели.
        let sorted = list.enumerated().sorted { a, b in
            let ra = a.element.kind == .interface ? 1 : 0
            let rb = b.element.kind == .interface ? 1 : 0
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)

        var names: [String: String] = [:]
        for row in rows where names[row.iface] == nil { names[row.iface] = displayName(row.iface, ports: ports) }
        return NetworkSnapshot(gateways: sorted, interfaceNames: names)
    }

    static func preferred(_ gws: [Gateway]) -> Gateway? {
        gws.first { if case .router = $0.kind { return !isTunnel($0.iface) } else { return false } } ?? gws.first
    }

    /// Таблица маршрутов. `isUser` — статические маршруты, добавленные руками или VPN-клиентом (не системные).
    static func routes() -> [RouteRow] {
        if Demo.enabled { return Demo.routes() }
        var out: [RouteRow] = []
        var ids = Set<String>()
        for r in netstat() where r.dest != "default" {
            guard let (display, args) = normalize(r.dest, flags: r.flags) else { continue }
            let isStatic = r.flags.contains("S")
            let isUser = isStatic && (r.flags.contains("G") || !(r.flags.contains("C") || r.flags.contains("m")))
            var delete = args
            if r.flags.contains("I") { delete += ["-ifscope", r.iface] }
            var id = "\(display)|\(r.gateway)|\(r.iface)"
            var n = 1
            while ids.contains(id) { n += 1; id = "\(display)|\(r.gateway)|\(r.iface)#\(n)" }
            ids.insert(id)
            out.append(RouteRow(id: id, destination: display, gateway: r.gateway, iface: r.iface,
                                flags: r.flags, isUser: isUser, deleteArgs: delete))
        }
        return out
    }

    /// netstat сокращает адреса: `10` = 10.0.0.0/8, `192.168.1/24`, `172.16/12`, `1.2.3.4` (хост).
    static func normalize(_ dest: String, flags: String) -> (String, [String])? {
        let parts = dest.split(separator: "/")
        guard let addrPart = parts.first else { return nil }
        var octets = addrPart.split(separator: ".").map(String.init)
        guard (1...4).contains(octets.count) else { return nil }
        let given = octets.count
        while octets.count < 4 { octets.append("0") }
        guard let ip = IPv4(octets.joined(separator: ".")) else { return nil }
        let isHost = flags.contains("H")
        if parts.count == 2, let p = Int(parts[1]) {
            if isHost { return (ip.description, ["-host", ip.description]) }
            let net = IPv4(value: ip.value & IPv4.mask(p))
            return ("\(net)/\(p)", ["-net", "\(net)/\(p)"])
        }
        if isHost || given == 4 { return (ip.description, ["-host", ip.description]) }
        let p = given * 8
        return ("\(ip)/\(p)", ["-net", "\(ip)/\(p)"])
    }

    static func probe(_ ip: IPv4) -> RouteProbe {
        if Demo.enabled { return Demo.probe(ip) }
        let r = Shell.run("/sbin/route", ["-n", "get", ip.description])
        var p = RouteProbe()
        for line in r.out.split(whereSeparator: \.isNewline) {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "gateway": p.gateway = kv[1]
            case "interface": p.interface = kv[1]
            case "destination": p.destination = kv[1]
            default: break
            }
        }
        return p
    }
}

// MARK: - Выполнение с правами root

struct PrivilegedResult: Sendable {
    struct Failure: Sendable { let dest: String; let message: String }
    var added = 0, changed = 0, deleted = 0
    var failures: [Failure] = []
    var cancelled = false
    var fatal: String?
    var viaSudo = false
}

enum Privileged {
    static let sudoersPath = "/private/etc/sudoers.d/routemanager"

    static var hasPasswordlessSudo: Bool {
        if Demo.enabled { return true }
        return Shell.run("/usr/bin/sudo", ["-n", "-l", "/sbin/route"]).ok
    }

    static var sudoersInstallCommand: String {
        let user = NSUserName()
        return "f=$(mktemp) && echo '\(user) ALL=(root) NOPASSWD: /sbin/route' > \"$f\" && /usr/sbin/visudo -cf \"$f\" && sudo install -m 440 -o root -g wheel \"$f\" \(sudoersPath); rm -f \"$f\""
    }

    struct RootResult: Sendable { var ok = false; var cancelled = false; var error: String? }

    /// Выполнить sh-скрипт от root через системный запрос пароля. Скрипт должен печатать `OK` или `ERR|текст`.
    static func runRoot(_ sh: String, prompt: String) -> RootResult {
        var res = RootResult()
        if Demo.enabled { res.ok = true; return res }
        let r = Shell.run("/usr/bin/osascript", ["-e", appleScript(sh, prompt: prompt)])
        let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        if out == "OK" { res.ok = true }
        else if out.hasPrefix("ERR|") { res.error = String(out.dropFirst(4)) }
        else if err.contains("-128") { res.cancelled = true }
        else { res.error = err.isEmpty ? "неизвестная ошибка" : err }
        return res
    }

    static func sudoersScript(user: String) -> String {
        """
        s() {
          f=$(/usr/bin/mktemp /private/etc/sudoers.d/.routemanager.XXXXXX) || { echo "ERR|mktemp"; return; }
          printf '%s\\n' '\(user) ALL=(root) NOPASSWD: /sbin/route' > "$f"
          if /usr/sbin/visudo -cf "$f" >/dev/null 2>&1 && /bin/chmod 440 "$f" && /usr/sbin/chown root:wheel "$f" && /bin/mv -f "$f" \(sudoersPath); then echo "OK"; else /bin/rm -f "$f"; echo "ERR|проверка visudo не прошла"; fi
        }
        s
        """
    }

    /// Разрешить текущему пользователю `sudo /sbin/route` без пароля (только эту команду).
    static func installSudoers() -> RootResult {
        let user = NSUserName()
        guard !user.isEmpty, user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            return RootResult(error: "необычное имя пользователя — настройте вручную")
        }
        return runRoot(sudoersScript(user: user), prompt: "RouteManager хочет разрешить изменение маршрутов без пароля.")
    }

    static func removeSudoers() -> RootResult {
        runRoot("/bin/rm -f \(sudoersPath) && echo OK || echo 'ERR|не удалось удалить'", prompt: "RouteManager хочет отключить изменение маршрутов без пароля.")
    }

    /// Все аргументы — проверенные IP, подсети, имена интерфейсов и флаги route; другие символы в скрипт не попадают.
    private static func isSafe(_ arg: String) -> Bool {
        !arg.isEmpty && arg.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "./-_".contains($0)) }
    }

    /// commands: ["a", "-host", "1.2.3.4", "192.168.1.1"] — добавить (или заменить), ["d", "-net", "10.0.0.0/8"] — удалить.
    static func execute(_ commands: [[String]]) -> PrivilegedResult {
        if Demo.enabled { return Demo.execute(commands) }
        var result = PrivilegedResult()
        let lines = commands.filter { $0.count >= 3 && ["a", "d"].contains($0[0]) && $0.allSatisfy(isSafe) }
            .map { $0.joined(separator: " ") }
        guard !lines.isEmpty else { result.fatal = "нечего выполнять"; return result }

        let sudo = hasPasswordlessSudo
        result.viaSudo = sudo
        let sh = script(lines, route: sudo ? "/usr/bin/sudo -n /sbin/route" : "/sbin/route")
        let r = sudo ? Shell.run("/bin/sh", ["-c", sh]) : Shell.run("/usr/bin/osascript", ["-e", appleScript(sh)])

        if !r.ok && r.out.isEmpty {
            if r.err.contains("-128") { result.cancelled = true } else { result.fatal = r.err.trimmingCharacters(in: .whitespacesAndNewlines) }
            return result
        }
        parse(r.out, into: &result)
        return result
    }

    /// sh-скрипт: `a` — добавить (если уже есть — заменить через `route change`), `d` — удалить. Вывод: ADD|CHG|DEL|ERR построчно.
    static func script(_ lines: [String], route: String) -> String {
        let header = """
        R="\(route)"
        a() { o=$($R -n add "$@" 2>&1); s=$?; case "$o" in *"File exists"*) o=$($R -n change "$@" 2>&1); s=$?; if [ $s -eq 0 ]; then echo "CHG|$2"; return; fi;; esac; if [ $s -eq 0 ]; then echo "ADD|$2"; else echo "ERR|$2|$(printf '%s' "$o" | tr '\\n' ' ')"; fi; }
        d() { o=$($R -n delete "$@" 2>&1); if [ $? -eq 0 ]; then echo "DEL|$2"; else echo "ERR|$2|$(printf '%s' "$o" | tr '\\n' ' ')"; fi; }

        """
        return header + lines.joined(separator: "\n") + "\n"
    }

    /// Один запрос пароля на всю пачку.
    static func appleScript(_ sh: String, prompt: String = "RouteManager хочет изменить таблицу маршрутизации.") -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        return "do shell script \"\(esc(sh))\" with prompt \"\(esc(prompt))\" with administrator privileges without altering line endings"
    }

    static func parse(_ out: String, into result: inout PrivilegedResult) {
        for line in out.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "ADD": result.added += 1
            case "CHG": result.changed += 1
            case "DEL": result.deleted += 1
            case "ERR":
                let msg = f.count > 2 ? f[2].replacingOccurrences(of: "route: ", with: "").trimmingCharacters(in: .whitespaces) : "ошибка"
                result.failures.append(.init(dest: f.count > 1 ? f[1] : "?", message: msg))
            default: break
            }
        }
    }
}
