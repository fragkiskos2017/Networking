import Foundation

// MARK: - Config

struct Config {
    static let APIKey = ""
    static let locale = ""
    static let baseURL = URL(string: "https://telenor.dk")!
}

// MARK: - Core components

/// HTTP method definitions
/// The rest of the methods defined in https://tools.ietf.org/html/rfc7231#section-4.3 can be added on demand
enum Method: String {
    case GET, POST, PUT
}

/// HTTP request headers
typealias Headers = [String: String]

/// Represents universal result
enum Result<T> {
    case success(T)
    case failure(Error)
}

/// Request model
class Request {
    let url: URL
    let method: Method
    let parameters: [String: Any]?
    let headers: Headers?
    private(set) var validations: [Validation]

    init(url: URL, method: Method, parameters: [String: Any]? = nil, headers: Headers?, validations: [Validation] = []) {
        self.url = url
        self.method = method
        self.parameters = parameters
        self.headers = headers
        self.validations = validations
    }
}

// MARK: - Validation

extension Request {
    typealias Validation = (_ response: HTTPURLResponse) throws -> Void

    enum ValidationError: Error {
        case unacceptableStatusCode(Int)
    }

    func validate<S: Sequence>(statusCode acceptableStatusCodes: S) -> Request where S.Iterator.Element == Int {
        let validation: Validation = { response in
            if !acceptableStatusCodes.contains(response.statusCode) {
                throw ValidationError.unacceptableStatusCode(response.statusCode)
            }
        }
        validations.append(validation)
        return self
    }
}

// MARK: - URL Request

extension Request {

    var asURLRequest: URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.allHTTPHeaderFields = headers
        if let parameters = parameters, let body = try? JSONSerialization.data(withJSONObject: parameters) {
            request.httpBody = body
        }
        return request
    }
}

// MARK: - Default Headers

extension Dictionary where Key == String, Value == String {
    static var `default`: Headers {
        return ["Content-Type": "application/json", "apikey": Config.APIKey, "locale": Config.locale]
    }
}

// MARK: - Networking

protocol NetworkingType {
    func sendRequest(_ request: Request, completion: @escaping (Result<Data?>) -> Void)
}

final class Networking: NetworkingType {
    private let session: URLSession
    private let plugins: [Plugin]

    init(session: URLSession = .shared, plugins: [Plugin] = []) {
        self.session = session
        self.plugins = plugins
    }

    func sendRequest(_ request: Request, completion: @escaping (Result<Data?>) -> Void) {
        let urlRequest = request.asURLRequest
        plugins.forEach { $0.willSend(urlRequest) }

        let task = session.dataTask(with: urlRequest) { [plugins] data, response, error in
            plugins.forEach { $0.didReceive(data: data, response: response, error: error) }

            if let response = response as? HTTPURLResponse {
                do {
                    try request.validations.forEach { try $0(response) }
                } catch {
                    completion(.failure(error))
                }
            }
            completion(.success(data))
        }
        task.resume()
    }
}

final class DemoNetworking: NetworkingType {
    func sendRequest(_ request: Request, completion: @escaping (Result<Data?>) -> Void) {
        // load demo JSON and complete
    }
}

// MARK: - Networking Plugins

protocol Plugin {
    /// Called immediately before a request is sent over the network
    func willSend(_ request: URLRequest)

    /// Called after a response has been received, but before `Networking` has invoked its completion handler
    func didReceive(data: Data?, response: URLResponse?, error: Error?)
}

// MARK: - NetworkActivityPlugin

/// Changes network activity indicator
final class NetworkActivityPlugin: Plugin {

    func willSend(_ request: URLRequest) {
        // push indicator counter
    }

    func didReceive(data: Data?, response: URLResponse?, error: Error?) {
        // pop indicator counter
    }
}

// MARK: - NetworkLoggerPlugin

final class NetworkLoggerPlugin: Plugin {

    func willSend(_ request: URLRequest) {
        // log request
    }

    func didReceive(data: Data?, response: URLResponse?, error: Error?) {
        // log response and error
    }
}

// MARK: - Decoder

struct Decoder {
    private let decoder: JSONDecoder

    init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    func decodeAndComplete<T: Decodable>(_ type: T.Type, from data: Data?, completion: @escaping (Result<T>) -> Void) {
        if data != nil {
			do {
				let response = try JSONDecoder().decode(T.self, from: data!)
			} catch {
				completion(.failure(error))
			}
            completion(.success(response))
        } else {
            completion(.failure(Error.invalidResponse))
        }
    }

    enum Error: Swift.Error {
        case invalidResponse
    }
}

// MARK: - Concrete Request Models

/// Concrete model of 'login with phone number' request
final class PhoneNumberLoginRequest: Request {
    init(phoneNumber: String, pinCode: String) {
        let parameters = ["loginId": phoneNumber, "oneTimePassword": pinCode]
        let url = URL(string: "auth/login", relativeTo: Config.baseURL)!
        super.init(url: url, method: .POST, parameters: parameters, headers: .default)
    }
}

/// Concrete model of 'GET marketing permissions' request
final class GetMarketingPermissionRequest: Request {
    init(customerId: String) {
        let url = URL(string: "/uapi/privacy/marketing/permission", relativeTo: Config.baseURL)!
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "customerId", value: customerId)]
        super.init(url: urlComponents.url!, method: .GET, headers: .default)
    }
}

// MARK: - Singleton API example

/// Facade for all API requests
final class API {
    static let shared = API()

    private let plugins: [Plugin] = [NetworkLoggerPlugin(), NetworkActivityPlugin()]
    private lazy var networking: NetworkingType = Networking(plugins: plugins)
    private let decoder = Decoder()

    var isDemoUser: Bool = false {
        didSet {
            networking = isDemoUser ? DemoNetworking() : Networking(plugins: plugins)
        }
    }

    func login(phoneNumber: String, pinCode: String, completion: @escaping (Result<PhoneNumberLoginResponse>) -> Void) {
        let request = PhoneNumberLoginRequest(phoneNumber: phoneNumber, pinCode: pinCode).validate(statusCode: 200..<300)
        networking.sendRequest(request) { [decoder] result in
            switch result {
            case .success(let data):
                decoder.decodeAndComplete(PhoneNumberLoginResponse.self, from: data, completion: completion)

            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func getMarketingPermission(customerId: String, completion: @escaping (Result<MarketingPermissionResponse>) -> Void) {
        let request = GetMarketingPermissionRequest(customerId: customerId).validate(statusCode: 200..<300)
        networking.sendRequest(request) { [decoder] result in
            switch result {
            case .success(let data):
                decoder.decodeAndComplete(MarketingPermissionResponse.self, from: data, completion: completion)

            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}

// MARK: - Response Models

struct PhoneNumberLoginResponse: Codable {
    let token: String
    let customerId: String
}

struct MarketingPermissionResponse: Decodable {
    let consentExpressionId: Int
    let isAgreed: Bool?
    let text: Text

    struct Text: Decodable {
        let description: String
        let legal: String
        let title: String
    }
}
