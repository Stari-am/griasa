import Foundation

// Entry point, kept separate from the checks so those files read as a
// description of the rules rather than as a program.
// Summed in groups: one 33-term expression is past what the compiler will type-check
// in reasonable time, and adding a file of checks should not break the build.
let group0: Int = runStabilizerChecks() + runSilenceChecks() + runIdentityChecks() + runMCPChecks() + runScopeChecks() + runCommitmentChecks() + runAttendanceChecks() + runAudioFormatChecks()
let group1: Int = runCleanerChecks() + runProviderDefaultChecks() + runSecretChecks() + runModelChecks() + runManagedChecks() + runNoticeChecks() + runRecordingRulesChecks() + runImportChecks()
let group2: Int = runFirstRunChecks() + runLocalModelChecks() + runRoutingChecks() + runRuntimeParsingChecks() + runEngineChoiceChecks() + runOllamaRequestChecks() + runPendingChecks() + runSetupMemoryChecks()
let group3: Int = runLlamaStreamChecks() + runLlamaServerChecks() + runResumeChecks() + runGrammarChecks() + runLongMeetingChecks() + runMCPEndpointChecks() + runMCPBundleChecks() + runBenchmarkChecks()
let group4: Int = runConversationChecks() + runWordSearchChecks()
let failed = group0 + group1 + group2 + group3 + group4
if failed == 0 {
    print("checks: all passed")
} else {
    print("\nchecks: \(failed) failed")
}
exit(failed == 0 ? 0 : 1)
