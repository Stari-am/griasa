import Foundation

// Entry point, kept separate from the checks so that file reads as a
// description of the rules rather than as a program.
let failed = runStabilizerChecks()
if failed == 0 {
    print("stabilizer checks: all passed")
} else {
    print("\nstabilizer checks: \(failed) failed")
}
exit(failed == 0 ? 0 : 1)
