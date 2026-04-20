@testable import FlowDown
import Foundation
import Storage
import Testing

struct ModelScopeTests {
    @Test
    func `cloud model response format inference normalizes endpoints`() {
        let missingFormat: CloudModel.ResponseFormat? = nil

        #expect(
            CloudModel.ResponseFormat.inferredFormat(
                fromEndpoint: " HTTPS://api.example.com/v1/chat/completions/?query=1#fragment ",
            ) == .chatCompletions,
        )
        #expect(
            CloudModel.ResponseFormat.inferredFormat(
                fromEndpoint: "https://api.example.com/responses/",
            ) == .responses,
        )
        #expect(
            CloudModel.ResponseFormat.inferredFormat(
                fromEndpoint: "https://chatgpt.com/backend-api/codex/?query=1",
            ) == .responses,
        )
        #expect(
            CloudModel.ResponseFormat.inferredFormat(
                fromEndpoint: "https://chatgpt.com/backend-api/codex/responses?query=1",
            ) == .responses,
        )
        #expect(
            CloudModel.isOpenAICodexOAuthEndpoint(
                " HTTPS://CHATGPT.COM/backend-api/codex/?query=1#fragment ",
            ),
        )
        #expect(
            CloudModel.isOpenAICodexOAuthEndpoint(
                " HTTPS://CHATGPT.COM/backend-api/codex/responses/?query=1#fragment ",
            ),
        )
        #expect(
            CloudModel.canonicalOpenAICodexOAuthEndpoint(
                for: "https://chatgpt.com/backend-api/codex/responses",
            ) == CloudModel.openAICodexOAuthEndpoint,
        )

        let oauthModel = CloudModel(
            deviceId: Storage.deviceId,
            endpoint: "https://chatgpt.com/backend-api/codex/responses",
        )
        #expect(oauthModel.usesAutomaticOpenAIOAuth)

        #expect(CloudModel.ResponseFormat.inferredFormat(fromEndpoint: "") == missingFormat)
        #expect(CloudModel.ResponseFormat.chatCompletions.defaultModelListEndpoint == "$INFERENCE_ENDPOINT$/../../models")
        #expect(CloudModel.ResponseFormat.responses.defaultModelListEndpoint == "$INFERENCE_ENDPOINT$/../models")
    }

    @Test
    func `legacy codex response format decodes as responses`() throws {
        let payload = Data(#"{"deviceId":"test-device","response_format":"codex"}"#.utf8)
        let decoded = try JSONDecoder().decode(CloudModel.self, from: payload)

        #expect(decoded.response_format == .responses)
    }

    @Test
    func `pollinations models translate advertised capabilities into cloud models`() {
        let pollinationsModel = PollinationsModel(
            name: "openai-large",
            tier: "anonymous",
            input_modalities: ["text"],
            output_modalities: ["text"],
            tools: true,
            vision: true,
            audio: true,
        )

        let cloudModel = PollinationsService.shared.createCloudModel(from: pollinationsModel)

        #expect(cloudModel.model_identifier == "openai-large")
        #expect(cloudModel.endpoint == "https://text.pollinations.ai/openai/v1/chat/completions")
        #expect(cloudModel.capabilities.contains(.tool))
        #expect(cloudModel.capabilities.contains(.visual))
        #expect(cloudModel.capabilities.contains(.auditory))
        #expect(cloudModel.comment.contains("pollinations.ai"))
    }

    @Test
    func `hub download progress tracks file completion and cancellation`() {
        let progress = ModelManager.HubDownloadProgress()
        progress.acquiredFileList(["a.bin", "b.bin"])

        #expect(progress.progressMap.keys.sorted() == ["a.bin", "b.bin"])
        #expect(progress.progressMap["a.bin"]?.completedUnitCount == 0)
        #expect(progress.progressMap["a.bin"]?.totalUnitCount == 100)

        progress.completeFile("a.bin", size: 64)
        progress.finalizeDownload()

        #expect(progress.progressMap["a.bin"]?.completedUnitCount == 64)
        #expect(progress.progressMap["b.bin"]?.completedUnitCount == progress.progressMap["b.bin"]?.totalUnitCount)

        progress.isCancelled = true

        var didThrow = false
        do {
            try progress.checkContinue()
        } catch {
            didThrow = true
        }

        #expect(didThrow)
    }
}
