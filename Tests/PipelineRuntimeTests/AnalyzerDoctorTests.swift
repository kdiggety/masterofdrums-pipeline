import XCTest
@testable import PipelineRuntime

final class AnalyzerDoctorTests: XCTestCase {
    func testEvaluateEnvironmentFailsWhenRequiredAnalyzerVarsMissing() {
        let checks = AnalyzerDoctor.evaluateEnvironment([:])

        XCTAssertEqual(checks.first(where: { $0.name == "PIPELINE_AUDIO_ANALYZER_COMMAND" })?.status, .fail)
        XCTAssertEqual(checks.first(where: { $0.name == "backend command configuration" })?.status, .fail)
    }

    func testEvaluateEnvironmentWarnsOnRecommendedFallbackSettings() {
        let checks = AnalyzerDoctor.evaluateEnvironment([
            "PIPELINE_AUDIO_ANALYZER_COMMAND": "./.venv/bin/python ./scripts/analyzer-wrapper.py --input {input} --output {output}",
            "PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND": "./.venv/bin/python ./scripts/beat-this-backend.py --input {input} --output {output}"
        ])

        XCTAssertEqual(checks.first(where: { $0.name == "PIPELINE_AUDIO_ANALYZER_COMMAND" })?.status, .pass)
        XCTAssertEqual(checks.first(where: { $0.name == "backend command configuration" })?.status, .pass)
        XCTAssertEqual(checks.first(where: { $0.name == "PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND" })?.status, .warn)
        XCTAssertEqual(checks.first(where: { $0.name == "PIPELINE_ANALYZER_FALLBACK_POLICY" })?.status, .warn)
        XCTAssertEqual(checks.first(where: { $0.name == "PIPELINE_ANALYZER_VALIDATION_MODE" })?.status, .warn)
    }

    func testEvaluateEnvironmentPassesLegacyBackendConfiguration() {
        let checks = AnalyzerDoctor.evaluateEnvironment([
            "PIPELINE_AUDIO_ANALYZER_COMMAND": "./.venv/bin/python ./scripts/analyzer-wrapper.py --input {input} --output {output}",
            "PIPELINE_ANALYZER_BACKEND_COMMAND": "./.venv/bin/python ./scripts/beat-this-backend.py --input {input} --output {output}"
        ])

        XCTAssertEqual(checks.first(where: { $0.name == "PIPELINE_AUDIO_ANALYZER_COMMAND" })?.status, .pass)
        XCTAssertEqual(checks.first(where: { $0.name == "backend command configuration" })?.status, .pass)
        XCTAssertFalse(checks.contains(where: { $0.name == "PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND" }))
    }

    func testReportRenderIncludesSummaryAndFixes() {
        let report = AnalyzerDoctorReport(
            workingDirectory: "/tmp/repo",
            checks: [
                AnalyzerDoctorCheck(name: "repo-local virtualenv", status: .fail, detail: "missing", remediation: "create it"),
                AnalyzerDoctorCheck(name: "ffmpeg", status: .pass, detail: "found", remediation: nil),
                AnalyzerDoctorCheck(name: "PIPELINE_ANALYZER_FALLBACK_POLICY", status: .warn, detail: "not set", remediation: "export it")
            ]
        )

        let text = report.renderText()
        XCTAssertTrue(text.contains("[pipeline] analyzer preflight"))
        XCTAssertTrue(text.contains("fix: create it"))
        XCTAssertTrue(text.contains("summary: FAIL"))
    }
}
