// Copyright 2022-2025 The Connect Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

@testable import Connect
import Foundation
import SwiftProtobuf
import Testing

struct UnaryQueryTests {
    // MARK: - Request construction

    @Test
    func queryIsDisabledByDefault() async {
        let httpClient = RecordingHTTPClient()
        let client = self.createClient(httpClient: httpClient)
        _ = await client.idempotentUnary(request: self.idempotentRequest())
        #expect(httpClient.requests.map(\.method) == [.post])
    }

    @Test
    func eligibleUnaryRequestUsesQueryWithSameHeadersAndBodyAsPOST() async throws {
        let postClient = RecordingHTTPClient()
        _ = await self.createClient(httpClient: postClient)
            .idempotentUnary(request: self.idempotentRequest())
        let queryClient = RecordingHTTPClient()
        let response = await self.createClient(httpClient: queryClient, unaryQuery: .enabled)
            .idempotentUnary(request: self.idempotentRequest())

        let post = try #require(postClient.requests.first)
        let query = try #require(queryClient.requests.first)
        #expect(response.error == nil)
        #expect(query.method == .query)
        #expect(query.method.rawValue == "QUERY")
        #expect(query.url == post.url)
        #expect(query.url.query == nil)
        #expect(query.headers == post.headers)
        #expect(query.headers[HeaderConstants.contentType] == ["application/json"])
        #expect(query.message == post.message)
        #expect(query.message?.isEmpty == false)
    }

    @Test
    func ineligibleUnaryRequestsStillUsePOST() async {
        let httpClient = RecordingHTTPClient()
        let client = self.createClient(httpClient: httpClient, unaryQuery: .enabled)
        _ = await client.unary(request: .init())
        #expect(httpClient.requests.map(\.method) == [.post])
    }

    @Test
    func streamingRequestsStillUsePOST() {
        let httpClient = RecordingHTTPClient()
        let client = self.createClient(httpClient: httpClient, unaryQuery: .enabled)
        _ = client.serverStream { _ in }
        #expect(httpClient.streamRequests.map(\.method) == [.post])
    }

    @Test
    func grpcWebIgnoresQuery() async {
        let httpClient = RecordingHTTPClient()
        let client = self.createClient(
            httpClient: httpClient, networkProtocol: .grpcWeb, unaryQuery: .enabled
        )
        _ = await client.idempotentUnary(request: self.idempotentRequest())
        #expect(httpClient.requests.map(\.method) == [.post])
    }

    @Test
    func requestCompressionAppliesToQuery() async throws {
        let httpClient = RecordingHTTPClient()
        let client = self.createClient(
            httpClient: httpClient,
            unaryQuery: .enabled,
            requestCompression: .init(minBytes: 1, pool: GzipCompressionPool())
        )
        _ = await client.idempotentUnary(request: self.idempotentRequest())

        let request = try #require(httpClient.requests.first)
        #expect(request.method == .query)
        #expect(request.headers[HeaderConstants.contentEncoding] == ["gzip"])
        let body = try #require(request.message)
        let decompressed = try GzipCompressionPool().decompress(data: body)
        #expect(decompressed == (try JSONCodec().serialize(message: self.idempotentRequest())))
    }

    // MARK: - Interaction with GET

    @Test
    func getTakesPrecedenceWhenRequestFitsSizeLimit() async {
        let httpClient = RecordingHTTPClient()
        let client = self.createClient(
            httpClient: httpClient,
            unaryGET: .enabledForLimitedPayloadSizes(maxBytes: 10_000),
            unaryQuery: .enabled
        )
        _ = await client.idempotentUnary(request: self.idempotentRequest())
        #expect(httpClient.requests.map(\.method) == [.get])
    }

    @Test
    func queryReplacesPOSTFallbackWhenRequestExceedsGETSizeLimit() async throws {
        let httpClient = RecordingHTTPClient()
        let client = self.createClient(
            httpClient: httpClient,
            unaryGET: .enabledForLimitedPayloadSizes(maxBytes: 1),
            unaryQuery: .enabled
        )
        _ = await client.idempotentUnary(request: self.idempotentRequest())
        let request = try #require(httpClient.requests.first)
        #expect(request.method == .query)
        #expect(request.url.query == nil)
        #expect(request.message?.isEmpty == false)
    }

    @Test
    func postFallbackRemainsWhenQueryIsDisabled() async {
        let httpClient = RecordingHTTPClient()
        let client = self.createClient(
            httpClient: httpClient, unaryGET: .enabledForLimitedPayloadSizes(maxBytes: 1)
        )
        _ = await client.idempotentUnary(request: self.idempotentRequest())
        #expect(httpClient.requests.map(\.method) == [.post])
    }

    // MARK: - Errors

    @Test
    func methodNotAllowedSurfacesAsErrorWithoutRetryingAsPOST() async {
        let httpClient = RecordingHTTPClient(responseCode: .unimplemented)
        let client = self.createClient(httpClient: httpClient, unaryQuery: .enabled)
        let response = await client.idempotentUnary(request: self.idempotentRequest())
        #expect(response.error?.code == .unimplemented)
        #expect(httpClient.requests.map(\.method) == [.query])
    }

    // MARK: - Config helpers

    @Test
    func shouldUseUnaryQueryOnlyForConnectRequestsWithNoSideEffects() {
        func request(_ level: IdempotencyLevel) -> HTTPRequest<Data?> {
            return HTTPRequest(
                url: URL(string: "https://connectrpc.com")!,
                headers: Headers(),
                message: Data([0x0, 0x1, 0x2]),
                method: .post,
                trailers: nil,
                idempotencyLevel: level
            )
        }
        let enabled = ProtocolClientConfig(host: "https://connectrpc.com", unaryQuery: .enabled)
        let disabled = ProtocolClientConfig(host: "https://connectrpc.com")
        let grpcWeb = ProtocolClientConfig(
            host: "https://connectrpc.com", networkProtocol: .grpcWeb, unaryQuery: .enabled
        )
        #expect(enabled.shouldUseUnaryQuery(for: request(.noSideEffects)))
        #expect(enabled.shouldUseUnaryQuery(for: request(.idempotent)) == false)
        #expect(enabled.shouldUseUnaryQuery(for: request(.unknown)) == false)
        #expect(disabled.shouldUseUnaryQuery(for: request(.noSideEffects)) == false)
        #expect(grpcWeb.shouldUseUnaryQuery(for: request(.noSideEffects)) == false)
    }

    @Test
    func transformToQueryOnlyChangesTheMethod() {
        let request = HTTPRequest<Data?>(
            url: URL(string: "https://connectrpc.com/path")!,
            headers: [HeaderConstants.contentType: ["application/json"]],
            message: Data(),
            method: .post,
            trailers: nil,
            idempotencyLevel: .noSideEffects
        )
        let transformed = ProtocolClientConfig(
            host: "https://connectrpc.com", unaryQuery: .enabled
        ).transformToQUERYIfNeeded(request)
        #expect(transformed.method == .query)
        #expect(transformed.url == request.url)
        #expect(transformed.headers == request.headers)
        #expect(transformed.message == Data())
    }

    // MARK: - Helpers

    private func idempotentRequest() -> Connectrpc_Conformance_V1_IdempotentUnaryRequest {
        return .with { request in
            request.responseDefinition = .with { response in
                response.responseData = Data([0x1, 0x2, 0x3])
            }
        }
    }

    private func createClient(
        httpClient: RecordingHTTPClient,
        networkProtocol: NetworkProtocol = .connect,
        unaryGET: ProtocolClientConfig.UnaryGET = .disabled,
        unaryQuery: ProtocolClientConfig.UnaryQuery = .disabled,
        requestCompression: ProtocolClientConfig.RequestCompression? = nil
    ) -> Connectrpc_Conformance_V1_ConformanceServiceClient {
        let config = ProtocolClientConfig(
            host: "https://connectrpc.com",
            networkProtocol: networkProtocol,
            unaryGET: unaryGET,
            unaryQuery: unaryQuery,
            requestCompression: requestCompression
        )
        return Connectrpc_Conformance_V1_ConformanceServiceClient(
            client: ProtocolClient(httpClient: httpClient, config: config)
        )
    }
}

private final class RecordingHTTPClient: HTTPClientInterface, @unchecked Sendable {
    private let recordedRequests = Locked([HTTPRequest<Data?>]())
    private let recordedStreamRequests = Locked([HTTPRequest<Data?>]())
    private let responseCode: Code

    var requests: [HTTPRequest<Data?>] { return self.recordedRequests.value }
    var streamRequests: [HTTPRequest<Data?>] { return self.recordedStreamRequests.value }

    init(responseCode: Code = .ok) {
        self.responseCode = responseCode
    }

    @discardableResult
    func unary(
        request: HTTPRequest<Data?>,
        onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
        onResponse: @escaping @Sendable (HTTPResponse) -> Void
    ) -> Cancelable {
        self.recordedRequests.perform { $0.append(request) }
        let isSuccess = self.responseCode == .ok
        onResponse(HTTPResponse(
            code: self.responseCode,
            headers: [HeaderConstants.contentType: [
                isSuccess ? "application/json" : "text/plain",
            ]],
            message: isSuccess ? Data("{}".utf8) : nil,
            trailers: [:],
            error: nil,
            tracingInfo: nil
        ))
        return Cancelable {}
    }

    func stream(
        request: HTTPRequest<Data?>,
        responseCallbacks: ResponseCallbacks
    ) -> RequestCallbacks<Data> {
        self.recordedStreamRequests.perform { $0.append(request) }
        return RequestCallbacks(cancel: {}, sendData: { _ in }, sendClose: {})
    }
}
