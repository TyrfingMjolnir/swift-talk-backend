//
//  SwiftTalkInterpreter.swift
//  Bits
//
//  Created by Chris Eidhof on 13.12.18.
//

import Foundation
import Promise
import NIOWrapper
import HTML
import Database
import Base


struct Reader<Value, Result> {
    let run: (Value) -> Result
    
    init(_ run: @escaping (Value) -> Result) {
        self.run = run
    }
    
    static func const(_ value: Result) -> Reader {
        return Reader { _ in value }
    }
}

extension Reader: Interpreter where Result: Interpreter {
    typealias I = Result
    static func write(_ string: String, status: HTTPResponseStatus, headers: [String : String]) -> Reader<Value, Result> {
        return Reader.const(I.write(string, status: status, headers: headers))
    }
    
    static func write(_ data: Data, status: HTTPResponseStatus, headers: [String : String]) -> Reader<Value, Result> {
        return Reader.const(I.write(data, status: status, headers: headers))
    }
    
    static func writeFile(path: String, maxAge: UInt64?) -> Reader<Value, Result> {
        return Reader.const(I.writeFile(path: path, maxAge: maxAge))
    }
    
    static func redirect(path: String, headers: [String : String]) -> Reader<Value, Result> {
        return Reader.const(I.redirect(path: path, headers: headers))
    }
    
    static func onComplete<A>(promise: Promise<A>, do cont: @escaping (A) -> Reader<Value, Result>) -> Reader<Value, Result> {
        return Reader { value in I.onComplete(promise: promise, do: { x in
            cont(x).run(value)
        })}
    }
    
    static func withPostData(do cont: @escaping (Data) -> Reader<Value, Result>) -> Reader<Value, Result> {
        return Reader { value in I.withPostData(do: { cont($0).run(value) }) }
    }
}

protocol ContainsRoute {
    associatedtype R: RouteP
}

extension RequestEnvironment: ContainsRoute {}

extension Reader: SwiftTalkInterpreter where Value: ContainsRoute, Result: Interpreter {}

protocol HasSession {
    associatedtype S
    static func withSession(_ cont: @escaping (S?) -> Self) -> Self
}

protocol HasDatabase {
    static func execute<A>(_ query: Query<A>, _ cont: @escaping (Either<A, Error>) -> Self) -> Self
}

protocol CanQuery {
    func execute<A>(_ query: Query<A>) -> Either<A, Error>
    @available(*, deprecated) func getConnection() -> Either<ConnectionProtocol, Error>

}

extension RequestEnvironment: CanQuery {
    func execute<A>(_ query: Query<A>) -> Either<A, Error> {
        do {
            return try .left(connection().execute(query))
        } catch {
            return .right(error)
        }
    }
    
    func getConnection() -> Either<ConnectionProtocol, Error> {
        do { return try .left(connection()) }
        catch { return .right(error) }
    }
}

extension Reader: HasDatabase where Value: CanQuery {
    static func execute<A>(_ query: Query<A>, _ cont: @escaping (Either<A, Error>) -> Reader<Value, Result>) -> Reader<Value, Result> {
        return Reader { env in
            return cont(env.execute(query)).run(env)
        }
    }
}

protocol HasErrorPage {
    static func renderError(_ error: Error) -> Self
}

extension SwiftTalkInterpreter where Self: HasErrorPage {
    static func catchAndDisplayError(line: UInt = #line, file: StaticString = #file, _ f: () throws -> Self) -> Self {
        do {
            return try f()
        } catch {
            log(file: file, line: line, error)
            return .renderError(error)
        }
    }
}

extension SwiftTalkInterpreter where Self: HTML, Self: HasDatabase, Self: HasErrorPage {
    static func query<A>(_ query: Query<A>, _ cont: @escaping (A) throws -> Self) -> Self {
        return Self.execute(query) { (result: Either<A, Error>) in
            catchAndDisplayError {
                switch result {
                case let .left(value): return try cont(value)
                case let .right(err): throw err
                }
            }
        }
    }
    
    static func queryWithError<A>(_ query: Query<A>, _ cont: @escaping (Either<A, Error>) throws -> Self) -> Self {
        return Self.execute(query) { (result: Either<A, Error>) in
            catchAndDisplayError {
                return try cont(result)
            }
        }

    }

    static func query<A>(_ q: Query<A>?, or: @autoclosure () -> A, _ cont: @escaping (A) -> Self) -> Self {
        if let x = q {
            return query(x, cont)
        } else {
            return cont(or())
        }
    }
}

extension SwiftTalkInterpreter where Self: HasSession, Self: HTML, Self: HasErrorPage {
    static func requireSession(_ cont: @escaping (S) throws -> Self) -> Self {
        return withSession { sess in
            catchAndDisplayError {
                try cont(sess ?! AuthorizationError())
            }
        }
    }
}

protocol ContainsSession {
    associatedtype S: SessionP
    var session: S? { get }
}

extension RequestEnvironment: ContainsSession {}

extension Reader: HasSession where Value: ContainsSession {
    typealias S = Value.S
    static func withSession(_ cont: @escaping (S?) -> Reader<Value, Result>) -> Reader<Value, Result> {
        return Reader { value in
            cont(value.session).run(value)
        }
    }
}

extension SwiftTalkInterpreter where Self: HTML, Self: HasSession, Self: HasErrorPage {
    static func withSession(_ cont: @escaping (S?) throws -> Self) -> Self {
        return withSession { sess in
            catchAndDisplayError { try cont(sess) }
        }
    }
}

protocol HTML {
    associatedtype R: RouteP
    associatedtype S: SessionP
    typealias RE = RequestEnvironment<R, S>
    static func write(_ html: ANode<RE>, status: HTTPResponseStatus) -> Self
    static func withCSRF(_ cont: @escaping (CSRFToken) -> Self) -> Self
}

extension HTML {
    static func write(_ html: ANode<RE>) -> Self {
        return self.write(html, status: .ok)
    }
}

protocol ContainsRequestEnvironment {
    associatedtype R: RouteP
    associatedtype S: SessionP
    var requestEnvironment: RequestEnvironment<R, S> { get }
}

extension RequestEnvironment: ContainsRequestEnvironment {
    var requestEnvironment: RequestEnvironment { return self }
}

extension Reader: HTML where Result: SwiftTalkInterpreter, Value: ContainsRequestEnvironment {
    typealias R = Value.R
    
    static func write(_ html: ANode<RE>, status: HTTPResponseStatus) -> Reader {
        return Reader { value in
            return .write(html: html.ast(input: value.requestEnvironment), status: status)
        }
    }

    static func withCSRF(_ cont: @escaping (CSRFToken) -> Reader) -> Reader {
        return Reader { (value: Value) in
            return cont(value.requestEnvironment.context.csrf).run(value)
        }
    }
}

extension Reader where Value == STRequestEnvironment, Result == NIOInterpreter {
    static func write(_ html: Node, status: HTTPResponseStatus) -> Reader {
        return Reader { (value: Value) -> Result in
            return NIOInterpreter.write(html.htmlDocument(input: value.requestEnvironment), status: status)
        }
    }
}


protocol RouteP {
    var path: String { get }
}

protocol SwiftTalkInterpreter: Interpreter {
    associatedtype R: RouteP
    static func writeFile(path: String) -> Self
    static func notFound(_ string: String) -> Self
    static func write(_ string: String, status: HTTPResponseStatus) -> Self
    static func write(rss: ANode<()>, status: HTTPResponseStatus) -> Self
    static func write(html: ANode<()>, status: HTTPResponseStatus) -> Self
    static func write(json: Data, status: HTTPResponseStatus) -> Self
    static func redirect(to route: R, headers: [String: String]) -> Self
}


extension SwiftTalkInterpreter {
    static func writeFile(path: String) -> Self {
        return .writeFile(path: path, maxAge: 60)
    }
    
    static func notFound(_ string: String = "Not found") -> Self {
        return .write(string, status: .notFound)
    }
    
    static func write(_ string: String, status: HTTPResponseStatus = .ok) -> Self {
        return .write(string, status: status, headers: [:])
    }
    
    static func write(rss: ANode<()>, status: HTTPResponseStatus = .ok) -> Self {
        return .write(rss.xmlDocument, status: status, headers: ["Content-Type": "application/rss+xml; charset=utf-8"])
    }
    
    static func write(html: ANode<()>, status: HTTPResponseStatus = .ok) -> Self {
        return .write(html.htmlDocument(input: ()), status: status, headers: ["Content-Type": "text/html; charset=utf-8"])
    }
    
    static func write(json: Data, status: HTTPResponseStatus = .ok) -> Self {
        return .write(json, status: status, headers: ["Content-Type": "application/json"])
    }
    
    static func redirect(to route: R, headers: [String: String] = [:]) -> Self {
        return .redirect(path: route.path, headers: headers)
    }
}

extension SwiftTalkInterpreter where Self: HTML, Self: HasErrorPage {
    static func onSuccess<A>(promise: Promise<A?>, file: StaticString = #file, line: UInt = #line, message: String = "Something went wrong.", do cont: @escaping (A) throws -> Self) -> Self {
        return onSuccess(promise: promise, file: file, line: line, do: cont, else: {
            throw ServerError(privateMessage: "Expected non-nil value, but got nil (\(file):\(line)).", publicMessage: message)
        })
    }
    
    static func onSuccess<A>(promise: Promise<A?>, file: StaticString = #file, line: UInt = #line, do cont: @escaping (A) throws -> Self, else: @escaping () throws -> Self) -> Self {
        return onComplete(promise: promise, do: { value in
            catchAndDisplayError {
                if let v = value {
                    return try cont(v)
                } else {
                    return try `else`()
                }
            }
        })
    }
    
    static func verifiedPost(do cont: @escaping ([String:String]) throws -> Self) -> Self {
        return verifiedPost(do: cont, or: {
            throw ServerError(privateMessage: "Expected POST", publicMessage: "Something went wrong.")
        })
    }
    static func verifiedPost(do cont: @escaping ([String:String]) throws -> Self, or: @escaping () throws -> Self) -> Self {
        return .withPostData { data in
        	if !data.isEmpty, let body = String(data: data, encoding: .utf8)?.parseAsQueryPart {
                return withCSRF { csrf in
                    catchAndDisplayError {
                        guard body["csrf"] == csrf.stringValue else {
                            throw ServerError(privateMessage: "CSRF failure", publicMessage: "Something went wrong.")
                        }
                        return try cont(body)
                    }
                }
        	} else {
            	return catchAndDisplayError(or)
        	}
        }
    }

    static func onCompleteOrCatch<A>(promise: Promise<A>, do cont: @escaping (A) throws -> Self) -> Self {
        return onComplete(promise: promise, do: { value in
            catchAndDisplayError { try cont(value) }
        })
    }

    // Renders a form. If it's POST, we try to parse the result and call the `onPost` handler, otherwise (a GET) we render the form.
    static func form<A,B>(_ f: Form<A, RE>, initial: A, convert: @escaping (A) -> Either<B, [ValidationError]>, onPost: @escaping (B) throws -> Self) -> Self {
        return verifiedPost(do: { (body: [String:String]) -> Self in
            withCSRF { csrf in
            	catchAndDisplayError {
                    guard let result = f.parse(body) else { throw ServerError(privateMessage: "Couldn't parse form", publicMessage: "Something went wrong. Please try again.") }
                    switch convert(result) {
                    case let .left(value):
                        return try onPost(value)
                    case let .right(errs):
                        return .write(f.render(result, errs))
                    }
        		}
            }
        }, or: {
            return .write(f.render(initial, []))
        })
        
    }
    
    static func form<A>(_ f: Form<A, RE>, initial: A, validate: @escaping (A) -> [ValidationError], onPost: @escaping (A) throws -> Self) -> Self {
        return form(f, initial: initial, convert: { (a: A) -> Either<A, [ValidationError]> in
            let errs = validate(a)
            return errs.isEmpty ? .left(a) : .right(errs)
        }, onPost: onPost)
    }
}
