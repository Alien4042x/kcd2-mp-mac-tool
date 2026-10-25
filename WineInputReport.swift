import Foundation

struct WineInputReport: Decodable {
    let status: String
    let deviceCount: UInt32
    let samples: UInt32?
    let peak: UInt32?
    let errorCode: UInt32?

    func summary(exitCode: Int32) throws -> String {
        if status == "ok_signal" || status == "ok_silent" {
            guard exitCode == 0, deviceCount > 0, let samples, samples > 0,
                  let peak, peak <= 32768, errorCode == nil,
                  (status == "ok_signal" ? peak > 0 : peak == 0) else {
                throw CocoaError(.coderReadCorrupt)
            }
            return status == "ok_signal"
                ? "Wine received \(samples) audio samples with a signal. Microphone access works in this Wine session."
                : "Wine received \(samples) audio samples, all silent. Check the headset mute switch and selected input."
        }
        let failures = ["no_devices", "event_failed", "allocation_failed", "open_failed", "prepare_failed",
                        "queue_failed", "start_failed", "timeout", "empty_capture"]
        guard exitCode != 0, failures.contains(status), samples == nil, peak == nil,
              let errorCode else { throw CocoaError(.coderReadCorrupt) }
        return "Wine microphone test failed: \(status) (code \(errorCode), \(deviceCount) input devices)."
    }
}
