import Foundation

// Checks for deciding that two humans are the same human, and for reading a file
// that already exists on somebody's disk.
//
// Both failures here are quiet and expensive. A wrong match attaches a meeting or
// a promise to the wrong colleague and nothing announces it. A decode that throws
// takes every person at once, and the app would come up looking freshly
// installed.

/// Returns the number of failed checks, so the entry point decides the exit code.
func runIdentityChecks() -> Int {
var failures = 0

func check(_ passed: Bool, rule: String, meaning: String, saw: String) {
    if passed { return }
    failures += 1
    print("""

    ✗ \(rule)
      why it matters: \(meaning)
      what happened:  \(saw)
    """)
}

// ── Normalising an address ───────────────────────────────────────────────────

do {
    let forms = ["mailto:Ivan.Petrov@Example.com",
                 "  IVAN.PETROV@example.com ",
                 "Ivan Petrov <ivan.petrov@example.com>",
                 "ivan.petrov@example.com"]
    let normalised = Set(forms.map { PersonIdentity.normalize(email: $0) })
    check(normalised == ["ivan.petrov@example.com"],
          rule: "the four shapes an address arrives in reduce to one",
          meaning: "calendars hand over mailto: URLs, display-name forms and mixed case; if these "
                 + "stay distinct the same colleague is stored two or three times and matching by "
                 + "address never fires",
          saw: "reduced to \(normalised.sorted())")
}

// ── The match ────────────────────────────────────────────────────────────────

// THE case this was built for. Two colleagues called Ivan, and a calendar invite
// carrying an address.
do {
    let candidates = [
        PersonIdentity.Candidate(name: "Ivan Petrov", emails: ["ivan.petrov@example.com"]),
        PersonIdentity.Candidate(name: "Ivan Sidorov", emails: ["ivan.sidorov@example.com"]),
    ]
    let match = PersonIdentity.resolve(name: "Ivan", email: "IVAN.SIDOROV@example.com",
                                       among: candidates)
    check(match == PersonIdentity.Match(name: "Ivan Sidorov", confidence: .byEmail),
          rule: "an address decides between two people with the same first name",
          meaning: "this is the whole reason addresses are stored: by name alone \"Ivan\" fits both, "
                 + "and whichever answer comes back is a coin flip that then collects somebody "
                 + "else's promises",
          saw: "resolved to \(String(describing: match))")
}

// The old behaviour returned the first candidate that fit. A coin flip is worse
// than no answer, because no answer is visible.
do {
    let candidates = [
        PersonIdentity.Candidate(name: "Ivan Petrov"),
        PersonIdentity.Candidate(name: "Ivan Sidorov"),
    ]
    let match = PersonIdentity.resolve(name: "Ivan", email: nil, among: candidates)
    check(match == nil,
          rule: "an ambiguous name is not a match",
          meaning: "an unresolved attendee is merely unhelpful; a confidently wrong one corrupts "
                 + "two people's histories and never says so",
          saw: "resolved to \(String(describing: match))")
}

// Most calendars deliver display names and no address at all. The fallback has to
// keep working, or the brief loses every attendee it used to find.
do {
    let candidates = [
        PersonIdentity.Candidate(name: "Ivan Petrov"),
        PersonIdentity.Candidate(name: "Maria Gomez"),
    ]
    let match = PersonIdentity.resolve(name: "Ivan", email: nil, among: candidates)
    check(match == PersonIdentity.Match(name: "Ivan Petrov", confidence: .byName),
          rule: "an unambiguous name still matches when no address is given",
          meaning: "corporate calendars routinely send attendees as display names only; requiring "
                 + "an address would make the brief emptier than it was before addresses existed",
          saw: "resolved to \(String(describing: match))")
}

// An address that nobody is registered under must not fall through to a name
// match against a different person.
do {
    let candidates = [PersonIdentity.Candidate(name: "Ivan Petrov",
                                               emails: ["ivan.petrov@example.com"])]
    let match = PersonIdentity.resolve(name: "Maria", email: "maria@example.com",
                                       among: candidates)
    check(match == nil,
          rule: "an unknown address plus an unknown name resolves to nobody",
          meaning: "the brief must be able to show an attendee it does not know, rather than "
                 + "guessing at the nearest name on file",
          saw: "resolved to \(String(describing: match))")
}

// ── Reading a file written before these fields existed ───────────────────────

// Synthetic, so this check is deterministic wherever it runs: exactly the shape
// people.json had before emails and handles were added.
do {
    let old = """
    [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"Ivan Petrov",\
    "notes":"Runs the platform team","dossier":"...","dossierDate":716000000}]
    """
    let decoder = JSONDecoder()
    do {
        let people = try decoder.decode([Person].self, from: Data(old.utf8))
        check(people.count == 1 && people[0].name == "Ivan Petrov"
                && people[0].emails.isEmpty && people[0].handles.isEmpty,
              rule: "a people.json written before emails existed still decodes",
              meaning: "if a missing key throws instead of defaulting, the whole array fails and "
                     + "every person disappears at once — the app comes up looking freshly installed",
              saw: "decoded \(people.count) people, first has emails \(people.first?.emails ?? [])")
    } catch {
        check(false,
              rule: "a people.json written before emails existed still decodes",
              meaning: "if a missing key throws instead of defaulting, the whole array fails and "
                     + "every person disappears at once — the app comes up looking freshly installed",
              saw: "threw: \(error)")
    }
}

// And the real file on this machine, when there is one. The synthetic case above
// proves the rule; this proves it against whatever has actually accumulated,
// which is the copy that matters.
do {
    let url = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Griasa/people.json")
    if let data = try? Data(contentsOf: url) {
        do {
            let people = try JSONDecoder().decode([Person].self, from: data)
            print("  · the real people.json on this machine decodes: \(people.count) people")
        } catch {
            check(false,
                  rule: "the real people.json on this machine decodes",
                  meaning: "this is the file the user would lose; the synthetic case passing is "
                         + "not evidence about the one that has real names in it",
                  saw: "threw: \(error)")
        }
    }
}

return failures
}
