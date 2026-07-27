//
//  DomainResolver.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/07/13.
//

import Foundation

struct DomainResolver {
    /// How the transport should reach a host.
    enum Resolution {
        /// Connect straight to these addresses, freshest first.
        case bypass(addresses: [String])
        /// Not part of the bypass table, let the system resolve the name.
        case system
        /// A bypass host that neither the system nor the bundled table could resolve.
        case unresolved
    }

    /// Successful resolutions stay usable for this long before being refreshed.
    static let cacheTTL: TimeInterval = 300
    /// Bundled addresses are stale by nature, so they are re-checked far more often.
    static let fallbackCacheTTL: TimeInterval = 30

    private static let lock = NSLock()
    private static var cache = [String: CachedAddresses]()

    private struct CachedAddresses {
        let addresses: [String]
        let expiration: Date
    }

    /// Resolves a bypass host, preferring live DNS over the bundled constants.
    ///
    /// Every candidate is returned, freshest first: the bundled table never
    /// replaces a live answer, it extends it. A poisoned or unhealthy record
    /// therefore no longer suppresses the fallback, it is simply tried first
    /// and the transport fails over once it is exhausted.
    static func resolve(domain: String) -> Resolution {
        guard !domain.isEmpty, let resolvable = ResolvableDomain(rawValue: domain)
        else { return .system }

        if let cached = cachedAddresses(for: domain) {
            return .bypass(addresses: cached)
        }

        let live = systemAddresses(for: domain)
        var addresses = live

        for address in resolvable.fallbackAddresses where !addresses.contains(address) {
            addresses.append(address)
        }
        guard !addresses.isEmpty else {
            Logger.error("No address could be resolved for: \(domain).")
            return .unresolved
        }
        if live.isEmpty {
            Logger.warning("DNS returned nothing, using bundled addresses for: \(domain).")
        }

        store(addresses, for: domain, ttl: live.isEmpty ? fallbackCacheTTL : cacheTTL)
        return .bypass(addresses: addresses)
    }
}

// MARK: Cache
private extension DomainResolver {
    static func cachedAddresses(for domain: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = cache[domain] else { return nil }
        guard entry.expiration > Date() else {
            cache.removeValue(forKey: domain)
            return nil
        }
        return entry.addresses
    }

    static func store(_ addresses: [String], for domain: String, ttl: TimeInterval) {
        lock.lock()
        cache[domain] = CachedAddresses(
            addresses: addresses,
            expiration: Date().addingTimeInterval(ttl)
        )
        lock.unlock()
    }
}

// MARK: Resolution
private extension DomainResolver {
    /// Resolves both A and AAAA records, in the order the system prefers for
    /// the current path. `AI_ADDRCONFIG` keeps IPv6 literals out of the result
    /// on IPv4-only networks and vice versa.
    static func systemAddresses(for domain: String) -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var head: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(domain, nil, &hints, &head)

        guard status == 0, let first = head else {
            if status != 0 {
                let reason = String(cString: gai_strerror(status))
                Logger.warning("DNS resolution failed for \(domain): \(reason).")
            }
            return []
        }
        defer { freeaddrinfo(first) }

        var addresses = [String]()
        var cursor: UnsafeMutablePointer<addrinfo>? = first

        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let converted = getnameinfo(
                info.pointee.ai_addr, info.pointee.ai_addrlen,
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST
            )
            if converted == 0 {
                let address = String(cString: buffer)
                if !address.isEmpty, !addresses.contains(address) {
                    addresses.append(address)
                }
            }
            cursor = info.pointee.ai_next
        }
        return addresses
    }
}

enum ResolvableDomain: String {
    case ehgt = "ehgt.org"
    case ehgt0 = "gt0.ehgt.org"
    case ehgt1 = "gt1.ehgt.org"
    case ehgt2 = "gt2.ehgt.org"
    case ehgt3 = "gt3.ehgt.org"
    case ehgtul = "ul.ehgt.org"
    case ehentai = "e-hentai.org"
    case exhentai = "exhentai.org"
    case repo = "repo.e-hentai.org"
    case forums = "forums.e-hentai.org"
    case github = "raw.githubusercontent.com"
}

private extension ResolvableDomain {
    /// Last-resort addresses for networks whose resolver is unavailable or
    /// poisoned. They are not maintained, so they are only tried in order
    /// after live resolution has failed.
    var fallbackAddresses: [String] {
        switch self {
        case .ehgt, .ehgt0, .ehgt1, .ehgt2, .ehgt3:
            return [
                "37.48.89.44", "81.171.10.48",
                "178.162.139.24", "178.162.140.212"
            ]
        case .ehgtul:
            return ["94.100.24.82", "94.100.24.72"]
        case .ehentai:
            return [
                "104.20.134.21", "104.20.135.21",
                "172.67.0.127"
            ]
        case .exhentai:
            return [
                "178.175.128.252", "178.175.129.252",
                "178.175.129.254", "178.175.128.254",
                "178.175.132.20", "178.175.132.22"
            ]
        case .repo:
            return ["94.100.28.57", "94.100.29.73"]
        case .forums:
            return ["94.100.18.243"]
        case .github:
            return [
                "151.101.0.133", "151.101.64.133",
                "151.101.128.133", "151.101.192.133"
            ]
        }
    }
}
