// Grand Line - native macOS app.
//
// R5-SEC-05 (full review #5): where the captain's GitHub token may go.
//
// `DocsSyncSource` downloads every file of the Playbook repo from whatever
// `download_url` the Contents API hands back, and it used to attach
// `Bearer <gh auth token>` to that request unconditionally. The URL is data
// from a response, not a literal this app wrote, and the token is the
// captain's whole `gh` login with every scope it was granted. So the token is
// attached only when `mayCarryToken(_:)` admits the URL: `https` to the API
// origin or `raw.githubusercontent.com`, on the default port, with no
// userinfo. `DocsSyncSource.applyAuth` asks before it even runs
// `gh auth token`.
//
// The review's other half was that a redirect off GitHub would carry the
// header along. Measured on macOS 26 against a real loopback server, it does
// not: Foundation drops `Authorization` on a redirect, to the same host or to
// another one. So there is no redirect guard here, because a guard whose test
// cannot fail is worse than none. `NetworkGateSelfTest
// .checkTheGitHubTokenStaysOnGitHub` asserts that Foundation behaviour
// instead, so an OS that starts forwarding the header fails the run by name
// rather than leaking quietly.

import Foundation

enum GitHubTokenScope {

    /// The only hosts the token is ever sent to. The API origin is where
    /// every literal URL in this app points, and `raw.githubusercontent.com`
    /// is where the Contents API's `download_url` points for a repo file.
    static let hosts: Set<String> = ["api.github.com", "raw.githubusercontent.com"]

    /// Whether a request to `url` may carry the token.
    static func mayCarryToken(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }
}
