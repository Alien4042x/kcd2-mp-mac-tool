import Foundation

@main struct WineInputReportChecks {
    static func read(_ json: String, exitCode: Int32) throws -> String {
        try JSONDecoder().decode(WineInputReport.self, from: Data(json.utf8)).summary(exitCode: exitCode)
    }

    static func main() throws {
        let signal = #"{"status":"ok_signal","deviceCount":1,"samples":48000,"peak":100,"errorCode":null}"#
        let signalSummary = try read(signal, exitCode: 0)
        precondition(signalSummary.contains("with a signal"))
        let silence = #"{"status":"ok_silent","deviceCount":1,"samples":48000,"peak":0,"errorCode":null}"#
        let silenceSummary = try read(silence, exitCode: 0)
        precondition(silenceSummary.contains("all silent"))
        let failure = #"{"status":"open_failed","deviceCount":1,"samples":null,"peak":null,"errorCode":5}"#
        let failureSummary = try read(failure, exitCode: 1)
        precondition(failureSummary.contains("failed"))
        let invalid = ["", "null", "{}", signal.replacingOccurrences(of: "48000", with: "0"),
                       signal.replacingOccurrences(of: "100", with: "0"),
                       signal.replacingOccurrences(of: "100", with: "40000"),
                       signal.replacingOccurrences(of: "48000", with: "null"),
                       silence.replacingOccurrences(of: "\"peak\":0", with: "\"peak\":null"),
                       failure.replacingOccurrences(of: "5", with: "null")]
        for json in invalid {
            do { _ = try read(json, exitCode: 0); fatalError("Invalid diagnostic accepted") }
            catch {}
        }
        do { _ = try read(signal, exitCode: 1); fatalError("Failed process reported success") }
        catch {}
        do { _ = try read(failure, exitCode: 0); fatalError("Inconsistent result accepted") }
        catch {}
        print("PASS: signal, silence, missing data, empty capture, malformed output and process failures distinguished")
    }
}
