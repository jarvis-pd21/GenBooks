# Security

GenBooks is an early local-first iOS project. It has no managed account or shared synchronization service. Provider keys live in iOS Keychain; optional online features send the data described in [Privacy](docs/privacy.md).

For a suspected vulnerability, use the repository's **Security → Report a vulnerability** option if available. Include the affected revision, a minimal reproduction using synthetic data, and the expected and actual behavior. If private reporting is unavailable, open an issue requesting a private reporting channel without exploit details, personal books, logs containing private context, or secrets. No response-time guarantee is currently offered.

Never post a real API key or signing credential. If one has been exposed, revoke it through its issuer; removing the text from a later commit does not revoke the credential or erase earlier public copies.

Security-sensitive changes include imported-file parsing, archive expansion limits, source trust boundaries, Keychain handling, app-group storage, and preservation of consumed revisions. Include failure cases and an independent review for changes to these boundaries. Test opt-ins and isolated simulator identities must not become production backdoors.
