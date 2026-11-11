import XCTest
import UIKit
@testable import PhoneCoder

final class PhoneCoderImageGenerationTests: XCTestCase {
    @MainActor
    func testInstalledIsAdvisoryAndNeverClaimsAdmission() {
        let ready = PhoneCoderImageReadiness(installed: true, downloading: false, snapshot: nil, requiredBytes: 3_000_000_000)
        XCTAssertEqual(ready.title, "Downloaded on this phone")
        XCTAssertTrue(ready.detail.contains("recheck"))
        XCTAssertEqual(ready.memoryFit, "Memory fit unavailable")
        XCTAssertEqual(PhoneCoderImageReadiness(installed: false, downloading: false, snapshot: nil, requiredBytes: 1).action, .download)
    }

    @MainActor
    func testMemoryFitUsesAdvisoryHeadroomRatherThanPhysicalCapacity() {
        let snapshot = PhoneCoderDeviceSnapshot(sampledAt: Date(timeIntervalSince1970: 0),
            physicalMemoryBytes: 12_000_000_000, appFootprintBytes: 2_000_000_000,
            processAvailableBytes: 1_000_000_000, processCeilingBytes: 3_000_000_000,
            entitlement: .present, thermalState: .nominal, effectiveThermalState: .nominal,
            lowPowerMode: false, stopReason: nil, isThrottling: false)
        let ready = PhoneCoderImageReadiness(installed: true, downloading: false,
            snapshot: snapshot, requiredBytes: 3_000_000_000)
        XCTAssertEqual(ready.action, .generate, "An advisory estimate must not replace runtime admission")
        XCTAssertTrue(ready.memoryFit.contains("tight"))
        XCTAssertTrue(ready.memoryFit.contains("recheck"))
    }

    @MainActor
    func testLoadingDenoisingFinalizingThenValidResult() throws {
        var operation = PhoneCoderImageOperation()
        let id = UUID()
        operation.begin(id: id, modelID: "stabilityai/sd-turbo", steps: 1, pixelEdge: 512)
        XCTAssertEqual(operation.phase, .preparing)
        operation.advance(.loading, id: id)
        XCTAssertEqual(operation.phase, .loading)
        operation.advance(.denoising, id: id, progress: 1)
        XCTAssertEqual(operation.phase, .denoising)
        operation.advance(.finalizing, id: id)
        XCTAssertEqual(operation.phase, .finalizing)
        XCTAssertNil(operation.image)
        XCTAssertTrue(operation.publish(pngData: try png(), id: id))
        XCTAssertEqual(operation.phase, .ready)
        XCTAssertEqual(operation.resultOperationID, id)
        XCTAssertEqual(operation.resultWidth, 2)
        XCTAssertEqual(operation.resultHeight, 3)
        XCTAssertNotNil(operation.image)
    }

    @MainActor
    func testInvalidPNGHasExplicitFailureAndNoSuccess() {
        var operation = started()
        let id = operation.id!
        operation.advance(.finalizing, id: id)
        XCTAssertFalse(operation.publish(pngData: Data("invalid PNG".utf8), id: id))
        XCTAssertEqual(operation.failure, .imageDecode)
        XCTAssertEqual(operation.phase, .failed)
        XCTAssertNil(operation.image)
        XCTAssertNil(operation.resultOperationID)
    }

    @MainActor
    func testOldCallbacksCannotRegressFinalizingOrReplaceNewOperation() throws {
        var operation = started()
        let first = operation.id!
        operation.advance(.finalizing, id: first)
        operation.advance(.denoising, id: first, progress: 0.1)
        XCTAssertEqual(operation.phase, .finalizing)
        let replacement = UUID()
        operation.begin(id: replacement, modelID: "stabilityai/sd-turbo", steps: 1, pixelEdge: 320)
        operation.advance(.finalizing, id: first)
        operation.fail(.memory, id: first)
        XCTAssertFalse(operation.publish(pngData: try png(), id: first))
        XCTAssertEqual(operation.phase, .preparing)
        XCTAssertEqual(operation.id, replacement)
        XCTAssertEqual(operation.effectivePixelEdge, 320)
    }

    @MainActor
    func testDelayedProgressAndFailureCannotUndoSuccessfulPublication() throws {
        var operation = started()
        let id = operation.id!
        operation.advance(.finalizing, id: id)
        XCTAssertTrue(operation.publish(pngData: try png(), id: id))
        operation.advance(.denoising, id: id, progress: 0.2)
        operation.fail(.generation, id: id)
        XCTAssertEqual(operation.phase, .ready)
        XCTAssertEqual(operation.resultOperationID, id)
        XCTAssertNil(operation.failure)
        XCTAssertNotNil(operation.image)
    }

    @MainActor
    func testNewAttemptAndSelectionClearPriorResult() throws {
        var operation = started()
        operation.advance(.finalizing, id: operation.id!)
        XCTAssertTrue(operation.publish(pngData: try png(), id: operation.id!))
        operation.begin(id: UUID(), modelID: "stabilityai/sd-turbo", steps: 2, pixelEdge: 192)
        XCTAssertNil(operation.image)
        XCTAssertNil(operation.resultOperationID)
        XCTAssertNil(operation.resultWidth)
        operation.reset()
        XCTAssertEqual(operation.phase, .idle)
        XCTAssertNil(operation.id)
    }

    @MainActor
    func testUserAndBackgroundCancellationHoldBusyUntilDrainAndRejectPublication() throws {
        for reason in [PhoneCoderImageCancellation.user, .background] {
            var operation = started()
            let id = operation.id!
            operation.requestCancellation(reason)
            XCTAssertEqual(operation.phase, .cancelling)
            XCTAssertTrue(operation.isBusy)
            operation.advance(.finalizing, id: id)
            XCTAssertFalse(operation.publish(pngData: try png(), id: id))
            operation.finishCancellation(id: id)
            XCTAssertEqual(operation.phase, .cancelled)
            XCTAssertFalse(operation.isBusy)
            XCTAssertEqual(operation.cancellation, reason)
            XCTAssertNil(operation.image)
        }
    }

    @MainActor
    func testProductionUnloadCancelsForSafetyAndRetainsReservationUntilDrain() async throws {
        let service = ImageGenerationService.shared
        let residency = ModelResidency.shared
        guard !residency.imageOperationReserved else { return XCTFail("Image test requires an idle shared owner") }
        // Both calls run in the same main-actor turn. Cancellation is signalled
        // before runGeneration can enter native work or a download.
        service.generate(prompt: "cancellation fixture")
        let id = try XCTUnwrap(service.imageOperation.id)
        service.unload()
        XCTAssertEqual(service.imageOperation.cancellation, .safety)
        XCTAssertEqual(service.imageOperation.phase, .cancelling)
        XCTAssertTrue(residency.imageOperationReserved)
        await waitForImageReservationToRetire()
        XCTAssertEqual(service.imageOperation.id, id)
        XCTAssertEqual(service.imageOperation.phase, .cancelled)
        XCTAssertEqual(service.imageOperation.cancellation, .safety)
        XCTAssertTrue(service.statusMessage.contains("device safety"))
        XCTAssertTrue(service.imageOperation.diagnostics(snapshot: nil).contains("Cancellation: safety"))
        XCTAssertNil(service.image)
    }

    @MainActor
    func testProductionBackgroundCancelRetainsOriginWhenUserCancelArrivesDuringDrain() async throws {
        let service = ImageGenerationService.shared
        guard !ModelResidency.shared.imageOperationReserved else { return XCTFail("Image test requires an idle shared owner") }
        service.generate(prompt: "cancellation fixture")
        service.cancel(reason: .background)
        service.cancel()
        XCTAssertEqual(service.imageOperation.cancellation, .background)
        XCTAssertTrue(ModelResidency.shared.imageOperationReserved)
        await waitForImageReservationToRetire()
        XCTAssertEqual(service.imageOperation.phase, .cancelled)
        XCTAssertEqual(service.imageOperation.cancellation, .background)
        XCTAssertTrue(service.statusMessage.contains("background"))
        XCTAssertNil(service.image)
    }

    @MainActor
    func testProductionUserCancelRetainsOriginWhenSafetyUnloadArrivesDuringDrain() async throws {
        let service = ImageGenerationService.shared
        guard !ModelResidency.shared.imageOperationReserved else { return XCTFail("Image test requires an idle shared owner") }
        service.generate(prompt: "cancellation fixture")
        service.cancel()
        service.unload()
        XCTAssertEqual(service.imageOperation.cancellation, .user)
        XCTAssertTrue(ModelResidency.shared.imageOperationReserved)
        await waitForImageReservationToRetire()
        XCTAssertEqual(service.imageOperation.phase, .cancelled)
        XCTAssertEqual(service.imageOperation.cancellation, .user)
        XCTAssertEqual(service.statusMessage, "Generation stopped. You can retry.")
        XCTAssertNil(service.image)
    }

    @MainActor
    private func waitForImageReservationToRetire() async {
        for _ in 0..<100 {
            if !ModelResidency.shared.imageOperationReserved { return }
            await Task.yield()
        }
        XCTFail("Cancelled image operation did not retire its reservation")
    }

    @MainActor
    func testKnownErrorsMapWithoutRawExceptionText() {
        XCTAssertEqual(PhoneCoderImageFailure.category(for: NSError(domain: "ImageGen", code: -3)), .memory)
        XCTAssertEqual(PhoneCoderImageFailure.category(for: NSError(domain: "ImageGen", code: -2)), .residency)
        XCTAssertEqual(PhoneCoderImageFailure.category(for: NSError(domain: "ImageGen", code: -1)), .imageEncode)
        XCTAssertEqual(PhoneCoderImageFailure.category(for: URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(PhoneCoderImageFailure.category(for: NSError(domain: "HFDownload", code: 401)), .access)
        XCTAssertEqual(PhoneCoderImageFailure.category(for: NSError(domain: "unknown", code: 401)), .generation)
    }

    @MainActor
    func testDiagnosticsExcludePromptNegativePromptImagesCredentialsPathsAndRawExceptions() throws {
        let sentinels = ["PROMPT_SENTINEL", "NEGATIVE_PROMPT_SENTINEL", "IMAGE_BASE64_SENTINEL", "hf_CREDENTIAL_SENTINEL", "/private/PATH_SENTINEL", "RAW_EXCEPTION_SENTINEL"]
        var operation = PhoneCoderImageOperation()
        operation.begin(id: UUID(), modelID: sentinels.joined(separator: " "), steps: 4, pixelEdge: 320)
        let error = NSError(domain: sentinels.joined(separator: " "), code: 999, userInfo: [NSLocalizedDescriptionKey: sentinels.joined(separator: " ")])
        operation.fail(PhoneCoderImageFailure.category(for: error), id: operation.id!)
        let text = operation.diagnostics(snapshot: nil)
        for sentinel in sentinels { XCTAssertFalse(text.contains(sentinel)) }
        XCTAssertTrue(text.contains("Model: Unavailable"))
        XCTAssertTrue(text.contains("Failure: generation"))
        XCTAssertFalse(text.contains(error.localizedDescription))
        XCTAssertEqual(text, operation.diagnostics(snapshot: nil))
    }

    @MainActor
    func testSuccessfulDiagnosticsContainMetadataButNoImagePayload() throws {
        var operation = started()
        let data = try png()
        operation.advance(.finalizing, id: operation.id!)
        XCTAssertTrue(operation.publish(pngData: data, id: operation.id!))
        let text = operation.diagnostics(snapshot: nil)
        XCTAssertTrue(text.contains("Result: 2 × 3"))
        XCTAssertTrue(text.contains("PNG bytes: \(data.count)"))
        XCTAssertFalse(text.contains(data.base64EncodedString()))
    }

    @MainActor
    private func started() -> PhoneCoderImageOperation {
        var operation = PhoneCoderImageOperation()
        operation.begin(id: UUID(), modelID: "stabilityai/sd-turbo", steps: 1, pixelEdge: 512)
        return operation
    }

    @MainActor
    private func png() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).image { context in UIColor.red.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 3)) }
        return try XCTUnwrap(image.pngData())
    }
}
