// OpenFoodJournal — Secure Assistant URL fetching
// Treats remote content as untrusted evidence and prevents fetch_url from
// reaching local/private infrastructure or admitting unbounded payloads.
// AGPL-3.0 License

import Foundation
import Darwin

nonisolated enum ChatURLSecurityError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case unsupportedScheme
    case credentialsNotAllowed
    case blockedPort(Int)
    case blockedHost(String)
    case privateAddress(String)
    case dnsLookupFailed(String)
    case dnsRebinding(String)
    case unsafeRedirect
    case invalidHTTPResponse
    case httpStatus(Int)
    case responseTooLarge(Int)
    case unsupportedMIMEType(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "A valid public http(s) URL is required."
        case .unsupportedScheme:
            return "Only http and https URLs can be fetched."
        case .credentialsNotAllowed:
            return "URLs containing a username or password are not allowed."
        case .blockedPort(let port):
            return "Port \(port) is not allowed."
        case .blockedHost(let host):
            return "The host \(host) is not a public internet destination."
        case .privateAddress:
            return "The URL resolves to a private, local, or reserved network address."
        case .dnsLookupFailed(let host):
            return "Could not safely resolve \(host)."
        case .dnsRebinding:
            return "The host's network address changed during the download."
        case .unsafeRedirect:
            return "The download attempted an unsafe redirect."
        case .invalidHTTPResponse:
            return "The server did not return a valid HTTP response."
        case .httpStatus(let status):
            return "The server returned HTTP \(status)."
        case .responseTooLarge(let limit):
            return "The response is larger than the \(limit / 1_048_576)MB download limit."
        case .unsupportedMIMEType(let type):
            let displayType = type.isEmpty ? "unknown" : type
            return "The response type \(displayType) is not supported."
        }
    }
}

nonisolated struct ChatResolvedAddress: Hashable, Sendable {
    let family: Int32
    let bytes: [UInt8]
}

nonisolated protocol ChatHostResolving: Sendable {
    func addresses(for host: String) throws -> Set<ChatResolvedAddress>
}

nonisolated struct SystemChatHostResolver: ChatHostResolving {
    func addresses(for host: String) throws -> Set<ChatResolvedAddress> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            throw ChatURLSecurityError.dnsLookupFailed(host)
        }
        defer { freeaddrinfo(first) }

        var addresses: Set<ChatResolvedAddress> = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            let info = current.pointee
            if info.ai_family == AF_INET, let pointer = info.ai_addr {
                var address = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                addresses.insert(ChatResolvedAddress(
                    family: AF_INET,
                    bytes: withUnsafeBytes(of: &address) { Array($0) }
                ))
            } else if info.ai_family == AF_INET6, let pointer = info.ai_addr {
                var address = pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr
                }
                addresses.insert(ChatResolvedAddress(
                    family: AF_INET6,
                    bytes: withUnsafeBytes(of: &address) { Array($0) }
                ))
            }
            cursor = info.ai_next
        }
        guard !addresses.isEmpty else {
            throw ChatURLSecurityError.dnsLookupFailed(host)
        }
        return addresses
    }
}

nonisolated enum ChatURLSecurityPolicy {
    private static let blockedHostnames: Set<String> = [
        "localhost",
        "localhost.localdomain",
        "metadata.google.internal",
        "metadata.azure.internal",
        "instance-data.ec2.internal",
    ]

    private static func normalizedHost(_ host: String) -> String {
        var normalized = host
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized.removeFirst()
            normalized.removeLast()
        }
        return normalized
    }

    static func validateStructure(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host else {
            throw ChatURLSecurityError.invalidURL
        }
        let host = normalizedHost(rawHost)
        guard !host.isEmpty else { throw ChatURLSecurityError.invalidURL }
        guard scheme == "http" || scheme == "https" else {
            throw ChatURLSecurityError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw ChatURLSecurityError.credentialsNotAllowed
        }
        if let port = components.port, port != 80, port != 443 {
            throw ChatURLSecurityError.blockedPort(port)
        }
        if blockedHostnames.contains(host)
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal") {
            throw ChatURLSecurityError.blockedHost(host)
        }
        if let literal = literalAddress(host), !isPublic(literal) {
            throw ChatURLSecurityError.privateAddress(host)
        }
    }

    static func validatedAddresses(
        for url: URL,
        resolver: any ChatHostResolving
    ) throws -> Set<ChatResolvedAddress> {
        try validateStructure(url)
        guard let rawHost = url.host else {
            throw ChatURLSecurityError.invalidURL
        }
        let host = normalizedHost(rawHost)
        let addresses = try resolver.addresses(for: host)
        guard addresses.allSatisfy(isPublic) else {
            throw ChatURLSecurityError.privateAddress(host)
        }
        return addresses
    }

    static func validateStableDNS(
        initial: Set<ChatResolvedAddress>,
        current: Set<ChatResolvedAddress>,
        host: String
    ) throws {
        guard initial == current else {
            throw ChatURLSecurityError.dnsRebinding(host)
        }
    }

    static func supports(mimeType: String, data: Data) -> Bool {
        let mime = mimeType.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        if data.starts(with: Data("%PDF".utf8)) { return true }
        if mime.hasPrefix("text/") || mime.hasPrefix("image/") { return true }
        return [
            "application/pdf",
            "application/json",
            "application/ld+json",
            "application/xml",
            "application/xhtml+xml",
            "application/javascript",
            "application/x-javascript",
            "application/csv",
        ].contains(mime)
    }

    private static func literalAddress(_ host: String) -> ChatResolvedAddress? {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return ChatResolvedAddress(
                family: AF_INET,
                bytes: withUnsafeBytes(of: &ipv4) { Array($0) }
            )
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return ChatResolvedAddress(
                family: AF_INET6,
                bytes: withUnsafeBytes(of: &ipv6) { Array($0) }
            )
        }
        return nil
    }

    static func isPublic(_ address: ChatResolvedAddress) -> Bool {
        if address.family == AF_INET, address.bytes.count == 4 {
            let b = address.bytes
            if b[0] == 0 || b[0] == 10 || b[0] == 127 { return false }
            if b[0] == 100 && (64...127).contains(b[1]) { return false }
            if b[0] == 169 && b[1] == 254 { return false }
            if b[0] == 172 && (16...31).contains(b[1]) { return false }
            if b[0] == 192 && b[1] == 168 { return false }
            if b[0] == 192 && b[1] == 0 { return false }
            if b[0] == 198 && (b[1] == 18 || b[1] == 19) { return false }
            if b[0] >= 224 { return false }
            return true
        }
        if address.family == AF_INET6, address.bytes.count == 16 {
            let b = address.bytes
            if b.allSatisfy({ $0 == 0 }) { return false }
            if b.dropLast().allSatisfy({ $0 == 0 }) && b.last == 1 { return false }
            if b[0] == 0xff || (b[0] & 0xfe) == 0xfc { return false }
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return false }
            if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false }
            if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
                return isPublic(ChatResolvedAddress(family: AF_INET, bytes: Array(b.suffix(4))))
            }
            return true
        }
        return false
    }
}

private final class ChatRedirectSafetyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let resolver: any ChatHostResolving
    private let lock = NSLock()
    private var resolved: [String: Set<ChatResolvedAddress>] = [:]

    init(resolver: any ChatHostResolving) {
        self.resolver = resolver
    }

    func addressesResolved(for host: String) -> Set<ChatResolvedAddress>? {
        lock.lock()
        defer { lock.unlock() }
        return resolved[host.lowercased()]
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let addresses = try? ChatURLSecurityPolicy.validatedAddresses(for: url, resolver: resolver),
              let host = url.host?.lowercased() else {
            completionHandler(nil)
            return
        }
        lock.lock()
        resolved[host] = addresses
        lock.unlock()
        completionHandler(request)
    }
}

@MainActor
final class SecureChatURLFetcher: ChatURLFetching {
    private let session: URLSession
    private let resolver: any ChatHostResolving
    private let maximumBytes: Int

    init(
        configuration: URLSessionConfiguration = .default,
        resolver: any ChatHostResolving = SystemChatHostResolver(),
        maximumBytes: Int = 15 * 1024 * 1024
    ) {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
        self.resolver = resolver
        self.maximumBytes = maximumBytes
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        let initialAddresses = try ChatURLSecurityPolicy.validatedAddresses(for: url, resolver: resolver)
        let redirectDelegate = ChatRedirectSafetyDelegate(resolver: resolver)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("text/html, text/plain, application/json, application/pdf, image/*", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
        guard let http = response as? HTTPURLResponse else {
            throw ChatURLSecurityError.invalidHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if (300..<400).contains(http.statusCode) {
                throw ChatURLSecurityError.unsafeRedirect
            }
            throw ChatURLSecurityError.httpStatus(http.statusCode)
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw ChatURLSecurityError.responseTooLarge(maximumBytes)
        }

        var data = Data()
        data.reserveCapacity(max(0, min(Int(response.expectedContentLength), maximumBytes)))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else {
                throw ChatURLSecurityError.responseTooLarge(maximumBytes)
            }
            data.append(byte)
        }

        let finalURL = response.url ?? url
        let finalAddresses = try ChatURLSecurityPolicy.validatedAddresses(for: finalURL, resolver: resolver)
        if finalURL.host?.caseInsensitiveCompare(url.host ?? "") == .orderedSame,
           let initialHost = url.host {
            try ChatURLSecurityPolicy.validateStableDNS(
                initial: initialAddresses,
                current: finalAddresses,
                host: initialHost
            )
        }
        if let finalHost = finalURL.host?.lowercased(),
           let redirectAddresses = redirectDelegate.addressesResolved(for: finalHost) {
            try ChatURLSecurityPolicy.validateStableDNS(
                initial: redirectAddresses,
                current: finalAddresses,
                host: finalHost
            )
        }
        guard ChatURLSecurityPolicy.supports(mimeType: response.mimeType ?? "", data: data) else {
            throw ChatURLSecurityError.unsupportedMIMEType(response.mimeType ?? "")
        }
        return (data, response)
    }
}
