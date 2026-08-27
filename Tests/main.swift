import Foundation

// Entry point, kept separate from the checks so those files read as a
// description of the rules rather than as a program.
let failed = runStabilizerChecks() + runSilenceChecks()
if failed == 0 {
    print("checks: all passed")
} else {
    print("\nchecks: \(failed) failed")
}
exit(failed == 0 ? 0 : 1)
