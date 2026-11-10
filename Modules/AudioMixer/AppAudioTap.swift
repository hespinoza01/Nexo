import CoreAudio
import Foundation

/// Gain value shared with the real-time IO thread. A plain Float store/load is atomic on arm64 and
/// x86-64, and a torn read can't happen for an aligned 32-bit value, so no lock on the audio thread.
final class GainBox: @unchecked Sendable {
    var value: Float
    init(_ value: Float) { self.value = value }
}

/// Per-app volume: a private process tap mutes the app's own output (`mutedWhenTapped`) and an
/// aggregate device (default output + that tap) plays it back at `gain`. Approach as in
/// vorssaint-utils' AppVolumeMixer (GPL-3.0-or-later), reduced to the essentials.
/// Creating the tap triggers macOS' "System Audio Recording" consent the first time.
final class AppAudioTap {
    let app: AudioApp
    let gain: GainBox
    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?

    init?(app: AudioApp, gain: Float, outputDevice: AudioObjectID) {
        self.app = app
        self.gain = GainBox(gain)
        guard let outputUID = AudioSystem.uid(of: outputDevice), start(outputUID: outputUID) else {
            stop()
            return nil
        }
    }

    deinit {
        stop()
    }

    func stop() {
        if let ioProc, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        ioProc = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = 0
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        tapID = 0
    }

    private func start(outputUID: String) -> Bool {
        let description = CATapDescription(stereoMixdownOfProcesses: app.objectIDs)
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        description.name = "Nexo \(app.name)"
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != 0 else { return false }
        var format = AudioStreamBasicDescription()
        guard CoreAudioProperty.read(tapID, kAudioTapPropertyFormat, &format), format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return false }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Nexo Mixer \(app.name)",
            kAudioAggregateDeviceUIDKey: "com.luckylopolis.nexo.mixer.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr, aggregateID != 0 else { return false }
        let gain = self.gain
        let tapChannels = Int(format.mChannelsPerFrame)
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { _, input, _, output, _ in
            MixRender.render(input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                output: UnsafeMutableAudioBufferListPointer(output), tapChannels: tapChannels, gain: gain.value)
        }
        guard status == noErr, let ioProc else { return false }
        return AudioDeviceStart(aggregateID, ioProc) == noErr
    }
}

/// Real-time render: copy the tap's samples to the output with gain and a soft limiter. No allocation,
/// no locks, no Objective-C: it runs on the HAL's IO thread.
enum MixRender {
    static let limiterKnee: Float = 0.9

    static func render(input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer, tapChannels: Int, gain: Float) {
        guard let source = tapBuffer(input, tapChannels: tapChannels), let sourceData = source.mData else {
            silence(output)
            return
        }
        let sourceChannels = Int(source.mNumberChannels)
        let sourceFrames = Int(source.mDataByteSize) / (MemoryLayout<Float>.size * max(1, sourceChannels))
        let samples = sourceData.assumingMemoryBound(to: Float.self)
        var outputChannel = 0
        for buffer in output {
            guard let data = buffer.mData else { continue }
            let channels = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(1, channels))
            let destination = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let sourceChannel = min(outputChannel + channel, sourceChannels - 1)
                    let sample = frame < sourceFrames ? samples[frame * sourceChannels + sourceChannel] : 0
                    destination[frame * channels + channel] = limit(sample * gain)
                }
            }
            outputChannel += channels
        }
    }

    /// Transparent below the knee, then a smooth curve that approaches but never exceeds full scale,
    /// so a >100 % boost doesn't hard-clip into crackle.
    static func limit(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > limiterKnee else { return sample }
        let headroom = 1 - limiterKnee
        let shaped = limiterKnee + headroom * tanh((magnitude - limiterKnee) / headroom)
        return sample < 0 ? -shaped : shaped
    }

    /// The aggregate's input side is the tap: the last buffer carrying the tap's channel count.
    private static func tapBuffer(_ input: UnsafeMutableAudioBufferListPointer, tapChannels: Int) -> AudioBuffer? {
        input.reversed().first { Int($0.mNumberChannels) == tapChannels && $0.mData != nil && $0.mDataByteSize > 0 }
    }

    private static func silence(_ output: UnsafeMutableAudioBufferListPointer) {
        for buffer in output {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }
}
