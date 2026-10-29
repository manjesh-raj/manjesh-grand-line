// Grand Line - native macOS app.
//
// R4-UX-04 of the fourth full review (WF-13 of the first): a saved host can be
// tested without opening a session. Before this, the first sign of a typo in
// an address was a Console tab's exit-255 banner and a reconnect loop.
//
// The Test button in the Hosts side panel runs
//
//     ssh -o BatchMode=yes -o ConnectTimeout=5 [-J chain] [-p port] -- <dest> true
//
// through `Subprocess`, never a PTY, and reads the answer off ssh's exit code
// and stderr. Three rules keep it safe:
//
// - **Only the host's validated fields reach argv.** A host whose address,
//   username or jump host starts with a dash (`Host.unsafeFieldNames`, GL-08)
//   is refused before anything runs, and `--` still terminates option
//   parsing ahead of the destination.
// - **`BatchMode=yes` means ssh never prompts.** No password, passphrase or
//   host-key question can appear, because there is nothing to answer it. A
//   host key ssh has never seen fails as "not trusted yet" rather than being
//   accepted behind the captain's back - this app sets no
//   `StrictHostKeyChecking` override anywhere, and the test does not either.
// - **The saved key is not unlocked.** Materialising it is a Keychain read
//   that can raise Touch ID (GL-25), which is the wrong price for a probe. So
//   the test uses what plain `ssh` would (the agent, `~/.ssh/config`), and a
//   host whose saved key would have signed it in says so rather than
//   reading as "needs a password".
//
// Agent forwarding and port-forwarding rules are left out on purpose: a test
// that binds the host's local forwards would collide with a live session of
// the same host.
//
// Pure, apart from `run`, so the argv and the reading of each answer are
// asserted in CI's blocking lane (`ReviewFourUXModelSelfTest`).

import Foundation

enum HostConnectionTest {

    /// What a test found, in the words the panel shows.
    enum Outcome: Equatable {
        /// ssh signed in and ran `true`.
        case signedIn
        /// The server answered and refused the credentials ssh could offer
        /// without asking - so a Connect will prompt, or use the saved key.
        case needsCredentials(savedKey: Bool)
        /// The server answered with a host key this Mac has not trusted yet.
        case hostKeyUnknown
        /// Nothing usable answered.
        case unreachable(String)
        /// The test was not run: the host has an unsafe field, or no address.
        case refused(String)

        var text: String {
            switch self {
            case .signedIn:
                return "Reachable - signed in"
            case .needsCredentials(let savedKey):
                return savedKey ? "Reachable - Connect will use the saved key"
                    : "Reachable - asks for a password or key"
            case .hostKeyUnknown:
                return "Reachable - host key not trusted yet"
            case .unreachable(let reason):
                return "Unreachable - \(reason)"
            case .refused(let reason):
                return "Not tested - \(reason)"
            }
        }

        var tint: HelmTint {
            switch self {
            case .signedIn: return .good
            case .needsCredentials, .hostKeyUnknown: return .warn
            case .unreachable, .refused: return .critical
            }
        }
    }

    /// The seconds ssh waits for the TCP connection, and the whole run's cap.
    /// The cap is longer because a jump chain connects once per hop.
    static let connectTimeout = 5
    static let runTimeout: TimeInterval = 20

    /// The full argv for testing `host`, or the reason it cannot be tested.
    static func arguments(for host: Host, allHosts: [Host]) -> Result<[String], RefusalReason> {
        let unsafe = host.unsafeFieldNames
        guard unsafe.isEmpty else {
            return .failure(RefusalReason(text: "\(unsafe.joined(separator: " and ")) starts with \u{201C}-\u{201D}"))
        }
        guard !host.address.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(RefusalReason(text: "no address"))
        }
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)"]
        let chain = HostCatalog.proxyJumpChain(for: host, hosts: allHosts)
        // A hop resolved from another saved host was validated when that host
        // was saved, but the chain is read here, at run time, so it is checked
        // here too.
        guard !chain.contains(where: Host.hasUnsafeLeadingDash) else {
            return .failure(RefusalReason(text: "the jump chain has a hop starting with \u{201C}-\u{201D}"))
        }
        if !chain.isEmpty { args += ["-J", chain.joined(separator: ",")] }
        if host.port != 22 { args += ["-p", String(host.port)] }
        args += ["--", host.destination, "true"]
        return .success(args)
    }

    struct RefusalReason: Error, Equatable {
        let text: String
    }

    /// Read ssh's answer. `savedKey` is whether the host names a saved key,
    /// which the test deliberately does not unlock.
    static func classify(_ result: SubprocessResult, savedKey: Bool) -> Outcome {
        switch result.outcome {
        case .timedOut:
            return .unreachable("no answer in \(Int(runTimeout)) seconds")
        case .launchFailed:
            return .unreachable(result.stderr.isEmpty ? "ssh could not start" : result.stderr)
        case .exited:
            break
        }
        // 255 is ssh's own failure. Anything else is the remote command's
        // status, which means ssh got all the way in.
        guard result.status == 255 else { return .signedIn }
        let stderr = result.stderr.lowercased()
        if stderr.contains("permission denied") || stderr.contains("too many authentication failures") {
            return .needsCredentials(savedKey: savedKey)
        }
        if stderr.contains("host key verification failed") || stderr.contains("host key for") {
            return .hostKeyUnknown
        }
        if stderr.contains("could not resolve hostname") {
            return .unreachable("the address does not resolve")
        }
        if stderr.contains("connection refused") {
            return .unreachable("connection refused")
        }
        if stderr.contains("timed out") {
            return .unreachable("no answer in \(connectTimeout) seconds")
        }
        if stderr.contains("no route to host") || stderr.contains("network is unreachable") {
            return .unreachable("no route to the host")
        }
        let firstLine = result.stderr.split(separator: "\n").first.map(String.init) ?? ""
        return .unreachable(firstLine.isEmpty ? "ssh exited with status 255" : firstLine)
    }

    /// How a test is run. A seam so a suite can answer for ssh: a self-test
    /// process refuses to start the captain's own tools (`ExternalToolGuard`).
    typealias Runner = (_ arguments: [String], _ completion: @escaping (SubprocessResult) -> Void) -> Void

    static let subprocessRunner: Runner = { arguments, completion in
        Subprocess.runAsync(executable: HostCatalog.sshExecutable, arguments: arguments,
                            timeout: runTimeout, completion: completion)
    }

    /// Test `host`. `completion` runs on main, exactly once.
    static func run(_ host: Host, allHosts: [Host], runner: Runner = subprocessRunner,
                    completion: @escaping (Outcome) -> Void) {
        switch arguments(for: host, allHosts: allHosts) {
        case .failure(let reason):
            completion(.refused(reason.text))
        case .success(let args):
            let savedKey = host.keyID != nil
            runner(args) { result in completion(classify(result, savedKey: savedKey)) }
        }
    }
}
