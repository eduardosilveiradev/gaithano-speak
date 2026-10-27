import Testing
import Foundation
@testable import SpeakCore

/// The version floor decides whether Fable 5.1 exists, and the naive comparison gets
/// it backwards on the exact number the spec names. That inversion is the reason this
/// suite exists.
@Suite("Preflight version")
struct CLIVersionTests {

    @Test("A numeric segment beats a string compare")
    func patchOrdering() {
        let floor = CLIVersion(2, 1, 255)
        let older = CLIVersion(2, 1, 9)

        // The bug this type prevents: as text, "2.1.255" sorts *before* "2.1.9",
        // so a string compare hides Agent Mode from everyone who is up to date.
        #expect("2.1.255" < "2.1.9")
        #expect(older < floor)
        #expect(!(floor < older))
    }

    @Test("Minor beats patch")
    func minorOrdering() {
        #expect(CLIVersion(2, 1, 255) < CLIVersion(2, 2, 0))
        #expect(CLIVersion(2, 2, 0) > CLIVersion.minimumClaudeCode)
        #expect(CLIVersion(1, 9, 9) < CLIVersion(2, 0, 0))
    }

    @Test("`claude --version` output parses out of its surrounding words")
    func parsesCLIOutput() {
        #expect(CLIVersion(parsing: "2.1.255 (Claude Code)") == CLIVersion(2, 1, 255))
        #expect(CLIVersion(parsing: "v2.1.255") == CLIVersion(2, 1, 255))
        #expect(CLIVersion(parsing: "2.2") == CLIVersion(2, 2, 0))
        #expect(CLIVersion(parsing: "not a version") == nil)
    }

    /// Semver: build metadata takes no part in precedence, and two builds of the
    /// floor version serve the same models.
    @Test("A build suffix does not change precedence")
    func buildMetadata() {
        let plain = CLIVersion(parsing: "2.1.255")
        let built = CLIVersion(parsing: "2.1.255+build.20260901")
        #expect(plain == built)
        #expect(built.map { $0 >= CLIVersion.minimumClaudeCode } == true)
    }

    /// A pre-release of the floor build is *below* it — the models aren't there yet,
    /// so the user needs the update prompt rather than a Fable escalation that 404s.
    @Test("A pre-release sorts below its release")
    func prerelease() {
        let beta = CLIVersion(parsing: "2.1.255-beta.1")
        #expect(beta == CLIVersion(2, 1, 255, prerelease: "beta.1"))
        #expect(beta.map { $0 < CLIVersion.minimumClaudeCode } == true)
        #expect(CLIVersion(2, 1, 255, prerelease: "alpha") < CLIVersion(2, 1, 255, prerelease: "beta"))
    }

    @Test("Description round-trips")
    func description() {
        #expect(CLIVersion(2, 1, 255).description == "2.1.255")
        #expect(CLIVersion(2, 1, 255, prerelease: "rc.1").description == "2.1.255-rc.1")
    }
}

@Suite("Preflight status")
struct PreflightStatusTests {

    private func allPassing(except failures: [PreflightCheck: PreflightFinding] = [:]) -> PreflightStatus {
        PreflightStatus(results: PreflightCheck.allCases.map {
            PreflightCheckResult($0, failures[$0] ?? .satisfied)
        })
    }

    @Test("Everything green is available")
    func available() {
        let status = allPassing()
        #expect(status.availability == .available)
        #expect(status.blocking.isEmpty)
        #expect(status.remedies.isEmpty)
        for capability in AgentCapability.allCases {
            #expect(status.isAvailable(capability))
        }
    }

    /// The distinction the spec asks for, and the one a single boolean would lose:
    /// no Chrome extension, but the desktop and the lights still work.
    @Test("A missing Chrome extension degrades the browser and nothing else")
    func chromeDegradesAlone() {
        let status = allPassing(except: [.chromeExtension: .notConnected])
        #expect(status.availability == .degraded)
        #expect(status.blocking.isEmpty)
        #expect(!status.isAvailable(.browser))
        #expect(status.isAvailable(.core))
        #expect(status.isAvailable(.smartThings))
        #expect(status.headline.contains("Chrome"))
    }

    @Test("SmartThings and Chrome fail independently")
    func independentDegradations() {
        let status = allPassing(except: [.smartThings: .notAuthenticated])
        #expect(status.availability == .degraded)
        #expect(status.isAvailable(.browser))
        #expect(!status.isAvailable(.smartThings))
    }

    @Test("Any of the four required checks takes the whole feature down")
    func requiredChecksBlock() {
        for check in PreflightCheck.allCases where check.isRequired {
            let status = allPassing(except: [check: .permissionNotGranted])
            #expect(status.availability == .unavailable, "\(check) should block")
            #expect(status.blocking.map(\.check) == [check])
            // Nothing runs at all, so no capability may claim to be usable.
            for capability in AgentCapability.allCases {
                #expect(!status.isAvailable(capability))
            }
        }
    }

    /// A pass that crashed halfway must not read as a green light.
    @Test("A check that never ran counts as blocking")
    func missingResultBlocks() {
        let partial = PreflightStatus(results: [PreflightCheckResult(.microphone, .satisfied)])
        #expect(partial.availability == .unavailable)
        #expect(partial.blocking.map(\.check).contains(.accessibility))
        #expect(partial.result(for: .claudeCode).finding == .checkFailed("not checked"))
    }

    @Test("An outdated CLI blocks and names the version it found")
    func outdatedCLI() {
        let status = allPassing(except: [.claudeCode: .outdated(found: "2.1.9")])
        #expect(status.availability == .unavailable)
        let remedy = status.result(for: .claudeCode).remedy
        #expect(remedy?.problem.contains("2.1.9") == true)
        #expect(remedy?.problem.contains("2.1.255") == true)
        #expect(remedy?.action == .runInTerminal("claude update"))
    }

    @Test("A missing top rung lowers the ceiling instead of stopping the run")
    func escalationCeiling() {
        #expect(allPassing().escalationCeiling == .fable)

        let noFable = allPassing(except: [.models: .unavailableOnPlan([.fable])])
        #expect(noFable.availability == .degraded)
        #expect(noFable.escalationCeiling == .opus)
        #expect(noFable.isAvailable(.core))

        let sonnetOnly = allPassing(except: [.models: .unavailableOnPlan([.fable, .opus])])
        #expect(sonnetOnly.escalationCeiling == .sonnet)
    }

    /// Blocking failures first: fixing SmartThings while the microphone is off helps
    /// nobody.
    @Test("Remedies lead with what is blocking")
    func remedyOrder() {
        let status = allPassing(except: [.smartThings: .notInstalled,
                                         .accessibility: .permissionNotGranted])
        #expect(status.remedies.count == 2)
        #expect(status.remedies.first?.problem.contains("Accessibility") == true)
    }

    /// The spec's rule that every error carries a concrete recovery action, checked
    /// across the whole cross product rather than trusted to the switch being complete.
    @Test("Every failure carries an action the user can take")
    func everyFailureHasARemedy() {
        let findings: [PreflightFinding] = [
            .permissionNotGranted,
            .notInstalled,
            .outdated(found: "1.0.0"),
            .notAuthenticated,
            .notConnected,
            .unavailableOnPlan([.fable]),
            .checkFailed("timed out"),
        ]
        for check in PreflightCheck.allCases {
            for finding in findings {
                let result = PreflightCheckResult(check, finding)
                let remedy = result.remedy
                #expect(remedy != nil, "\(check)/\(finding)")
                #expect(remedy?.problem.isEmpty == false, "\(check)/\(finding)")
                #expect(remedy?.actionLabel.isEmpty == false, "\(check)/\(finding)")
            }
        }
    }

    @Test("A satisfied check offers nothing to fix")
    func satisfiedHasNoRemedy() {
        #expect(PreflightCheckResult(.microphone, .satisfied).remedy == nil)
    }
}
