import Accelerate
import AVFoundation

private let kAudioMixerTrack_frameCapacity: AVAudioFrameCount = 1024

protocol AudioMixerTrackDelegate: AnyObject {
    func track(_ track: AudioMixerTrack<Self>, didOutput audioPCMBuffer: AVAudioPCMBuffer, when: AVAudioTime)
    func track(_ track: AudioMixerTrack<Self>, errorOccurred error: AudioMixerError)
}

final class AudioMixerTrack<T: AudioMixerTrackDelegate> {
    let id: UInt8
    let outputFormat: AVAudioFormat
    weak var delegate: T?
    var settings: AudioMixerTrackSettings = .init() {
        didSet {
            settings.apply(audioConverter, oldValue: oldValue)
        }
    }
    var inputFormat: AVAudioFormat? {
        return audioConverter?.inputFormat
    }
    private var inSourceFormat: CMFormatDescription? {
        didSet {
            guard inSourceFormat != oldValue else {
                return
            }
            setUp(inSourceFormat)
        }
    }
    private var audioTime = AudioTime()
    private var ringBuffer: AudioRingBuffer?
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var audioConverter: AVAudioConverter? {
        didSet {
            guard let audioConverter else {
                return
            }
            audioConverter.downmix = settings.downmix
            if let channelMap = settings.validatedChannelMap(audioConverter) {
                audioConverter.channelMap = channelMap.map { NSNumber(value: $0) }
            } else {
                switch audioConverter.outputFormat.channelCount {
                case 1:
                    audioConverter.channelMap = [0]
                case 2:
                    audioConverter.channelMap = (audioConverter.inputFormat.channelCount == 1) ? [0, 0] : [0, 1]
                default:
                    break
                }
            }
            audioConverter.primeMethod = .normal
        }
    }

    init(id: UInt8, outputFormat: AVAudioFormat) {
        self.id = id
        self.outputFormat = outputFormat
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        inSourceFormat = sampleBuffer.formatDescription
        if !audioTime.hasAnchor {
            audioTime.anchor(sampleBuffer.presentationTimeStamp, sampleRate: outputFormat.sampleRate)
        }
        ringBuffer?.append(sampleBuffer)
        resample()
    }

    func append(_ audioBuffer: AVAudioPCMBuffer, when: AVAudioTime) {
        inSourceFormat = audioBuffer.format.formatDescription
        if !audioTime.hasAnchor {
            audioTime.anchor(when)
        }
        ringBuffer?.append(audioBuffer, when: when)
        resample()
    }

    /// Tracks whether we've logged the nil-buffers warning to avoid log spam.
    private var loggedNilBuffers = false

    @inline(__always)
    private func resample() {
        guard let outputBuffer, let inputBuffer, let ringBuffer else {
            if !loggedNilBuffers {
                logger.warn("AudioMixerTrack: resample() skipped — outputBuffer:", outputBuffer as Any,
                            "inputBuffer:", inputBuffer as Any, "ringBuffer:", ringBuffer as Any)
                loggedNilBuffers = true
            }
            return
        }
        loggedNilBuffers = false
        var status: AVAudioConverterOutputStatus? = .endOfStream
        repeat {
            var error: NSError?
            status = audioConverter?.convert(to: outputBuffer, error: &error) { inNumberFrames, status in
                if inNumberFrames <= ringBuffer.counts {
                    _ = ringBuffer.render(inNumberFrames, ioData: inputBuffer.mutableAudioBufferList)
                    inputBuffer.frameLength = inNumberFrames
                    status.pointee = .haveData
                    return inputBuffer
                } else {
                    status.pointee = .noDataNow
                    return nil
                }
            }
            switch status {
            case .haveData:
                delegate?.track(self, didOutput: outputBuffer.muted(settings.isMuted), when: audioTime.at)
                audioTime.advanced(1024)
            case .error:
                if let error {
                    logger.error("AudioMixerTrack: resample convert error:", error)
                    delegate?.track(self, errorOccurred: .failedToConvert(error: error))
                }
            default:
                break
            }
        } while(status == .haveData)
    }

    private func setUp(_ inSourceFormat: CMFormatDescription?) {
        guard let inputFormat = AVAudioUtil.makeAudioFormat(inSourceFormat) else {
            logger.error("AudioMixerTrack: failed to create input format from:", inSourceFormat as Any)
            delegate?.track(self, errorOccurred: .failedToCreate(from: inputFormat, to: outputFormat))
            return
        }
        ringBuffer = .init(inputFormat)
        if ringBuffer == nil {
            logger.error("AudioMixerTrack: failed to create ring buffer, inputFormat:", inputFormat)
        }
        inputBuffer = .init(pcmFormat: inputFormat, frameCapacity: kAudioMixerTrack_frameCapacity * 4)
        outputBuffer = .init(pcmFormat: outputFormat, frameCapacity: kAudioMixerTrack_frameCapacity)
        if inputBuffer == nil || outputBuffer == nil {
            logger.error("AudioMixerTrack: failed to allocate buffers, input:", inputBuffer as Any, "output:", outputBuffer as Any)
        }
        logger.info("AudioMixerTrack: setUp inputFormat:", inputFormat, ", outputFormat:", outputFormat)
        audioTime.reset()
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        if converter == nil {
            logger.error("AudioMixerTrack: AVAudioConverter init failed, from:", inputFormat, "to:", outputFormat)
        }
        audioConverter = converter
    }
}
