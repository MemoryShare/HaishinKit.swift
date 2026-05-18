import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite struct StreamRecorderTests {
    // MARK: - Single-track starvation (silent recording loss regression)
    //
    // The recorder only calls `writer.startWriting()` once an input exists for *every*
    // configured track (`isReadyForStartWriting`: settings.count == writer.inputs.count).
    // If one media type is never delivered, the writer stays `.unknown`, writes zero
    // bytes, produces no file, and emits no error — the loss is only discovered when
    // `stopRecording()` is called. In production this was triggered by the RTMP server's
    // `|RtmpSampleAccess` flag starving the recorder of audio. These tests pin that
    // failure mode so any regression (or a fix that changes it) is visible.

    @Test func stopRecording_videoOnlyDelivery_throwsFailedToFinishWriting() async throws {
        let recorder = StreamRecorder()
        let mixer = MediaMixer(captureSessionMode: .manual)
        let url = await recorder.moviesDirectory.appendingPathComponent("video-only-\(UUID().uuidString).mov")

        try await recorder.startRecording(url)

        // Only video ever arrives — audio track never materialises.
        for _ in 0..<30 {
            if let video = CMVideoSampleBufferFactory.makeSampleBuffer(width: 1280, height: 720) {
                recorder.mixer(mixer, didOutput: video)
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        await #expect(throws: (StreamRecorder.Error).self) {
            _ = try await recorder.stopRecording()
        }
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func stopRecording_audioOnlyDelivery_throwsFailedToFinishWriting() async throws {
        let recorder = StreamRecorder()
        let mixer = MediaMixer(captureSessionMode: .manual)
        let url = await recorder.moviesDirectory.appendingPathComponent("audio-only-\(UUID().uuidString).mov")

        try await recorder.startRecording(url)

        // Only audio ever arrives — video track never materialises.
        for _ in 0..<30 {
            if let audio = AVAudioPCMBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1) {
                recorder.mixer(mixer, didOutput: audio, when: AVAudioTime(hostTime: mach_absolute_time()))
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        await #expect(throws: (StreamRecorder.Error).self) {
            _ = try await recorder.stopRecording()
        }
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func startRunning_nil() async throws {
        let recorder = StreamRecorder()
        try await recorder.startRecording(nil)
        let moviesDirectory = await recorder.moviesDirectory
        // $moviesDirectory/B644F60F-0959-4F54-9D14-7F9949E02AD8.mp4
        #expect(((await recorder.outputURL?.path.contains(moviesDirectory.path())) != nil))
    }

    @Test func startRunning_fileName() async throws {
        let recorder = StreamRecorder()
        try? await recorder.startRecording(URL(string: "dir/sample.mp4"))
        _ = await recorder.moviesDirectory
        // $moviesDirectory/dir/sample.mp4
        #expect(((await recorder.outputURL?.path.contains("dir/sample.mp4")) != nil))
    }

    @Test func startRunning_fullPath() async {
        let recorder = StreamRecorder()
        let fullPath = await recorder.moviesDirectory.appendingPathComponent("sample.mp4")
        // $moviesDirectory/sample.mp4
        try? await recorder.startRecording(fullPath)
        #expect(await recorder.outputURL == fullPath)
    }

    @Test func startRunning_dir() async {
        let recorder = StreamRecorder()
        try? await recorder.startRecording(URL(string: "dir"))
        // $moviesDirectory/dir/33FA7D32-E0A8-4E2C-9980-B54B60654044.mp4
        #expect(((await recorder.outputURL?.path.contains("dir")) != nil))
    }

    @Test func startRunning_fileAlreadyExists() async {
        let recorder = StreamRecorder()
        let filePath = await recorder.moviesDirectory.appendingPathComponent("duplicate-file.mp4")
        FileManager.default.createFile(atPath: filePath.path, contents: nil)
        do {
            try await recorder.startRecording(filePath)
            fatalError()
        } catch {
            try? FileManager.default.removeItem(atPath: filePath.path)
        }
    }
}
