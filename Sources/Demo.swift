import Foundation

/// Демо-режим для скриншотов и знакомства с приложением: `RouteManager --demo`
/// (или `open RouteManager.app --args --demo`). Все сетевые данные выдуманные
/// (адреса из документационных диапазонов RFC 5737 и домены *.example),
/// ничего не меняется в системе и не пишется в ваши списки.
enum Demo {
    static let enabled: Bool =
        ProcessInfo.processInfo.arguments.contains("--demo")
        || ProcessInfo.processInfo.environment["ROUTEMANAGER_DEMO"] == "1"

    // MARK: Сеть

    static let router = IPv4(value: 0xC0A8_0101) // 192.168.1.1
    static let routerIface = "en0"
    static let vpnIface = "utun4"

    static var snapshot: NetworkSnapshot {
        NetworkSnapshot(
            gateways: [
                Gateway(kind: .router(router), iface: routerIface, name: "Wi-Fi (en0)", isPrimary: false),
                Gateway(kind: .interface, iface: vpnIface, name: "VPN (utun4)", isPrimary: true),
            ],
            interfaceNames: ["en0": "Wi-Fi (en0)", "utun4": "VPN (utun4)", "lo0": "lo0"]
        )
    }

    // MARK: Списки

    static var lists: [IPList] {
        [
            IPList(name: "Банки и госсервисы", text: """
            # Сайты, которые не открываются через VPN
            bank.example
            online.bank.example
            gov.example
            198.51.100.25
            198.51.100.26

            """, gateway: .currentRouter, autoApply: true),
            IPList(name: "Рабочая сеть", text: """
            10.20.0.0/16
            172.20.30.0/24
            git.corp.example

            """, gateway: .currentRouter, autoApply: true),
            IPList(name: "Видео через VPN", text: """
            video.example
            203.0.113.0/24

            """, gateway: .interface(vpnIface), autoApply: false),
        ]
    }

    static let dns: [String: [String]] = [
        "bank.example": ["198.51.100.10", "198.51.100.11"],
        "online.bank.example": ["198.51.100.12"],
        "gov.example": ["192.0.2.40"],
        "git.corp.example": ["10.20.1.15"],
        "video.example": ["203.0.113.80"],
        "example.com": ["203.0.113.10"],
        "staging.example.com": ["203.0.113.50"],
    ]

    static func resolve(_ host: String) -> [IPv4] {
        (dns[host] ?? []).compactMap(IPv4.init)
    }

    // MARK: Таблица маршрутов (симуляция `route`)

    private struct UserRoute { var target: RouteTarget; var gateway: String; var iface: String }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var userRoutes: [UserRoute] = [
        UserRoute(target: .net(IPv4("10.0.0.0")!, 8), gateway: "192.168.1.1", iface: "en0"),
        UserRoute(target: .net(IPv4("172.16.0.0")!, 12), gateway: "192.168.1.1", iface: "en0"),
        UserRoute(target: .net(IPv4("192.168.0.0")!, 16), gateway: "192.168.1.1", iface: "en0"),
        UserRoute(target: .host(IPv4("192.0.2.200")!), gateway: "192.168.1.1", iface: "en0"),
    ]

    private static let systemRows: [RouteRow] = [
        ("127.0.0.0/8", "127.0.0.1", "lo0", "UCS"),
        ("169.254.0.0/16", "link#14", "en0", "UCS"),
        ("192.168.1.0/24", "link#14", "en0", "UCS"),
        ("224.0.0.0/4", "link#14", "en0", "UmCS"),
        ("255.255.255.255", "link#14", "en0", "UCS"),
    ].map { d, g, i, f in
        RouteRow(id: "sys|\(d)|\(i)", destination: d, gateway: g, iface: i, flags: f, isUser: false,
                 deleteArgs: d.contains("/") ? ["-net", d] : ["-host", d])
    }

    static func routes() -> [RouteRow] {
        lock.lock(); defer { lock.unlock() }
        let user = userRoutes.sorted { $0.target < $1.target }.map { r -> RouteRow in
            let isHost: Bool = { if case .host = r.target { return true } else { return false } }()
            let viaRouter = !r.gateway.hasPrefix("link#")
            let flags = (viaRouter ? "UG" : "U") + (isHost ? "HS" : "Sc")
            return RouteRow(id: "user|\(r.target)", destination: r.target.description, gateway: r.gateway,
                            iface: r.iface, flags: flags, isUser: true, deleteArgs: r.target.routeArgs)
        }
        return systemRows + user
    }

    static func probe(_ ip: IPv4) -> RouteProbe {
        lock.lock(); defer { lock.unlock() }
        func prefix(_ t: RouteTarget) -> Int { if case .net(_, let p) = t { return p } else { return 32 } }
        func contains(_ t: RouteTarget) -> Bool {
            switch t {
            case .host(let h): return h == ip
            case .net(let n, let p): return ip.isIn(n, p)
            }
        }
        if let best = userRoutes.filter({ contains($0.target) }).max(by: { prefix($0.target) < prefix($1.target) }) {
            return RouteProbe(gateway: best.gateway.hasPrefix("link#") ? nil : best.gateway,
                              interface: best.iface, destination: best.target.description)
        }
        return RouteProbe(gateway: nil, interface: vpnIface, destination: "default")
    }

    /// Выполняет команды `a`/`d` над выдуманной таблицей.
    static func execute(_ commands: [[String]]) -> PrivilegedResult {
        lock.lock(); defer { lock.unlock() }
        var res = PrivilegedResult()
        res.viaSudo = true
        for c in commands where c.count >= 3 {
            let raw = c[2]
            guard let target = EntryParser.literal(raw) else { continue }
            if c[0] == "d" {
                let before = userRoutes.count
                userRoutes.removeAll { $0.target == target }
                if userRoutes.count < before { res.deleted += 1 } else {
                    res.failures.append(.init(dest: raw, message: "writing to routing socket: not in table"))
                }
            } else {
                let gwArgs = Array(c.dropFirst(3))
                let route: UserRoute = gwArgs.first == "-interface" && gwArgs.count > 1
                    ? UserRoute(target: target, gateway: "link#20", iface: gwArgs[1])
                    : UserRoute(target: target, gateway: gwArgs.first ?? "?", iface: routerIface)
                if let i = userRoutes.firstIndex(where: { $0.target == target }) {
                    userRoutes[i] = route; res.changed += 1
                } else {
                    userRoutes.append(route); res.added += 1
                }
            }
        }
        return res
    }

    // MARK: hosts

    nonisolated(unsafe) static var hostsText = """
    ##
    # Host Database
    #
    # localhost is used to configure the loopback interface
    # when the system is booting.  Do not change this entry.
    ##
    127.0.0.1	localhost
    255.255.255.255	broadcasthost
    ::1             localhost

    # Локальная разработка
    127.0.0.1	myapp.test api.myapp.test
    192.168.1.20	nas.home.example	# домашний NAS
    203.0.113.50	staging.example.com	# временно, до переезда DNS

    # Блокировка
    0.0.0.0	ads.example.net tracker.example.net
    #0.0.0.0	analytics.example.org

    """
}
