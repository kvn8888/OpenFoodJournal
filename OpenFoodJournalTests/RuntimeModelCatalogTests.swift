// OpenFoodJournal — models.dev runtime metadata contract tests

import Foundation
import Testing
@testable import OpenFoodJournal

@MainActor
private final class StubModelCatalogFetcher: ModelCatalogFetching {
    var handler: (URLRequest, Int) throws -> (Data, URLResponse)
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping (URLRequest, Int) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try handler(request, requests.count)
    }
}

@MainActor
struct RuntimeModelCatalogTests {
    @Test func refreshAppliesConcreteCapabilitiesPricingAndPersistsCache() async throws {
        let cacheURL = temporaryCacheURL()
        let endpoint = URL(string: "https://models.dev/api.json")!
        let payload = Self.catalogFixture
        let fetcher = StubModelCatalogFetcher { request, _ in
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return (
                payload,
                HTTPURLResponse(
                    url: endpoint,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["ETag": "\"catalog-v1\""]
                )!
            )
        }
        let catalog = RuntimeModelCatalog(fetcher: fetcher, cacheURL: cacheURL)

        #expect(await catalog.refreshIfNeeded())
        #expect(fetcher.requests.count == 1)

        let requested = AssistantModelSelection(
            descriptor: ChatModelCatalog.descriptor(
                provider: .gemini,
                model: "gemini-flash-latest"
            ),
            endpoint: nil,
            routingMode: .automatic
        )
        let selection = catalog.selectionResolvingRuntimeMetadata(requested)
        #expect(selection.descriptor.capabilities.maximumInputTokens == 1_048_576)
        #expect(selection.descriptor.capabilities.maximumOutputTokens == 65_536)
        #expect(selection.descriptor.capabilities.supportsImages)
        #expect(selection.descriptor.capabilities.supportsPDFs)

        let concrete = catalog.resolution(
            for: requested,
            resolvedModelID: "models/gemini-3.6-flash"
        )
        #expect(concrete.resolvedModelID == "gemini-3.6-flash")
        #expect(concrete.selection.descriptor.baseModelID == "gemini-3.6-flash")
        #expect(concrete.catalogVersion == "models.dev:catalog-v1")
        let pricing = try #require(concrete.pricing)
        #expect(pricing.inputPerMillionUSD == 1.5)
        #expect(pricing.cachedInputPerMillionUSD == 0.15)
        #expect(pricing.outputPerMillionUSD == 7.5)
        #expect(
            pricing.estimatedCost(for: ChatTokenUsage(input: 1_000_000, output: 1_000_000))
                == 9
        )

        let restored = RuntimeModelCatalog(
            fetcher: StubModelCatalogFetcher { _, _ in
                throw URLError(.notConnectedToInternet)
            },
            cacheURL: cacheURL
        )
        #expect(restored.lastSuccessfulRefreshAt != nil)
        #expect(
            restored
                .selectionResolvingRuntimeMetadata(requested)
                .descriptor
                .capabilities
                .maximumInputTokens == 1_048_576
        )
    }

    @Test func freshCacheSkipsNetworkAndStaleCacheUsesConditionalRefresh() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let cacheURL = temporaryCacheURL()
        let endpoint = URL(string: "https://models.dev/api.json")!
        let fetcher = StubModelCatalogFetcher { request, call in
            if call == 1 {
                return (
                    Self.catalogFixture,
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["ETag": "\"catalog-v1\""]
                    )!
                )
            }
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"catalog-v1\"")
            return (
                Data(),
                HTTPURLResponse(
                    url: endpoint,
                    statusCode: 304,
                    httpVersion: nil,
                    headerFields: ["ETag": "\"catalog-v1\""]
                )!
            )
        }
        let catalog = RuntimeModelCatalog(
            fetcher: fetcher,
            cacheURL: cacheURL,
            now: { clock }
        )

        #expect(await catalog.refreshIfNeeded())
        #expect(await catalog.refreshIfNeeded() == false)
        #expect(fetcher.requests.count == 1)

        clock.addTimeInterval(RuntimeModelCatalog.refreshInterval + 1)
        #expect(await catalog.refreshIfNeeded())
        #expect(fetcher.requests.count == 2)
        #expect(catalog.lastSuccessfulRefreshAt == clock)
    }

    @Test func providerAliasChangeIsUsedImmediatelyAndForcesMetadataRefresh() async throws {
        let cacheURL = temporaryCacheURL()
        let endpoint = URL(string: "https://models.dev/api.json")!
        let fetcher = StubModelCatalogFetcher { request, call in
            (
                call == 1 ? Self.catalogFixture : Data(),
                HTTPURLResponse(
                    url: endpoint,
                    statusCode: call == 1 ? 200 : 304,
                    httpVersion: nil,
                    headerFields: ["ETag": "\"catalog-v1\""]
                )!
            )
        }
        let catalog = RuntimeModelCatalog(fetcher: fetcher, cacheURL: cacheURL)
        #expect(await catalog.refreshIfNeeded())
        let requested = AssistantModelSelection(
            descriptor: ChatModelCatalog.descriptor(
                provider: .gemini,
                model: "gemini-flash-latest"
            ),
            endpoint: nil,
            routingMode: .automatic
        )

        catalog.observeResolvedModel(
            provider: .gemini,
            requestedModelID: "gemini-flash-latest",
            resolvedModelID: "gemini-3.6-flash"
        )
        let resolution = catalog.resolution(for: requested, resolvedModelID: nil)
        #expect(resolution.resolvedModelID == "gemini-3.6-flash")
        #expect(resolution.pricing?.outputPerMillionUSD == 7.5)

        for _ in 0..<20 where fetcher.requests.count < 2 {
            await Task.yield()
        }
        #expect(fetcher.requests.count == 2)
    }

    @Test func unavailableCatalogKeepsShippedFallbackUsable() async {
        let catalog = RuntimeModelCatalog(
            fetcher: StubModelCatalogFetcher { _, _ in
                throw URLError(.cannotConnectToHost)
            },
            cacheURL: temporaryCacheURL()
        )
        let selection = AssistantModelSelection(
            descriptor: ChatModelCatalog.azureDescriptor(
                model: .terra,
                deployment: "user-defined-deployment"
            ),
            endpoint: URL(string: "https://sample.openai.azure.com/openai/v1"),
            routingMode: .automatic
        )

        #expect(await catalog.refreshIfNeeded() == false)
        let fallback = catalog.resolution(for: selection, resolvedModelID: nil)
        #expect(fallback.selection.descriptor.deploymentIdentifier == "user-defined-deployment")
        #expect(fallback.resolvedModelID == AzureAssistantModel.terra.rawValue)
        #expect(fallback.selection.descriptor.capabilities.maximumInputTokens == 922_000)
        #expect(fallback.pricing != nil)
    }

    @Test func assistantAccountingUsesProviderReportedConcreteModel() async throws {
        let endpoint = URL(string: "https://models.dev/api.json")!
        let catalog = RuntimeModelCatalog(
            fetcher: StubModelCatalogFetcher { _, _ in
                (
                    Self.catalogFixture,
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["ETag": "\"catalog-v1\""]
                    )!
                )
            },
            cacheURL: temporaryCacheURL()
        )
        #expect(await catalog.refreshIfNeeded())
        let harness = try ChatTestHarness(
            provider: .gemini,
            primary: "gemini-flash-latest",
            modelCatalog: catalog
        )
        harness.proxy.enqueue(ChatModelTurn(
            text: "Done.",
            usage: ChatTokenUsage(input: 1_000, output: 1_000),
            providerRequestID: "gemini-request-1",
            resolvedModelID: "gemini-3.6-flash"
        ))
        let thread = harness.makeThread()

        await harness.service.send("Use the current model.", in: thread)

        let accumulator = GeminiCostAccumulator.current(in: harness.context)
        #expect(accumulator.lastModel == "gemini-3.6-flash")
        #expect(abs(accumulator.lastEstimatedTokenCostUSD - 0.009) < 0.000_001)
        #expect(accumulator.lastPricingModel?.contains("gemini-3.6-flash") == true)
        let run = try #require(thread.agentRuns?.first)
        let round = try #require(run.roundRecords.first)
        #expect(round.baseModelID == "gemini-3.6-flash")
        #expect(round.deploymentID == "gemini-flash-latest")
        #expect(round.pricingCatalogVersion == "models.dev:catalog-v1")
        let log = try #require(
            harness.diagnostics.events.first(where: { $0.eventType == "ai_request" })
        )
        #expect(log.baseModelID == "gemini-flash-latest")
        #expect(log.deploymentID == "gemini-3.6-flash")
    }

    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ofj-model-catalog-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("cache.json")
    }

    private static let catalogFixture = #"""
    {
      "google": {
        "id": "google",
        "name": "Google",
        "models": {
          "gemini-flash-latest": {
            "id": "gemini-flash-latest",
            "name": "Gemini Flash Latest",
            "attachment": true,
            "reasoning": true,
            "tool_call": true,
            "modalities": {"input": ["text", "image", "pdf"], "output": ["text"]},
            "limit": {"context": 1048576, "output": 65536},
            "cost": {"input": 1.5, "output": 9.0, "cache_read": 0.15},
            "last_updated": "2026-05-19"
          },
          "gemini-3.6-flash": {
            "id": "gemini-3.6-flash",
            "name": "Gemini 3.6 Flash",
            "attachment": true,
            "reasoning": true,
            "tool_call": true,
            "modalities": {"input": ["text", "image", "pdf"], "output": ["text"]},
            "limit": {"context": 1048576, "output": 65536},
            "cost": {"input": 1.5, "output": 7.5, "cache_read": 0.15},
            "last_updated": "2026-07-21"
          }
        }
      },
      "azure": {
        "id": "azure",
        "name": "Azure",
        "models": {
          "gpt-5.6-terra": {
            "id": "gpt-5.6-terra",
            "name": "GPT-5.6 Terra",
            "attachment": true,
            "reasoning": true,
            "tool_call": true,
            "modalities": {"input": ["text", "image", "pdf"], "output": ["text"]},
            "limit": {"context": 1050000, "input": 922000, "output": 128000},
            "cost": {
              "input": 2.5,
              "output": 15.0,
              "cache_read": 0.25,
              "tiers": [{
                "input": 5.0,
                "output": 22.5,
                "cache_read": 0.5,
                "tier": {"type": "context", "size": 272000}
              }]
            },
            "last_updated": "2026-07-09"
          }
        }
      }
    }
    """#.data(using: .utf8)!
}
