import ArgumentParser
import AsyncHTTPClient
import Foundation
import NIO
import NIOHTTP1
import Darwin.C


extension Validator {
    struct CheckDependencies: ParsableCommand {
        @Option(name: .shortAndLong, help: "limit number of urls to check")
        var limit: Int?

        @Option(name: .shortAndLong, help: "read input from file")
        var input: String?

        @Option(name: .shortAndLong, help: "save changes to output file")
        var output: String?

        @Argument(help: "Package urls to check")
        var packageUrls: [PackageURL] = []

        @Option(name: .shortAndLong, help: "number of retries")
        var retries: Int = 3

        @Flag(name: .long, help: "check redirects of canonical package list")
        var usePackageList = false

        var inputSource: InputSource {
            switch (input, usePackageList, packageUrls.count) {
                case (.some(let fname), false, 0):
                    return .file(fname)
                case (.none, true, 0):
                    return .packageList
                case (.none, false, 1...):
                    return .packageURLs(packageUrls)
                default:
                    return .invalid
            }
        }

        func validate() throws {
            if case .invalid = inputSource {
                throw ValidationError("Specify either an input file (--input), --usePackageList, or a list of package URLs")
            }
        }

        mutating func run() throws {
            if Current.githubToken() == nil {
                print("Warning: Using anonymous authentication -- you will quickly run into rate limiting issues\n")
            }

            let inputURLs = try inputSource.packageURLs()

            print("Checking dependencies (\(limit ?? inputURLs.count) packages) ...")

            let updated = try expandDependencies(inputURLs: inputURLs,
                                                 limit: limit,
                                                 retries: retries)

            if let path = output {
                try Current.fileManager.saveList(updated, path: path)
            }
        }
    }
}


/// Checks and expands dependencies from a set of input package URLs. The list of output URLs is unique, sorted, and will preserve the capitalization of the first URL encountered.
/// - Parameter inputURLs: package URLs to inspect
/// - Returns: complete list of package URLs, including the input set
func expandDependencies(inputURLs: [PackageURL],
                        limit: Int? = nil,
                        retries: Int) throws -> [PackageURL] {
    try inputURLs
        .prefix(limit ?? inputURLs.count)
        .flatMap { packageURL -> [PackageURL] in
            do {
                return try findDependencies(packageURL: packageURL,
                                            waitIfRateLimited: true,
                                            retries: retries)
            } catch AppError.invalidPackage {
                return []
            }
        }
        .mergingWithExisting(urls: inputURLs)
        .sorted(by: { $0.lowercased() < $1.lowercased() })
}


func resolvePackageRedirects(eventLoop: EventLoop, urls: [PackageURL]) -> EventLoopFuture<[PackageURL]> {
    let requests = urls.map {
        Current.resolvePackageRedirects(eventLoop, $0)
            .map(\.url)
    }
    let flattened = EventLoopFuture.whenAllSucceed(requests, on: eventLoop)
    return flattened.map {
        // drop nil urls
        $0.compactMap({ $0 })
    }
}


func dropForks(client: HTTPClient, urls: [PackageURL]) -> EventLoopFuture<[PackageURL]> {
    Github.fetchRepositories(client: client, urls: urls)
        .map { pairs in
            pairs.filter { (url, repo) in
                guard let repo = repo else { return false }
                return !repo.fork
            }
            .map { (url, repo) in url }
        }
}


func dropNoProducts(client: HTTPClient, packageURLs: [PackageURL]) -> EventLoopFuture<[PackageURL]> {
    let req = packageURLs
        .map { packageURL in
            Package.getManifestURL(client: client, packageURL: packageURL)
                .map { (packageURL, $0) }
        }
    return EventLoopFuture.whenAllSucceed(req, on: client.eventLoopGroup.next())
        .map { pairs in
            pairs.filter { (_, manifestURL) in
                guard let pkg = try? Current.decodeManifest(manifestURL) else { return false }
                return !pkg.products.isEmpty
            }
            .map { (packageURL, _) in packageURL }
        }
}


func findDependencies(packageURL: PackageURL,
                      waitIfRateLimited: Bool,
                      retries: Int) throws -> [PackageURL] {
    try Retry.attempt("Finding dependencies", retries: retries) {
        do {
            let client = HTTPClient(eventLoopGroupProvider: .createNew)
            defer { try? client.syncShutdown() }
            return try findDependencies(client: client, url: packageURL).wait()
        } catch AppError.rateLimited(until: let reset) where waitIfRateLimited {
            print("RATE LIMITED")
            print("rate limit will reset at \(reset)")
            let delay = UInt32(max(0, reset.timeIntervalSinceNow) + 60)
            print("sleeping for \(delay) seconds ...")
            fflush(stdout)
            sleep(delay)
            print("now: \(Date())")
            throw AppError.rateLimited(until: reset)
        } catch let error as NSError {
            if error.code == 256
                && error.localizedDescription == "The file “Package.swift” couldn’t be opened." {
                print("Warning: invalid package: \(packageURL): \(error.localizedDescription)")
                throw AppError.invalidPackage(url: packageURL)
            }
            print("ERROR: \(error)")
            throw error
        } catch {
            print("ERROR: \(error)")
            throw error
        }
    }
}


func findDependencies(client: HTTPClient, url: PackageURL) throws -> EventLoopFuture<[PackageURL]> {
    let el = client.eventLoopGroup.next()
    print("Dependencies for \(url.absoluteString) ...")
    return Package.getManifestURL(client: client, packageURL: url)
        .flatMapThrowing {
            try Current.decodeManifest($0)
                .dependencies
                .filter { $0.url.scheme == "https" }
                .filter { $0.url.host?.lowercased() == "github.com" }
                .map { $0.url.appendingGitExtension() }
        }
        .flatMapError { error in
            switch error {
                case AppError.dumpPackageError, AppError.repositoryNotFound:
                    print("INFO: Skipping package due to error: \(error)")
                    return el.makeSucceededFuture([])
                default:
                    return el.makeFailedFuture(error)
            }
        }
        .flatMap { resolvePackageRedirects(eventLoop: el, urls: $0) }
        .flatMap { dropForks(client: client, urls: $0) }
        .flatMap { dropNoProducts(client: client, packageURLs: $0) }
        .map { $0.map { $0.appendingGitExtension() } }
        .map { urls in
            urls.forEach {
                print("  - \($0.absoluteString)")
            }
            fflush(stdout)
            return urls
        }
}


func fetch<T: Decodable>(_ type: T.Type, client: HTTPClient, url: URL) -> EventLoopFuture<T> {
    let eventLoop = client.eventLoopGroup.next()
    let headers = HTTPHeaders([
        ("User-Agent", "SPI-Validator"),
        Current.githubToken().map { ("Authorization", "Bearer \($0)") }
    ].compactMap({ $0 }))

    do {
        let request = try HTTPClient.Request(url: url, method: .GET, headers: headers)
        return client.execute(request: request)
            .flatMap { response in
                if case let .limited(until: reset) = Github.rateLimitStatus(response) {
                    return eventLoop.makeFailedFuture(AppError.rateLimited(until: reset))
                }
                guard (200...299).contains(response.status.code) else {
                    return eventLoop.makeFailedFuture(
                        AppError.requestFailed(url, response.status.code)
                    )
                }
                guard let body = response.body else {
                    return eventLoop.makeFailedFuture(AppError.noData(url))
                }
                do {
                    let content = try JSONDecoder().decode(type, from: body)
                    return eventLoop.makeSucceededFuture(content)
                } catch {
                    let json = body.getString(at: 0, length: body.readableBytes) ?? "(nil)"
                    return eventLoop.makeFailedFuture(
                        AppError.decodingError(context: url.absoluteString,
                                               underlyingError: error,
                                               json: json))
                }
            }
    } catch {
        return eventLoop.makeFailedFuture(error)
    }
}
