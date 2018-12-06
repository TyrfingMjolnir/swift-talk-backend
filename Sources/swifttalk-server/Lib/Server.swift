//
//  Server.swift
//  Bits
//
//  Created by Chris Eidhof on 31.07.18.
//

import Foundation
import NIO
import NIOHTTP1
import NIOFoundationCompat


enum HTTPMethod: String, Codable {
    case post = "POST"
    case get = "GET"
}

struct Request {
    var path: [String]
    var query: [String:String]
    var method: HTTPMethod
    var cookies: [(String, String)]
}

protocol Interpreter {
    static func write(_ string: String, status: HTTPResponseStatus, headers: [String: String]) -> Self
    static func write(_ data: Data, status: HTTPResponseStatus, headers: [String: String]) -> Self
    static func writeFile(path: String, maxAge: UInt64?) -> Self
    static func redirect(path: String, headers: [String: String]) -> Self
    static func onComplete<A>(promise: Promise<A>, do cont: @escaping (A) -> Self) -> Self
    static func withPostData(do cont: @escaping (Data) -> Self) -> Self
}

extension Interpreter {
    static func writeFile(path: String) -> Self {
        return .writeFile(path: path, maxAge: 60)
    }
}

extension Interpreter {
    static func notFound(_ string: String = "Not found") -> Self {
        return .write(string, status: .notFound)
    }

    static func write(_ string: String, status: HTTPResponseStatus = .ok) -> Self {
        return .write(string, status: status, headers: [:])
    }

    static func write<I>(_ html: ANode<I>, input: I, status: HTTPResponseStatus = .ok) -> Self {
        return .write(html.htmlDocument(input: input))
    }
    
    static func write(xml: ANode<()>, status: HTTPResponseStatus = .ok) -> Self {
        return Self.write(xml.xmlDocument, status: .ok, headers: ["Content-Type": "application/rss+xml; charset=utf-8"])
    }
    
    static func write(json: Data, status: HTTPResponseStatus = .ok) -> Self {
        return Self.write(json, status: .ok, headers: ["Content-Type": "application/json"])
    }

    static func redirect(path: String) -> Self {
        return .redirect(path: path, headers: [:])
    }
    
    static func redirect(to route: Route, headers: [String: String] = [:]) -> Self {
        return .redirect(path: route.path, headers: headers)
    }
    
    static func withPostBody(do cont: @escaping ([String:String]) -> Self) -> Self {
        return .withPostData { data in
            let result = String(data: data, encoding: .utf8)?.parseAsQueryPart
            return cont(result ?? [:])
        }
    }
    
    static func withPostBody(do cont: @escaping ([String:String]) -> Self, or: @escaping () -> Self) -> Self {
        return .withPostData { data in
            let result = String(data: data, encoding: .utf8)?.parseAsQueryPart
            if let r = result {
                return cont(r)
            } else {
                return or()
            }
        }
    }

    static func onComplete<A>(promise: Promise<A>, do cont: @escaping (A) throws -> Self) -> Self {
        return onComplete(promise: promise, do: { value in
            catchAndDisplayError { try cont(value) }
        })
    }
    
    static func onSuccess<A>(promise: Promise<A?>, file: StaticString = #file, line: UInt = #line, message: String = "Something went wrong.", do cont: @escaping (A) throws -> Self) -> Self {
        return onComplete(promise: promise, do: { value in
            catchAndDisplayError {
                guard let v = value else {
                    throw RenderingError(privateMessage: "Expected non-nil value, but got nil (\(file):\(line)).", publicMessage: message)
                }
                return try cont(v)
            }
        })
    }
    
    static func onSuccess<A>(promise: Promise<A?>, file: StaticString = #file, line: UInt = #line, message: String = "Something went wrong.", do cont: @escaping (A) throws -> Self, or: @escaping () throws -> Self) -> Self {
        return onComplete(promise: promise, do: { value in
            catchAndDisplayError {
                if let v = value {
                    return try cont(v)
                } else {
                    return try or()
                }
            }
        })
    }
    
    static func withPostBody(do cont: @escaping ([String:String]) throws -> Self) -> Self {
        return .withPostBody { dict in
            return catchAndDisplayError { try cont(dict) }
        }
    }
    
    static func withPostBody(do cont: @escaping ([String:String]) throws -> Self, or: @escaping () throws -> Self) -> Self {
        return .withPostData { data in
            return catchAndDisplayError {
                // TODO instead of checking whether data is empty, we should check whether it was a post?
                if !data.isEmpty, let r = String(data: data, encoding: .utf8)?.parseAsQueryPart {
                    return try cont(r)
                } else {
                    return try or()
                }
            }
        }
    }
    
    static func withPostBody(csrf: CSRFToken, do cont: @escaping ([String:String]) throws -> Self, or: @escaping () throws -> Self) -> Self {
        return .withPostBody(do: { body in
            guard body["csrf"] == csrf.stringValue else {
                throw RenderingError(privateMessage: "CSRF failure", publicMessage: "Something went wrong.")
            }
            return try cont(body)
        }, or: or)
    }
    
    static func withPostBody(csrf: CSRFToken, do cont: @escaping ([String:String]) throws -> Self) -> Self {
        return .withPostBody(do: { body in
            guard body["csrf"] == csrf.stringValue else {
                throw RenderingError(privateMessage: "CSRF failure", publicMessage: "Something went wrong.")
            }
            return try cont(body)
        })
    }
}

struct NIOInterpreter: Interpreter {
    struct Deps {
        let header: HTTPRequestHead
        let ctx: ChannelHandlerContext
        let fileIO: NonBlockingFileIO
        let handler: RouteHandler
        let manager: FileManager
        let resourcePaths: [URL]
    }
    let run: (Deps) -> PostContinuation?
    typealias PostContinuation = (Data) -> NIOInterpreter
    
    static func withPostData(do cont: @escaping PostContinuation) -> NIOInterpreter {
        return NIOInterpreter { env in
            return cont
        }
    }

    static func redirect(path: String, headers: [String: String] = [:]) -> NIOInterpreter {
        return NIOInterpreter { env in
            // We're using seeOther (303) because it won't do a POST but always a GET (important for forms)
            var head = HTTPResponseHead(version: env.header.version, status: .seeOther)
            head.headers.add(name: "Location", value: path)
            for (key, value) in headers {
                head.headers.add(name: key, value: value)
            }
            let part = HTTPServerResponsePart.head(head)
            _ = env.ctx.channel.write(part)
            _ = env.ctx.channel.writeAndFlush(HTTPServerResponsePart.end(nil)).then {
                env.ctx.channel.close()
            }
            return nil
        }
    }
    
    static func writeFile(path: String, maxAge: UInt64? = 60) -> NIOInterpreter {
        return NIOInterpreter { deps in
            let fullPath = deps.resourcePaths.resolve(path) ?? URL(fileURLWithPath: "")
            let fileHandleAndRegion = deps.fileIO.openFile(path: fullPath.path, eventLoop: deps.ctx.eventLoop)
            fileHandleAndRegion.whenFailure { _ in
                _ = write("Error", status: .badRequest).run(deps)
            }
            fileHandleAndRegion.whenSuccess { (file, region) in
                var response = HTTPResponseHead(version: deps.header.version, status: .ok)
                response.headers.add(name: "Content-Length", value: "\(region.endIndex)")
                let contentType: String
                // (path as NSString) doesn't work on Linux... so using the initializer below.
                switch NSString(string: path).pathExtension {
                case "css": contentType = "text/css; charset=utf-8"
                case "svg": contentType = "image/svg+xml; charset=utf8"
                default: contentType = "text/plain; charset=utf-8"
                }
                response.headers.add(name: "Content-Type", value: contentType)
                if let m = maxAge {
                	response.headers.add(name: "Cache-Control", value: "max-age=\(m)")
                }
                deps.ctx.write(deps.handler.wrapOutboundOut(.head(response)), promise: nil)
                deps.ctx.writeAndFlush(deps.handler.wrapOutboundOut(.body(.fileRegion(region)))).then {
                    let p: EventLoopPromise<Void> = deps.ctx.eventLoop.newPromise()
                    deps.ctx.writeAndFlush(deps.handler.wrapOutboundOut(.end(nil)), promise: p)
                    
                    return p.futureResult
                    }.thenIfError { (_: Error) in
                        deps.ctx.close()
                    }.whenComplete {
                        _ = try? file.close()
                }
            }
            return nil
        }
    }
    
    static func onComplete<A>(promise: Promise<A>, do cont: @escaping (A) -> NIOInterpreter) -> NIOInterpreter {
        return NIOInterpreter { env in
            promise.run { str in
                env.ctx.eventLoop.execute {
                    let result = cont(str).run(env)
                    assert(result == nil, "You have to read POST data as the first step")
                }

            }
            return nil
        }
    }
    
    static func write(_ data: Data, status: HTTPResponseStatus = .ok, headers: [String: String] = [:]) -> NIOInterpreter {
        return NIOInterpreter { env in
            var head = HTTPResponseHead(version: env.header.version, status: status)
            for (key, value) in headers {
                head.headers.add(name: key, value: value)
            }
            let part = HTTPServerResponsePart.head(head)
            _ = env.ctx.channel.write(part)
            var buffer = env.ctx.channel.allocator.buffer(capacity: data.count)
            buffer.write(bytes: data)
            let bodyPart = HTTPServerResponsePart.body(.byteBuffer(buffer))
            _ = env.ctx.channel.write(bodyPart)
            _ = env.ctx.channel.writeAndFlush(HTTPServerResponsePart.end(nil)).then {
                env.ctx.channel.close()
            }
            return nil
        }
    }

    static func write(_ string: String, status: HTTPResponseStatus = .ok, headers: [String: String] = [:]) -> NIOInterpreter {
        return NIOInterpreter { env in
            var head = HTTPResponseHead(version: env.header.version, status: status)
            for (key, value) in headers {
                head.headers.add(name: key, value: value)
            }
            let part = HTTPServerResponsePart.head(head)
            _ = env.ctx.channel.write(part)
            var buffer = env.ctx.channel.allocator.buffer(capacity: string.utf8.count)
            buffer.write(string: string)
            let bodyPart = HTTPServerResponsePart.body(.byteBuffer(buffer))
            _ = env.ctx.channel.write(bodyPart)
            _ = env.ctx.channel.writeAndFlush(HTTPServerResponsePart.end(nil)).then {
                env.ctx.channel.close()
            }
            return nil
        }
    }
}

extension StringProtocol {
    var keyAndValue: (String, String)? {
        guard let i = index(of: "=") else { return nil }
        let n = index(after: i)
        return (String(self[..<i]), String(self[n...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }
}

extension String {
    fileprivate var decoded: String {
    	return (removingPercentEncoding ?? "").replacingOccurrences(of: "+", with: " ")
    }
}

extension StringProtocol {
    var parseAsQueryPart: [String:String] {
        let items = split(separator: "&").compactMap { $0.keyAndValue }
        return Dictionary(items.map { (k,v) in (k.decoded, v.decoded) }, uniquingKeysWith: { $1 })
    }
}

extension String {
    var parseQuery: (String, [String:String]) {
        guard let i = self.index(of: "?") else { return (self, [:]) }
        let path = self[..<i]
        let remainder = self[index(after: i)...]
        return (String(path), remainder.parseAsQueryPart)
    }
}

extension HTTPMethod {
    init?(_ value: NIOHTTP1.HTTPMethod) {
        switch value {
        case .GET: self = .get
        case .POST: self = .post
        default: return nil
        }
    }
}



final class RouteHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let handle: (Request) -> NIOInterpreter?
    let paths: [URL]
    var postCont: (NIOInterpreter.PostContinuation, HTTPRequestHead)? = nil
    var accumData = Data()
    
    let fileIO: NonBlockingFileIO
    init(_ fileIO: NonBlockingFileIO, resourcePaths: [URL], handle: @escaping (Request) -> NIOInterpreter?) {
        self.fileIO = fileIO
        self.handle = handle
        self.paths = resourcePaths
    }
    
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)
        switch reqPart {
        case .head(let header):
            accumData = Data()
            let (path, query) = header.uri.parseQuery
            let cookies = header.headers["Cookie"].first.map {
                $0.split(separator: ";").compactMap { $0.trimmingCharacters(in: .whitespaces).keyAndValue }
            } ?? []
            let env = NIOInterpreter.Deps(header: header, ctx: ctx, fileIO: fileIO, handler: self, manager: FileManager.default, resourcePaths: paths)

            func notFound() {
                log(info: "Not found: \(header.uri), method: \(header.method)")
                _ = NIOInterpreter.write("Not found: \(header.uri)", status: .notFound).run(env)
            }
            
            guard let method = HTTPMethod(header.method) else { notFound(); return }
            let r = Request(path: path.split(separator: "/").map(String.init), query: query, method: method, cookies: cookies)
            if let i = handle(r) {
                if let c = i.run(env) {
                    postCont = (c, header)
                }
            } else {
                notFound()
            }

        case .body(var b):
            guard postCont != nil else { return }
            if let d = b.readData(length: b.readableBytes) {
                accumData.append(d)
            }
        case .end:
            if let (p, header) = postCont {
                let env = NIOInterpreter.Deps(header: header, ctx: ctx, fileIO: fileIO, handler: self, manager: FileManager.default, resourcePaths: paths)
                let result = p(accumData).run(env)
                accumData = Data()
                assert(result == nil, "Can't read post data twice")
            }
        }
    }
}



struct Server {
    let threadPool: BlockingIOThreadPool = {
        let t = BlockingIOThreadPool(numberOfThreads: 1)
        t.start()
        return t
    }()
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private let fileIO: NonBlockingFileIO
    private let handle: (Request) -> NIOInterpreter?
    private let paths: [URL]

    init(handle: @escaping (Request) -> NIOInterpreter?, resourcePaths: [URL]) {
        fileIO = NonBlockingFileIO(threadPool: threadPool)
        self.handle = handle
        paths = resourcePaths
    }
    
    func execute(_ f: @escaping () -> ()) {
        group.next().execute(f)
    }
    
    func listen(port: Int = 8765) throws {
        let reuseAddr = ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET),
                                              SO_REUSEADDR)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(reuseAddr, value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).then { _ in
                    channel.pipeline.add(handler: RouteHandler(self.fileIO, resourcePaths: self.paths, handle: self.handle))
                }
            }
            .childChannelOption(ChannelOptions.socket(
                IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(reuseAddr, value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead,
                                value: 1)
        log(info: "Going to start listening on port \(port)")
        let channel = try bootstrap.bind(host: "0.0.0.0", port: port).wait()
        try channel.closeFuture.wait()
    }
}
