import Foundation

/// Whether the day pipeline may ask a model right now.
///
/// A day tried while no model is there fails, and each failure costs one of its
/// three attempts: a Mac that was offline, or a local engine still starting at
/// launch, would use them all up and leave days `failed` that nothing was wrong
/// with. So the queue starts only when there is something to ask: the local
/// engine (Griasa's, Ollama, LM Studio or a typed server) once it answers, or a
/// cloud provider the person set up with a key. Foundation only, so test.sh can
/// reach it.
enum ConversationModelGate {
    static func mayRun(providerIsLocal: Bool, providerIsConfigured: Bool, localEngineReady: Bool) -> Bool {
        providerIsLocal ? localEngineReady : providerIsConfigured
    }
}
