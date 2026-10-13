import Foundation

public enum LLMProviderFactory {
    /// Builds the provider for `config`. API keys are read from `secrets` on every call, so key edits apply immediately.
    public static func make(
        config: LLMProviderConfig,
        secrets: any SecretStore,
        session: URLSession = .shared,
        locator: CLILocator = .shared
    ) -> any LLMProvider {
        switch config.kind {
        case .anthropicAPI: AnthropicProvider(config: config, secrets: secrets, session: session)
        case .openAIAPI, .localOpenAICompatible: OpenAIProvider(config: config, secrets: secrets, session: session)
        case .geminiAPI: GeminiProvider(config: config, secrets: secrets, session: session)
        case .claudeCLI: ClaudeCLIProvider(config: config, locator: locator)
        case .codexCLI: CodexCLIProvider(config: config, locator: locator)
        case .geminiCLI: GeminiCLIProvider(config: config, locator: locator)
        case .cursorCLI: CursorCLIProvider(config: config, locator: locator)
        }
    }
}
