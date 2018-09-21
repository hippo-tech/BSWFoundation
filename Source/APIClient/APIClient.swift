//
//  Created by Pierluigi Cifani on 02/03/2018.
//  Copyright © 2018 TheLeftBit. All rights reserved.
//

import Foundation
import Deferred

public protocol APIClientNetworkFetcher {
    func fetchData(with urlRequest: URLRequest) -> Task<APIClient.Response>
    func uploadFile(with urlRequest: URLRequest, fileURL: URL) -> Task<APIClient.Response>
}

public protocol APIClientDelegate: class {
    func apiClientDidReceiveUnauthorized(forRequest at: URL, apiClient: APIClient)
}

open class APIClient {

    var delegateQueue = DispatchQueue.main
    public weak var delegate: APIClientDelegate?
    private var router: Router
    private let workerQueue: OperationQueue
    private let workerGCDQueue = DispatchQueue(label: "\(ModuleName).APIClient", qos: .userInitiated)
    private let fileManagerQueue = DispatchQueue(label: "\(ModuleName).APIClient.filemanager")
    private let fileManager = FileManager.default
    private let networkFetcher: APIClientNetworkFetcher

    public static func backgroundClient(environment: Environment, signature: Signature? = nil) -> APIClient {
        let session = URLSession(configuration: .background(withIdentifier: "\(Bundle.main.displayName)-APIClient"))
        return APIClient(environment: environment, signature: signature, networkFetcher: session)
    }

    public init(environment: Environment, signature: Signature? = nil, networkFetcher: APIClientNetworkFetcher? = nil) {
        let queue = queueForSubmodule("APIClient")
        queue.underlyingQueue = workerGCDQueue
        self.router = Router(environment: environment, signature: signature)
        self.networkFetcher = networkFetcher ?? URLSession(configuration: .default, delegate: nil, delegateQueue: queue)
        self.workerQueue = queue
    }

    public func performSimpleRequest<T: Decodable>(_ request: Request<T>) -> Task<APIClient.Response> {
        return createURLRequest(endpoint: request.endpoint)
                ≈> networkFetcher.fetchData
    }
    
    public func perform<T: Decodable>(_ request: Request<T>) -> Task<T> {
        return createURLRequest(endpoint: request.endpoint)
                ≈> networkFetcher.fetchData
                ≈> validateResponse
                ≈> parseResponse
    }

    public func performMultipartUpload<T: Decodable>(_ request: Request<T>, parameters: [MultipartParameter]) -> Task<T> {
        let createURLTask = createURLRequest(endpoint: request.endpoint)
        let multipartTask = createURLTask.andThen(upon: workerGCDQueue) {
            return self.prepareMultipartRequest(urlRequest: $0, multipartParameters: parameters)
        }
        let uploadTask = multipartTask.andThen(upon: workerGCDQueue) {
            return self.networkFetcher.uploadFile(with: $0.0, fileURL: $0.1)
        }
        let validateTask: Task<Data> = uploadTask.andThen(upon: workerGCDQueue) {
            return self.validateResponse(response: $0)
        }
        let parseTask: Task<T> = validateTask.andThen(upon: workerGCDQueue) {
            return self.parseResponse(data: $0)
        }

        uploadTask.upon(workerGCDQueue) { _  in
            guard let fileURL = multipartTask.peek()?.value?.1 else {
                return
            }

            self.deleteFileAtPath(fileURL: fileURL)
        }

        return parseTask
    }

    public func addTokenSignature(token: String) {
        self.addSignature(Signature(name: "Authorization", value: "Bearer \(token)"))
    }
    
    public func addSignature(_ signature: Signature) {
        self.router = Router(
            environment: router.environment,
            signature: signature
        )
    }

    public func removeTokenSignature() {
        self.router = Router(
            environment: router.environment,
            signature: nil
        )
    }
    
    public var currentEnvironment: Environment {
        return self.router.environment
    }
}

extension APIClient {

    public enum Error: Swift.Error {
        case serverError
        case malformedURL
        case malformedParameters
        case malformedResponse
        case encodingRequestFailed
        case multipartEncodingFailed(reason: MultipartFormFailureReason)
        case malformedJSONResponse(Swift.Error)
        case failureStatusCode(Int, Data?)
        case unknownError
    }

    public struct Signature {
        let name: String
        let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }
    
    public struct Response {
        public let data: Data
        public let httpResponse: HTTPURLResponse
        
        public init(data: Data, httpResponse: HTTPURLResponse) {
            self.data = data
            self.httpResponse = httpResponse
        }
    }
}

// MARK: Private

private extension APIClient {

    func validateResponse(response: Response) -> Task<Data> {
        switch response.httpResponse.statusCode {
        case (200..<300):
            return Task(success: response.data)
        default:
            if response.httpResponse.statusCode == 401, let url = response.httpResponse.url {
                dispatchToMainQueueSyncIfPossible {
                    self.delegate?.apiClientDidReceiveUnauthorized(forRequest: url, apiClient: self)
                }
            }
            let apiError = APIClient.Error.failureStatusCode(response.httpResponse.statusCode, response.data)
            return Task(failure: apiError)
        }
    }

    func parseResponse<T: Decodable>(data: Data) -> Task<T> {
        return JSONParser.parseData(data)
    }

    func createURLRequest(endpoint: Endpoint) -> Task<URLRequest> {
        let deferred = Deferred<Task<URLRequest>.Result>()
        let workItem = DispatchWorkItem {
            do {
                let request: URLRequest = try self.router.urlRequest(forEndpoint: endpoint)
                deferred.fill(with: .success(request))
            } catch let error {
                deferred.fill(with: .failure(error))
            }
        }
        workerGCDQueue.async(execute: workItem)
        return Task(deferred, cancellation: { [weak workItem] in
            workItem?.cancel()
        })
    }

    func prepareMultipartRequest(urlRequest: URLRequest, multipartParameters: [MultipartParameter]) -> Task<(URLRequest, URL)> {
        let deferred = Deferred<Task<(URLRequest, URL)>.Result>()
        let workItem = DispatchWorkItem {
            let form = MultipartFormData()
            multipartParameters.forEach { param in
                switch param.parameterValue {
                case .url(let url):
                    form.append(
                        url,
                        withName: param.parameterKey,
                        fileName: param.fileName,
                        mimeType: param.mimeType.rawType
                    )
                case .data(let data):
                    form.append(
                        data,
                        withName: param.parameterKey,
                        fileName: param.fileName,
                        mimeType: param.mimeType.rawType
                    )
                }
            }

            let tempDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            let directoryURL = tempDirectoryURL.appendingPathComponent("com.BSWFoundation.APIClient/multipart.form.data")
            let fileURL = directoryURL.appendingPathComponent(UUID().uuidString)

            // Create directory inside serial queue to ensure two threads don't do this in parallel
            var fileManagerError: Swift.Error?
            self.fileManagerQueue.sync {
                do {
                    try self.fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
                    try form.writeEncodedData(to: fileURL)

                } catch {
                    fileManagerError = error
                }
            }

            if let fileManagerError = fileManagerError {
                deferred.fail(with: fileManagerError)
            } else {
                var urlRequestWithContentType = urlRequest
                urlRequestWithContentType.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
                deferred.succeed(with: (urlRequestWithContentType, fileURL))
            }
        }
        workerGCDQueue.async(execute: workItem)
        return Task(deferred, cancellation: { [weak workItem] in
            workItem?.cancel()
        })
    }

    @discardableResult
    func deleteFileAtPath(fileURL: URL) -> Task<()> {
        let deferred = Deferred<Task<()>.Result>()
        self.fileManagerQueue.sync {
            do {
                try self.fileManager.removeItem(at: fileURL)
                deferred.succeed(with: ())
            } catch let error {
                deferred.fail(with: error)
            }
        }
        return Task(deferred)
    }
}

extension URLSession: APIClientNetworkFetcher {
    public func fetchData(with urlRequest: URLRequest) -> Task<APIClient.Response> {
        let deferred = Deferred<Task<APIClient.Response>.Result>()
        let task = self.dataTask(with: urlRequest) { (data, response, error) in
            self.analyzeResponse(deferred: deferred, data: data, response: response, error: error)
        }
        task.resume()
        if #available(iOS 11.0, tvOS 11.0, watchOS 4.0, macOS 10.13, *) {
            return Task(deferred, progress: task.progress)
        } else {
            return Task(deferred, cancellation: { [weak task] in
                task?.cancel()
            })
        }
    }

    public func uploadFile(with urlRequest: URLRequest, fileURL: URL) -> Task<APIClient.Response> {
        let deferred = Deferred<Task<APIClient.Response>.Result>()
        let task = self.uploadTask(with: urlRequest, fromFile: fileURL) { (data, response, error) in
            self.analyzeResponse(deferred: deferred, data: data, response: response, error: error)
        }
        task.resume()
        if #available(iOS 11.0, tvOS 11.0, watchOS 4.0, macOS 10.13, *) {
            return Task(deferred, progress: task.progress)
        } else {
            return Task(deferred, cancellation: { [weak task] in
                task?.cancel()
            })
        }
    }

    private func analyzeResponse(deferred: Deferred<Task<APIClient.Response>.Result>, data: Data?, response: URLResponse?, error: Error?) {
        guard error == nil else {
            deferred.fill(with: .failure(error!))
            return
        }

        guard let httpResponse = response as? HTTPURLResponse,
            let data = data else {
                deferred.fill(with: .failure(APIClient.Error.malformedResponse))
                return
        }

        deferred.fill(with: .success(APIClient.Response.init(data: data, httpResponse: httpResponse)))
    }
}

public typealias HTTPHeaders = [String: String]
public struct VoidResponse: Decodable {}

private func dispatchToMainQueueSyncIfPossible(_ handler: @escaping VoidHandler) {
    if Thread.current.isMainThread {
        DispatchQueue.main.async {
            handler()
        }
    } else {
        DispatchQueue.main.sync {
            handler()
        }
    }
}
