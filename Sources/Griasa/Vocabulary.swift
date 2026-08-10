import Foundation

/// Contextual vocabulary fed to every speech recognizer so English tech and
/// crypto terms are recognized correctly even when the surrounding speech is
/// in another language. Users can extend this list in Settings.
enum Vocabulary {
    static let builtIn: [String] = [
        // Dev / tech
        "GitHub", "GitLab", "pull request", "merge request", "commit", "deploy",
        "rollback", "backend", "frontend", "API", "SDK", "CLI", "endpoint",
        "Kubernetes", "Docker", "TypeScript", "JavaScript", "Python", "Swift",
        "Rust", "React", "Next.js", "PostgreSQL", "Redis", "webhook", "OAuth",
        "refactoring", "feature flag", "staging", "production", "hotfix",
        "code review", "standup", "sprint", "backlog", "roadmap", "MVP",
        "Figma", "Jira", "Slack", "Notion",
        // Crypto / web3
        "blockchain", "wallet", "staking", "airdrop", "token", "toncoin",
        "TON", "jetton", "USDT", "Bitcoin", "Ethereum", "DeFi", "NFT",
        "smart contract", "seed phrase", "mnemonic", "custody", "non-custodial",
        "mainnet", "testnet", "gas fee", "swap", "bridge", "liquidity",
        "stablecoin", "exchange", "KYC", "AML", "on-chain", "off-chain",
        "hash", "validator", "node", "dApp", "Telegram", "TON Connect",
    ]

    static func combined(with userTerms: String) -> [String] {
        let extra = userTerms
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return builtIn + extra
    }
}
