// Manjesh Grand Line - native macOS app.
//
// The Whiteboard's *deterministic* half: a few lines of mermaid-lite text in,
// real Excalidraw elements out, with no model, no network and no subprocess.
//
// ## Why this exists beside the AI composer, rather than replacing it
//
// `WhiteboardDiagram.swift` already turns a plain-English description into a
// diagram, and it is the right tool when the captain knows the *shape* of the
// answer but not its parts ("a three-tier web app with a load balancer"). It
// is the wrong tool when he already knows exactly what connects to what: a
// round trip to `claude` for `A --> B` is seconds of waiting for something
// this app can compute in microseconds, and - worse - it is not repeatable,
// so the same five lines can come back laid out differently twice.
//
// So this file is the fast, predictable on-ramp: **it never calls
// `ClaudeOneShot`, never resolves `claude`, and never touches the network.**
// `WhiteboardDSLSelfTest` asserts that as a source guard, because the whole
// value proposition collapses the moment one call sneaks in - and a call that
// sneaks in still *works*, which is exactly why a behavioural test would not
// notice.
//
// ## What it reuses, and what it deliberately does not
//
// Reused: `WhiteboardDiagram.allowedTypes` and `.maxElements` (a generator
// that emitted a type the page refuses would be a silent dead end, so the
// invariant is asserted rather than assumed), and the page's own `loadScene`
// bridge call verbatim - **no change to `whiteboard.js` at all**, which is
// what keeps `Scripts/build-excalidraw-web.sh` out of this change entirely.
//
// Not reused: `WhiteboardDiagram.parse`. That function's job is defending
// against a *model* - arbitrary JSON of unknown shape, a frame with no
// `children`, a `javascript:` link. This generator's output is built field by
// field a few lines above the caller, from a closed set of element types, with
// no free-form values except the captain's own label text. Round-tripping it
// through JSON only to re-parse it would be ceremony, not safety. What is
// genuinely worth bounding - a pasted-in wall of DSL - is bounded here, at the
// input (`maxLines`) and at the output (`WhiteboardDiagram.maxElements`).
//
// ## The mode is picked, never inferred from the arrow spelling
//
// The obvious shortcut is to read `-->` as a flowchart edge and `->` as a
// sequence message. It is rejected on purpose: one character would then decide
// the entire shape of the output, silently, so a captain who typed `->` out of
// habit gets a lifeline diagram with no indication anything was interpreted.
// An explicit mode picker (which is also what the captain's own reviewed
// mockup shows) removes the trap rather than making it load-bearing - and with
// the mode already known, **each mode can accept both spellings**, so there is
// nothing left to get wrong.
//
// The one place the two spellings do differ is *inside* sequence mode, where
// `-->` is a dashed reply and `->` a solid call. That is mermaid's own
// convention, it is what makes a request/response postmortem readable, and it
// is a styling difference within one element type rather than a mode switch.

import Foundation

/// Where a parse failed, in the captain's own coordinates.
///
/// The line number is the whole point of a local parser: a model can only
/// answer "that didn't work", while this can answer "line 4 doesn't have an
/// arrow in it". A `nil` line means the problem is with the input as a whole
/// (it is empty, or it is too big) rather than with any one line.
struct DiagramDSLError: Error, CustomStringConvertible {
    let line: Int?
    let message: String

    var description: String {
        guard let line else { return message }
        return "line \(line): \(message)"
    }
}

/// One preset from the component library.
///
/// A component is a styled `rectangle` with a bound label, never an image:
/// `image`/`embeddable`/`iframe` are not in `WhiteboardDiagram.allowedTypes`
/// (an image skeleton needs a `fileId` for a file already in the scene, and
/// the other two exist to load a remote URL the page's CSP blocks), so an icon
/// set would have to be a second asset pipeline for something the canvas
/// cannot draw. The emoji in the label is the icon, and it survives export,
/// copy/paste and Excalidraw's own editing for free.
///
/// The colours are literal hexes rather than `HelmTint`s, which is the correct
/// exception rather than an oversight: these are painted *inside* Excalidraw's
/// own canvas by Excalidraw itself, not by this app's chrome, and every value
/// is one of Excalidraw's own default swatches (verified present in the
/// vendored bundle). A shape drawn from this palette is indistinguishable from
/// one the captain drew by hand with the canvas's own colour picker - which is
/// the point, since the output is meant to be hand-editable afterwards. They
/// now come from `DiagramComponentRole` rather than from a per-component
/// switch; see that type for why the hue is by role and not by vendor.
///
/// **The library is SRE/DevOps-shaped, and AWS-heavy on purpose.** It shipped
/// as seven generic shapes in one flat row, which is enough to sketch a
/// three-box diagram and not enough to draw the captain's actual work. The set
/// is organised into `DiagramComponentCategory` drawers and reached through the
/// popover's Components drop-down; the original seven are unchanged in keyword,
/// alias, title, emoji and colour, and are re-listed under `Common`.
enum DiagramComponent: String, CaseIterable {
    case server
    case k8sPod
    case database
    case queue
    case loadBalancer
    case secretStore
    case actor
    case ec2
    case lambda
    case ecs
    case eks
    case alb
    case apiGateway
    case cloudFront
    case route53
    case s3
    case rds
    case dynamoDB
    case elastiCache
    case sqs
    case sns
    case eventBridge
    case kinesis
    case stepFunctions
    case iam
    case secretsManager
    case cloudWatch
    case vpc
    case deployment
    case k8sService
    case ingress
    case configMap
    case namespace
    case statefulSet
    case cronJob
    case node
    case cdn
    case dns
    case firewall
    case proxy
    case vpn
    case internet
    case subnet
    case cache
    case objectStore
    case dataWarehouse
    case searchIndex
    case stream
    case metrics
    case logs
    case traces
    case dashboard
    case alert
    case onCall
    case repo
    case pipeline
    case registry
    case containerImage
    case iac
    case certificate
    case auth
    case waf

    /// One row of the component table: everything about a component except
    /// how it is painted, which comes from its `role`.
    ///
    /// **One table, not six parallel `switch`es.** The library was seven
    /// components and six switches over them; at 62 it is one line per
    /// component, which is the difference between a reviewable diff and a
    /// place where a case can be added to five of the six by accident.
    struct Spec {
        let keyword: String
        let aliases: [String]
        let title: String
        let emoji: String
        let role: DiagramComponentRole
    }

    var spec: Spec {
        switch self {
        case .server: return Spec(keyword: "server", aliases: ["server", "svc", "service", "app"], title: "Server", emoji: "\u{1F5A5}\u{FE0F}", role: .compute)
        case .k8sPod: return Spec(keyword: "k8s", aliases: ["k8s", "pod", "kube"], title: "K8s Pod", emoji: "\u{2638}\u{FE0F}", role: .container)
        case .database: return Spec(keyword: "db", aliases: ["db", "database", "store"], title: "Database", emoji: "\u{1F5C4}\u{FE0F}", role: .data)
        case .queue: return Spec(keyword: "queue", aliases: ["queue", "mq", "topic"], title: "Queue", emoji: "\u{1F4EC}", role: .messaging)
        case .loadBalancer: return Spec(keyword: "lb", aliases: ["lb", "loadbalancer", "load_balancer"], title: "Load balancer", emoji: "\u{2696}\u{FE0F}", role: .routing)
        case .secretStore: return Spec(keyword: "secrets", aliases: ["secrets", "secret", "vault"], title: "Secret store", emoji: "\u{1F510}", role: .security)
        case .actor: return Spec(keyword: "actor", aliases: ["actor", "user", "person", "client"], title: "Actor", emoji: "\u{1F464}", role: .person)
        case .ec2: return Spec(keyword: "ec2", aliases: ["ec2", "instance"], title: "EC2", emoji: "\u{1F5A5}\u{FE0F}", role: .compute)
        case .lambda: return Spec(keyword: "lambda", aliases: ["lambda", "fn", "function"], title: "Lambda", emoji: "\u{26A1}", role: .compute)
        case .ecs: return Spec(keyword: "ecs", aliases: ["ecs", "fargate"], title: "ECS / Fargate", emoji: "\u{1F4E6}", role: .container)
        case .eks: return Spec(keyword: "eks", aliases: ["eks"], title: "EKS", emoji: "\u{2638}\u{FE0F}", role: .container)
        case .alb: return Spec(keyword: "alb", aliases: ["alb", "elb", "nlb"], title: "ALB / ELB", emoji: "\u{2696}\u{FE0F}", role: .routing)
        case .apiGateway: return Spec(keyword: "apigw", aliases: ["apigw", "apigateway", "api_gateway"], title: "API Gateway", emoji: "\u{1F6AA}", role: .routing)
        case .cloudFront: return Spec(keyword: "cloudfront", aliases: ["cloudfront"], title: "CloudFront", emoji: "\u{1F30D}", role: .routing)
        case .route53: return Spec(keyword: "route53", aliases: ["route53", "r53"], title: "Route 53", emoji: "\u{1F9ED}", role: .routing)
        case .s3: return Spec(keyword: "s3", aliases: ["s3", "bucket"], title: "S3", emoji: "\u{1FAA3}", role: .data)
        case .rds: return Spec(keyword: "rds", aliases: ["rds", "aurora"], title: "RDS / Aurora", emoji: "\u{1F5C3}\u{FE0F}", role: .data)
        case .dynamoDB: return Spec(keyword: "dynamodb", aliases: ["dynamodb", "ddb", "dynamo"], title: "DynamoDB", emoji: "\u{26A1}", role: .data)
        case .elastiCache: return Spec(keyword: "elasticache", aliases: ["elasticache"], title: "ElastiCache", emoji: "\u{1F9CA}", role: .data)
        case .sqs: return Spec(keyword: "sqs", aliases: ["sqs"], title: "SQS", emoji: "\u{1F4EC}", role: .messaging)
        case .sns: return Spec(keyword: "sns", aliases: ["sns"], title: "SNS", emoji: "\u{1F4E3}", role: .messaging)
        case .eventBridge: return Spec(keyword: "eventbridge", aliases: ["eventbridge", "events"], title: "EventBridge", emoji: "\u{1F500}", role: .messaging)
        case .kinesis: return Spec(keyword: "kinesis", aliases: ["kinesis"], title: "Kinesis", emoji: "\u{1F30A}", role: .messaging)
        case .stepFunctions: return Spec(keyword: "stepfunctions", aliases: ["stepfunctions", "sfn"], title: "Step Functions", emoji: "\u{1FA9C}", role: .messaging)
        case .iam: return Spec(keyword: "iam", aliases: ["iam", "role"], title: "IAM", emoji: "\u{1F6C2}", role: .security)
        case .secretsManager: return Spec(keyword: "secretsmanager", aliases: ["secretsmanager", "asm"], title: "Secrets Manager", emoji: "\u{1F511}", role: .security)
        case .cloudWatch: return Spec(keyword: "cloudwatch", aliases: ["cloudwatch", "cw"], title: "CloudWatch", emoji: "\u{1F453}", role: .observability)
        case .vpc: return Spec(keyword: "vpc", aliases: ["vpc"], title: "VPC", emoji: "\u{1F3E2}", role: .edge)
        case .deployment: return Spec(keyword: "deploy", aliases: ["deploy", "deployment"], title: "Deployment", emoji: "\u{1F680}", role: .container)
        case .k8sService: return Spec(keyword: "k8ssvc", aliases: ["k8ssvc", "clusterip", "kubesvc"], title: "Service (k8s)", emoji: "\u{1F517}", role: .routing)
        case .ingress: return Spec(keyword: "ingress", aliases: ["ingress"], title: "Ingress", emoji: "\u{1F6AA}", role: .routing)
        case .configMap: return Spec(keyword: "configmap", aliases: ["configmap", "cm", "config"], title: "ConfigMap", emoji: "\u{1F4C4}", role: .data)
        case .namespace: return Spec(keyword: "namespace", aliases: ["namespace", "ns"], title: "Namespace", emoji: "\u{1F5C2}\u{FE0F}", role: .edge)
        case .statefulSet: return Spec(keyword: "statefulset", aliases: ["statefulset", "sts"], title: "StatefulSet", emoji: "\u{1F9F1}", role: .container)
        case .cronJob: return Spec(keyword: "cronjob", aliases: ["cronjob", "cron", "job"], title: "CronJob", emoji: "\u{23F0}", role: .container)
        case .node: return Spec(keyword: "node", aliases: ["node", "worker"], title: "Node", emoji: "\u{1F5A5}\u{FE0F}", role: .compute)
        case .cdn: return Spec(keyword: "cdn", aliases: ["cdn", "edge"], title: "CDN", emoji: "\u{1F30D}", role: .routing)
        case .dns: return Spec(keyword: "dns", aliases: ["dns"], title: "DNS", emoji: "\u{1F9ED}", role: .routing)
        case .firewall: return Spec(keyword: "firewall", aliases: ["firewall", "fw", "sg", "securitygroup"], title: "Firewall / SG", emoji: "\u{1F9F1}", role: .security)
        case .proxy: return Spec(keyword: "proxy", aliases: ["proxy", "nginx", "envoy"], title: "Proxy", emoji: "\u{1F504}", role: .routing)
        case .vpn: return Spec(keyword: "vpn", aliases: ["vpn", "tunnel"], title: "VPN", emoji: "\u{1F576}\u{FE0F}", role: .security)
        case .internet: return Spec(keyword: "internet", aliases: ["internet", "public", "www"], title: "Internet", emoji: "\u{1F310}", role: .edge)
        case .subnet: return Spec(keyword: "subnet", aliases: ["subnet"], title: "Subnet", emoji: "\u{1F5FA}\u{FE0F}", role: .edge)
        case .cache: return Spec(keyword: "cache", aliases: ["cache", "redis", "memcached"], title: "Cache", emoji: "\u{1F9CA}", role: .data)
        case .objectStore: return Spec(keyword: "blob", aliases: ["blob", "objectstore", "objectstorage"], title: "Object storage", emoji: "\u{1FAA3}", role: .data)
        case .dataWarehouse: return Spec(keyword: "warehouse", aliases: ["warehouse", "dwh", "redshift", "snowflake"], title: "Data warehouse", emoji: "\u{1F3ED}", role: .data)
        case .searchIndex: return Spec(keyword: "search", aliases: ["search", "elasticsearch", "opensearch", "index"], title: "Search index", emoji: "\u{1F50D}", role: .data)
        case .stream: return Spec(keyword: "stream", aliases: ["stream", "kafka"], title: "Stream / Kafka", emoji: "\u{1F30A}", role: .messaging)
        case .metrics: return Spec(keyword: "metrics", aliases: ["metrics", "metric", "prometheus"], title: "Metrics", emoji: "\u{1F4C8}", role: .observability)
        case .logs: return Spec(keyword: "logs", aliases: ["logs", "log", "loki"], title: "Logs", emoji: "\u{1F4DC}", role: .observability)
        case .traces: return Spec(keyword: "traces", aliases: ["traces", "trace", "tracing", "otel"], title: "Traces", emoji: "\u{1F9F5}", role: .observability)
        case .dashboard: return Spec(keyword: "dashboard", aliases: ["dashboard", "grafana"], title: "Dashboard", emoji: "\u{1F4CA}", role: .observability)
        case .alert: return Spec(keyword: "alert", aliases: ["alert", "alarm", "alerting"], title: "Alert", emoji: "\u{1F6A8}", role: .observability)
        case .onCall: return Spec(keyword: "oncall", aliases: ["oncall", "pager", "pagerduty"], title: "On-call", emoji: "\u{1F4DF}", role: .observability)
        case .repo: return Spec(keyword: "repo", aliases: ["repo", "git", "github", "gitlab"], title: "Git repo", emoji: "\u{1F4D3}", role: .delivery)
        case .pipeline: return Spec(keyword: "pipeline", aliases: ["pipeline", "ci", "cd", "cicd"], title: "Pipeline", emoji: "\u{1F6E0}\u{FE0F}", role: .delivery)
        case .registry: return Spec(keyword: "registry", aliases: ["registry", "ecr", "dockerhub"], title: "Image registry", emoji: "\u{1F4E6}", role: .delivery)
        case .containerImage: return Spec(keyword: "container", aliases: ["container", "containerimage", "docker"], title: "Container image", emoji: "\u{1F433}", role: .container)
        case .iac: return Spec(keyword: "terraform", aliases: ["terraform", "iac", "tf", "cloudformation"], title: "Terraform / IaC", emoji: "\u{1F4D0}", role: .delivery)
        case .certificate: return Spec(keyword: "cert", aliases: ["cert", "tls", "ssl", "certificate"], title: "TLS certificate", emoji: "\u{1F4DC}", role: .security)
        case .auth: return Spec(keyword: "auth", aliases: ["auth", "sso", "oidc", "idp"], title: "Auth / SSO", emoji: "\u{1F6C2}", role: .security)
        case .waf: return Spec(keyword: "waf", aliases: ["waf"], title: "WAF", emoji: "\u{1F6E1}\u{FE0F}", role: .security)
        }
    }

    /// The word the DSL uses: `db(Postgres)`.
    var keyword: String { spec.keyword }

    /// Spellings that mean the same thing. Forgiving on input costs nothing and
    /// removes the one failure a typed-node syntax invites: remembering whether
    /// it was `db` or `database`.
    ///
    /// Every alias across the whole library must be unique - `named` resolves
    /// the first owner and would leave the other silently unreachable, which is
    /// what `WhiteboardDSLSelfTest` asserts. One existing alias moved when the
    /// library grew: `ingress` belonged to `loadBalancer` and now names the
    /// Kubernetes `Ingress` component, which is the more specific answer and
    /// renders in the identical routing hue - so `ingress(x)` draws the same
    /// purple box it always did, only labelled "Ingress" rather than "Load
    /// balancer" when written bare.
    var aliases: [String] { spec.aliases }

    /// What the picker says, and what an inserted component is called when the
    /// captain gives it no name of its own.
    var title: String { spec.title }

    var emoji: String { spec.emoji }

    var role: DiagramComponentRole { spec.role }

    var strokeColor: String { role.strokeColor }

    var backgroundColor: String { role.backgroundColor }

    /// Every drawer this component appears in. A component may be in more than
    /// one - see `DiagramComponentCategory`.
    var categories: [DiagramComponentCategory] {
        DiagramComponentCategory.allCases.filter { $0.components.contains(self) }
    }

    static func named(_ word: String) -> DiagramComponent? {
        let needle = word.lowercased()
        return allCases.first { $0.aliases.contains(needle) }
    }

    /// The keywords worth naming when the captain typed one this does not know.
    ///
    /// Listing all 62 would be a wall of text in a one-line error, so this
    /// answers with near-misses when there are any (a prefix match either way
    /// catches `postgre`, `lamda`, `dynamo`) and falls back to the `Common`
    /// drawer plus a pointer at the drop-down, which is where the rest live.
    static func suggestions(for word: String) -> String {
        let needle = word.lowercased()
        guard !needle.isEmpty else { return commonKeywords }
        let near = allCases.filter { component in
            component.aliases.contains { $0.hasPrefix(needle) || needle.hasPrefix($0) }
        }
        guard !near.isEmpty else { return commonKeywords }
        return near.map(\.keyword).joined(separator: ", ")
    }

    private static var commonKeywords: String {
        DiagramComponentCategory.common.components.map(\.keyword).joined(separator: ", ")
    }
}

/// What a component *does*, which is what decides how it is drawn.
///
/// **Colour is by role, never by vendor**, and that is a deliberate reading
/// decision rather than a shortcut: a database is green whether it is RDS or a
/// Postgres box, a queue is amber whether it is SQS or RabbitMQ. Hue-by-vendor
/// would render an all-AWS diagram monochrome and tell the reader nothing,
/// while hue-by-role means a glance at any diagram - mixed-cloud or not -
/// separates the request path from the state from the plumbing.
///
/// Every hex below is one of Excalidraw's own default swatches, verified
/// present in the vendored bundle (`Vendor/Excalidraw/web/whiteboard.js`) -
/// the invariant `DiagramComponent`'s own header states, unchanged. The seven
/// original components keep their exact previous pair: this mapping was chosen
/// so `server`/`k8sPod`/`database`/`queue`/`loadBalancer`/`secretStore`/`actor`
/// resolve to the values they always had, so promoting them to roles is a
/// refactor with no visual change.
enum DiagramComponentRole {
    /// Anything that runs code on request.
    case compute
    /// A containerised workload or the thing that schedules one.
    case container
    /// Anything that holds state.
    case data
    /// Anything that carries work between two other things.
    case messaging
    /// Anything that decides where a request goes next.
    case routing
    /// Anything that grants, withholds or proves access.
    case security
    /// Anything that watches the system rather than serving it.
    case observability
    /// Anything on the path from a commit to production.
    case delivery
    /// A boundary rather than a component - a VPC, a subnet, the internet.
    case edge
    /// A human. The one role with no box fill, on purpose.
    case person

    var strokeColor: String {
        switch self {
        case .compute: return "#1971c2"
        case .container: return "#0c8599"
        case .data: return "#2f9e44"
        case .messaging: return "#f08c00"
        case .routing: return "#9c36b5"
        case .security: return "#e03131"
        case .observability: return "#0ca678"
        case .delivery: return "#c2255c"
        case .edge: return "#343a40"
        case .person: return "#1e1e1e"
        }
    }

    /// `"transparent"` is Excalidraw's own sentinel for "no fill", not a value
    /// this file invented.
    var backgroundColor: String {
        switch self {
        case .compute: return "#a5d8ff"
        case .container: return "#99e9f2"
        case .data: return "#b2f2bb"
        case .messaging: return "#ffec99"
        case .routing: return "#d0bfff"
        case .security: return "#ffc9c9"
        case .observability: return "#96f2d7"
        case .delivery: return "#fcc2d7"
        case .edge: return "#e9ecef"
        case .person: return "transparent"
        }
    }
}

/// A drawer of the component drop-down.
///
/// **A component may appear in more than one category, on purpose.** This is a
/// picker, so being findable in two plausible places is a feature rather than
/// an ambiguity - an EKS cluster is genuinely both an AWS service and a
/// Kubernetes thing, and someone reaching for it will look in whichever they
/// were already thinking about. `Common` re-lists the seven shapes the palette
/// shipped with so the fastest path to a generic box stays one hop away.
///
/// `WhiteboardDSLSelfTest` asserts every `DiagramComponent` appears in at least
/// one category: a component reachable only by typing its keyword is one the
/// captain has no way to discover.
enum DiagramComponentCategory: String, CaseIterable {
    case common
    case aws
    case kubernetes
    case network
    case data
    case messaging
    case observability
    case delivery
    case security

    var title: String {
        switch self {
        case .common: return "Common"
        case .aws: return "AWS"
        case .kubernetes: return "Kubernetes"
        case .network: return "Network & edge"
        case .data: return "Data & storage"
        case .messaging: return "Messaging & events"
        case .observability: return "Observability"
        case .delivery: return "CI/CD & delivery"
        case .security: return "Security & identity"
        }
    }

    var emoji: String {
        switch self {
        case .common: return "\u{2B50}"
        case .aws: return "\u{2601}\u{FE0F}"
        case .kubernetes: return "\u{2638}\u{FE0F}"
        case .network: return "\u{1F310}"
        case .data: return "\u{1F5C4}\u{FE0F}"
        case .messaging: return "\u{1F4EC}"
        case .observability: return "\u{1F4C8}"
        case .delivery: return "\u{1F6E0}\u{FE0F}"
        case .security: return "\u{1F510}"
        }
    }

    var components: [DiagramComponent] {
        switch self {
        case .common: return [.server, .k8sPod, .database, .queue, .loadBalancer, .secretStore, .actor]
        case .aws: return [.ec2, .lambda, .ecs, .eks, .alb, .apiGateway, .cloudFront, .route53, .s3, .rds, .dynamoDB, .elastiCache, .sqs, .sns, .eventBridge, .kinesis, .stepFunctions, .iam, .secretsManager, .cloudWatch, .vpc]
        case .kubernetes: return [.k8sPod, .deployment, .statefulSet, .cronJob, .k8sService, .ingress, .configMap, .namespace, .node, .eks]
        case .network: return [.loadBalancer, .alb, .apiGateway, .cdn, .dns, .proxy, .firewall, .vpn, .vpc, .subnet, .internet]
        case .data: return [.database, .rds, .dynamoDB, .s3, .objectStore, .cache, .elastiCache, .dataWarehouse, .searchIndex]
        case .messaging: return [.queue, .sqs, .sns, .eventBridge, .kinesis, .stream, .stepFunctions]
        case .observability: return [.metrics, .logs, .traces, .dashboard, .alert, .onCall, .cloudWatch]
        case .delivery: return [.repo, .pipeline, .registry, .containerImage, .iac]
        case .security: return [.secretStore, .secretsManager, .iam, .auth, .certificate, .waf, .firewall]
        }
    }
}

enum DiagramDSL {

    // MARK: Shape of the output

    enum Mode: String, CaseIterable {
        case flowchart
        case sequence

        var title: String {
            switch self {
            case .flowchart: return "Flowchart"
            case .sequence: return "Sequence"
            }
        }

        var placeholder: String {
            switch self {
            case .flowchart:
                return "Client --> LB\nLB --> ServiceA\nServiceA --> db(Postgres): query"
            case .sequence:
                return "Client -> Server: request\nServer -> DB: query\nDB --> Server: rows"
            }
        }
    }

    /// A generated diagram: the skeleton the page loads, plus what to say about
    /// it before the captain commits to inserting it.
    struct Diagram {
        let elements: [[String: Any]]
        /// "4 boxes, 3 arrows" - shown live as the captain types, which is the
        /// affordance a deterministic parser can offer and a model cannot.
        let summary: String
        /// Every box, in layout order, for the preview. Derived from the same
        /// pass that built `elements` so the two cannot disagree.
        let boxes: [PreviewBox]
        let connectors: [PreviewConnector]
    }

    /// Geometry for the native preview. Deliberately a flat value type rather
    /// than "re-read the skeleton dictionaries": the preview would then be
    /// parsing this file's own output back out of `Any`, which is both slower
    /// and a second place to get the field names right.
    struct PreviewBox {
        let x: Double, y: Double, width: Double, height: Double
        let label: String
        let strokeHex: String
        let fillHex: String
    }

    struct PreviewConnector {
        let x1: Double, y1: Double, x2: Double, y2: Double
        let label: String
        let dashed: Bool
        /// A lifeline is drawn as a plain rule rather than an arrow.
        let isLifeline: Bool
    }

    // MARK: Limits

    /// An input bound, separate from the output bound below. A pasted wall of
    /// text should be refused for what it *is* rather than after the layout
    /// pass has already run over it.
    static let maxLines = 200

    /// The most nodes one diagram may name. Past this the layout stops being
    /// readable long before it stops being possible, and saying so is more
    /// useful than drawing it.
    static let maxNodes = 60

    // MARK: Geometry

    static let nodeHeight: Double = 60
    static let nodeMinWidth: Double = 120
    static let nodeMaxWidth: Double = 280
    /// `formatRules` asks a model for "at least 60px of gap between shapes so
    /// arrows and labels have room"; the same number is right for the same
    /// reason when this file is the one laying out.
    static let columnGap: Double = 60
    static let rankGap: Double = 90

    static let actorGap: Double = 60
    static let lifelineTopGap: Double = 50
    static let messageSpacing: Double = 60
    static let lifelineTailGap: Double = 50
    /// A message from an actor to itself has no second lifeline to land on, so
    /// it is drawn as a short stub to the right. Mermaid draws a loop; a stub
    /// is the honest approximation in a format with no curve primitive here,
    /// and it still reads as "this actor did something to itself".
    static let selfMessageWidth: Double = 64

    static let fontSize: Double = 16
    static let labelFontSize: Double = 14

    /// Roughly how wide a character is at `fontSize`, for auto-sizing a box to
    /// its label. An estimate on purpose: this is laying out for Excalidraw's
    /// hand-drawn font, which this process cannot measure, and being a little
    /// generous costs nothing while being tight clips text.
    static let charWidth: Double = 9.5

    static func boxWidth(for label: String) -> Double {
        let ideal = Double(label.count) * charWidth + 34
        return min(nodeMaxWidth, max(nodeMinWidth, ideal.rounded()))
    }

    // MARK: Entry point

    /// Parses and lays out in one pass. Pure: same text in, byte-identical
    /// elements out, every time.
    static func build(_ text: String, mode: Mode) -> Result<Diagram, DiagramDSLError> {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count <= maxLines else {
            return .failure(DiagramDSLError(
                line: nil,
                message: "that's \(lines.count) lines, past the \(maxLines)-line limit. Try splitting it into smaller diagrams."))
        }
        switch mode {
        case .flowchart: return buildFlowchart(lines)
        case .sequence: return buildSequence(lines)
        }
    }

    /// A single component from the palette, ready to drop on the board.
    ///
    /// `index` cascades successive inserts so clicking "Database" twice does
    /// not stack two boxes in exactly the same place. It deliberately knows
    /// nothing about what is already on the board: reading the canvas back
    /// first would put an async round trip in front of a palette click, and
    /// the page scrolls to whatever it loads anyway - so the captain sees the
    /// new shape and drags it where they want, which they were going to do
    /// regardless.
    static func component(_ component: DiagramComponent, index: Int) -> Diagram {
        let label = "\(component.emoji) \(component.title)"
        let step: Double = 28
        let x = (Double(index % 8) * step).rounded()
        let y = (Double(index % 8) * step).rounded()
        let width = boxWidth(for: label)
        let box = PreviewBox(x: x, y: y, width: width, height: nodeHeight,
                             label: label,
                             strokeHex: component.strokeColor,
                             fillHex: component.backgroundColor)
        return Diagram(elements: [shapeElement(id: "component-\(component.keyword)-\(index)", box: box)],
                       summary: "1 box",
                       boxes: [box],
                       connectors: [])
    }

    // MARK: Lexing

    /// One statement's worth of text, or `nil` for a line that carries none.
    ///
    /// `#` and `//` both start a comment, because a captain writing a diagram
    /// has muscle memory from one or the other and neither is a plausible
    /// beginning for a node name.
    static func strippedStatement(_ raw: String) -> String? {
        var line = raw
        if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
        if let slashes = line.range(of: "//") { line = String(line[line.startIndex..<slashes.lowerBound]) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Splits a statement into its node segments and the arrows between them.
    ///
    /// `-->` is matched before `->`, or the shorter token would consume the
    /// tail of the longer one and leave a stray `-` glued to a node name. A
    /// hyphen inside a name (`api-gateway`) is untouched, because neither token
    /// matches `-g`.
    struct ArrowSplit {
        /// `count == arrows.count + 1` for any statement with an arrow in it.
        let segments: [String]
        /// `true` for `-->`. Only sequence mode reads this - see this file's
        /// header for why flowchart mode treats both spellings as one edge.
        let arrows: [Bool]
    }

    static func splitOnArrows(_ statement: String) -> ArrowSplit {
        var segments: [String] = []
        var arrows: [Bool] = []
        var current = ""
        let chars = Array(statement)
        var i = 0
        while i < chars.count {
            if i + 2 < chars.count, chars[i] == "-", chars[i + 1] == "-", chars[i + 2] == ">" {
                segments.append(current)
                arrows.append(true)
                current = ""
                i += 3
            } else if i + 1 < chars.count, chars[i] == "-", chars[i + 1] == ">" {
                segments.append(current)
                arrows.append(false)
                current = ""
                i += 2
            } else {
                current.append(chars[i])
                i += 1
            }
        }
        segments.append(current)
        return ArrowSplit(segments: segments.map { $0.trimmingCharacters(in: .whitespaces) },
                          arrows: arrows)
    }

    /// Peels a trailing `: label` off a statement.
    ///
    /// Split on the **first** colon, before any arrow splitting: a label is
    /// free text and may legitimately contain an arrow (`A --> B: maps a->b`),
    /// so tokenizing arrows first would tear the label apart. Splitting on the
    /// first colon also leaves a later one alone, which is what keeps a URL in
    /// a label intact.
    static func splitLabel(_ statement: String) -> (head: String, label: String?) {
        guard let colon = statement.firstIndex(of: ":") else { return (statement, nil) }
        let head = String(statement[statement.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let label = String(statement[statement.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (head, label.isEmpty ? nil : label)
    }

    /// A node segment: either a bare name, or `kind(Name)` naming a component.
    ///
    /// The node's identity is the name **inside** the parentheses, so
    /// `db(Postgres)` on one line and a bare `Postgres` on the next are the
    /// same node. One namespace rather than two (mermaid's `A[Label]` keeps an
    /// id and a caption apart; for a DSL this small, a second namespace is one
    /// more thing to get wrong for no gain).
    struct NodeToken {
        let name: String
        let kind: DiagramComponent?
    }

    static func parseNode(_ segment: String, line: Int) -> Result<NodeToken, DiagramDSLError> {
        let text = segment.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            return .failure(DiagramDSLError(line: line, message: "there's an arrow with nothing on one side of it."))
        }
        guard let open = text.firstIndex(of: "(") else {
            guard !text.contains(")") else {
                return .failure(DiagramDSLError(line: line, message: "\"\(text)\" has a closing bracket with no opening one."))
            }
            return .success(NodeToken(name: text, kind: nil))
        }
        guard text.hasSuffix(")") else {
            return .failure(DiagramDSLError(line: line, message: "\"\(text)\" is missing its closing bracket."))
        }
        let keyword = String(text[text.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        let inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else {
            return .failure(DiagramDSLError(line: line, message: "\"\(text)\" has no name inside the brackets."))
        }
        guard let kind = DiagramComponent.named(keyword) else {
            return .failure(DiagramDSLError(
                line: line,
                message: "\"\(keyword)\" isn't a component. Did you mean: \(DiagramComponent.suggestions(for: keyword))? The full set is in the Components drop-down."))
        }
        return .success(NodeToken(name: inner, kind: kind))
    }

    // MARK: Flowchart

    private struct FlowEdge {
        let from: Int
        let to: Int
        let label: String?
    }

    /// Layout: rank by longest path from a source, then one row per rank.
    ///
    /// Kahn's algorithm over the DAG, taking `rank[v] = max(rank[v], rank[u]+1)`
    /// so a node sits below *every* one of its inputs rather than just the
    /// first one that reached it. Rows are laid out top to bottom (mermaid's
    /// own `graph TD` default, and the direction a fan-out reads best in), and
    /// each row is centred against the widest row so the diagram has an axis.
    ///
    /// A cycle has no topological order at all, and refusing to draw one would
    /// be the wrong answer for a retry loop - which is a perfectly ordinary
    /// thing to diagram. So anything Kahn leaves unranked is placed afterwards,
    /// in first-appearance order, one rank below its highest already-ranked
    /// input (or after everything else, if none of its inputs were ranked).
    /// Deterministic, and the back-edge simply points upward.
    private static func buildFlowchart(_ lines: [String]) -> Result<Diagram, DiagramDSLError> {
        var names: [String] = []
        var index: [String: Int] = [:]
        var kinds: [Int: DiagramComponent] = [:]
        var edges: [FlowEdge] = []

        func intern(_ token: NodeToken) -> Int {
            let id: Int
            if let existing = index[token.name] {
                id = existing
            } else {
                id = names.count
                names.append(token.name)
                index[token.name] = id
            }
            // First explicit typing wins: a later `db(API)` after `server(API)`
            // is far likelier a slip than a change of mind, and "the
            // declaration decides" stays stable as lines are appended to the
            // bottom of a growing diagram.
            if let kind = token.kind, kinds[id] == nil { kinds[id] = kind }
            return id
        }

        for (offset, raw) in lines.enumerated() {
            let lineNumber = offset + 1
            guard let statement = strippedStatement(raw) else { continue }
            let (head, label) = splitLabel(statement)
            let split = splitOnArrows(head)

            guard !split.arrows.isEmpty else {
                // A lone node is a legal statement: it is how a diagram
                // declares a component's type up front, or names something
                // nothing points at yet.
                switch parseNode(head, line: lineNumber) {
                case .failure(let error): return .failure(error)
                case .success(let token): _ = intern(token)
                }
                continue
            }

            var previous: Int?
            for segment in split.segments {
                switch parseNode(segment, line: lineNumber) {
                case .failure(let error): return .failure(error)
                case .success(let token):
                    let id = intern(token)
                    if let from = previous {
                        guard from != id else {
                            return .failure(DiagramDSLError(
                                line: lineNumber,
                                message: "\"\(token.name)\" points at itself. A flowchart arrow needs two different boxes."))
                        }
                        // A chain (`A --> B --> C`) is two edges, and a label on
                        // the line applies to each of them. For the ordinary
                        // two-node line - which is almost every line - that is
                        // simply "the edge's label".
                        edges.append(FlowEdge(from: from, to: id, label: label))
                    }
                    previous = id
                }
            }
            guard names.count <= maxNodes else {
                return .failure(DiagramDSLError(
                    line: lineNumber,
                    message: "that's more than \(maxNodes) boxes. Try splitting it into smaller diagrams."))
            }
        }

        guard !names.isEmpty else {
            return .failure(DiagramDSLError(
                line: nil,
                message: "nothing to draw yet. Try a line like \"Client --> Server\"."))
        }

        let ranks = rankNodes(count: names.count, edges: edges)
        // Labels first, widths from the labels, layout from the widths - in
        // that order. A typed node's label carries an emoji, so measuring the
        // bare name and widening the box afterwards would lay the row out
        // against a width the box does not end up having: the row would sit
        // slightly off its own centre line, and two typed siblings could eat
        // into the gap the arrows need.
        let labels: [String] = names.indices.map { id in
            kinds[id].map { "\($0.emoji) \(names[id])" } ?? names[id]
        }
        let widths = labels.map { boxWidth(for: $0) }

        var rows: [[Int]] = Array(repeating: [], count: (ranks.max() ?? 0) + 1)
        for id in names.indices { rows[ranks[id]].append(id) }

        let rowWidths = rows.map { row in
            row.reduce(0.0) { $0 + widths[$1] } + Double(max(0, row.count - 1)) * columnGap
        }
        let widest = rowWidths.max() ?? 0

        var frames: [CGRect] = Array(repeating: .zero, count: names.count)
        for (rank, row) in rows.enumerated() {
            var x = ((widest - rowWidths[rank]) / 2).rounded()
            let y = (Double(rank) * (nodeHeight + rankGap)).rounded()
            for id in row {
                frames[id] = CGRect(x: x, y: y, width: widths[id], height: nodeHeight)
                x += widths[id] + columnGap
            }
        }

        var boxes: [PreviewBox] = []
        var elements: [[String: Any]] = []
        for id in names.indices {
            let kind = kinds[id]
            let box = PreviewBox(x: frames[id].minX, y: frames[id].minY,
                                 width: frames[id].width, height: nodeHeight,
                                 label: labels[id],
                                 strokeHex: kind?.strokeColor ?? defaultStroke,
                                 fillHex: kind?.backgroundColor ?? "transparent")
            boxes.append(box)
            elements.append(shapeElement(id: "n\(id)", box: box))
        }

        var connectors: [PreviewConnector] = []
        for edge in edges {
            let from = frames[edge.from], to = frames[edge.to]
            let x1 = (from.midX).rounded(), y1 = from.maxY
            let x2 = (to.midX).rounded(), y2 = to.minY
            connectors.append(PreviewConnector(x1: x1, y1: y1, x2: x2, y2: y2,
                                               label: edge.label ?? "", dashed: false, isLifeline: false))
            var arrow: [String: Any] = [
                "type": "arrow",
                "x": x1, "y": y1,
                "width": x2 - x1, "height": y2 - y1,
                "strokeColor": defaultStroke,
                // Bound both ends, which is what makes the arrow follow when
                // the captain drags a box afterwards - the whole point of
                // generating something hand-editable rather than a picture.
                "start": ["id": "n\(edge.from)"],
                "end": ["id": "n\(edge.to)"],
            ]
            if let label = edge.label {
                arrow["label"] = ["text": label, "fontSize": labelFontSize]
            }
            elements.append(arrow)
        }

        guard elements.count <= WhiteboardDiagram.maxElements else {
            return .failure(DiagramDSLError(
                line: nil,
                message: "that comes to \(elements.count) elements, past the \(WhiteboardDiagram.maxElements)-element limit."))
        }
        return .success(Diagram(elements: elements,
                                summary: "\(count(names.count, "box", "boxes")), \(count(edges.count, "arrow", "arrows"))",
                                boxes: boxes,
                                connectors: connectors))
    }

    /// Kahn's algorithm, plus a deterministic placement for cycle members.
    /// Exposed for the self-test, which asserts the ranking directly rather
    /// than inferring it from y coordinates.
    static func rankNodes(count: Int, edges: [(from: Int, to: Int)]) -> [Int] {
        var outgoing: [[Int]] = Array(repeating: [], count: count)
        var incoming: [[Int]] = Array(repeating: [], count: count)
        var inDegree = Array(repeating: 0, count: count)
        for edge in edges {
            outgoing[edge.from].append(edge.to)
            incoming[edge.to].append(edge.from)
            inDegree[edge.to] += 1
        }
        var rank = Array(repeating: 0, count: count)
        var placed = Array(repeating: false, count: count)
        // First-appearance order, never a set: the layout has to be the same
        // every time the same text is typed.
        var queue = (0..<count).filter { inDegree[$0] == 0 }
        var head = 0
        while head < queue.count {
            let node = queue[head]; head += 1
            placed[node] = true
            for next in outgoing[node] {
                rank[next] = max(rank[next], rank[node] + 1)
                inDegree[next] -= 1
                if inDegree[next] == 0 { queue.append(next) }
            }
        }
        for node in 0..<count where !placed[node] {
            let ranked = incoming[node].filter { placed[$0] }.map { rank[$0] + 1 }
            let after = placed.indices.filter { placed[$0] }.map { rank[$0] + 1 }.max() ?? 0
            rank[node] = ranked.max() ?? after
            placed[node] = true
        }
        return rank
    }

    private static func rankNodes(count: Int, edges: [FlowEdge]) -> [Int] {
        rankNodes(count: count, edges: edges.map { (from: $0.from, to: $0.to) })
    }

    // MARK: Sequence

    private struct Message {
        let from: Int
        let to: Int
        let label: String?
        let dashed: Bool
    }

    /// Layout: actors across the top, a lifeline under each, one message per
    /// row below the last - which is the auto-spacing a sequence diagram is
    /// for. Message `i` sits at a fixed `messageSpacing` below message `i-1`,
    /// in DSL order, so re-ordering two lines re-orders the diagram and
    /// nothing else moves.
    ///
    /// Message arrows are deliberately **not** bound to anything. Excalidraw
    /// binds arrows to *shapes*, and a lifeline is a `line` - so a binding
    /// would either be refused or land on the actor box at the top, dragging
    /// every message up to it. Absolute geometry between two lifeline
    /// positions is both what works and what a sequence diagram means.
    private static func buildSequence(_ lines: [String]) -> Result<Diagram, DiagramDSLError> {
        var names: [String] = []
        var index: [String: Int] = [:]
        var kinds: [Int: DiagramComponent] = [:]
        var messages: [Message] = []

        func intern(_ token: NodeToken) -> Int {
            let id: Int
            if let existing = index[token.name] {
                id = existing
            } else {
                id = names.count
                names.append(token.name)
                index[token.name] = id
            }
            if let kind = token.kind, kinds[id] == nil { kinds[id] = kind }
            return id
        }

        for (offset, raw) in lines.enumerated() {
            let lineNumber = offset + 1
            guard let statement = strippedStatement(raw) else { continue }
            let (head, label) = splitLabel(statement)
            let split = splitOnArrows(head)

            guard !split.arrows.isEmpty else {
                switch parseNode(head, line: lineNumber) {
                case .failure(let error): return .failure(error)
                case .success(let token): _ = intern(token)
                }
                continue
            }

            var previous: Int?
            for (position, segment) in split.segments.enumerated() {
                switch parseNode(segment, line: lineNumber) {
                case .failure(let error): return .failure(error)
                case .success(let token):
                    let id = intern(token)
                    if let from = previous {
                        messages.append(Message(from: from, to: id, label: label,
                                                dashed: split.arrows[position - 1]))
                    }
                    previous = id
                }
            }
            guard names.count <= maxNodes else {
                return .failure(DiagramDSLError(
                    line: lineNumber,
                    message: "that's more than \(maxNodes) actors. Try splitting it into smaller diagrams."))
            }
        }

        guard !names.isEmpty else {
            return .failure(DiagramDSLError(
                line: nil,
                message: "nothing to draw yet. Try a line like \"Client -> Server: request\"."))
        }

        var labels: [String] = []
        var widths: [Double] = []
        for id in names.indices {
            let kind = kinds[id]
            let label = kind.map { "\($0.emoji) \(names[id])" } ?? names[id]
            labels.append(label)
            widths.append(boxWidth(for: label))
        }

        var centres: [Double] = []
        var x: Double = 0
        for width in widths {
            centres.append((x + width / 2).rounded())
            x += width + actorGap
        }

        let firstMessageY = nodeHeight + lifelineTopGap
        let lastMessageY = messages.isEmpty
            ? firstMessageY
            : firstMessageY + Double(messages.count - 1) * messageSpacing
        let lifelineBottom = lastMessageY + lifelineTailGap

        var boxes: [PreviewBox] = []
        var connectors: [PreviewConnector] = []
        var elements: [[String: Any]] = []

        for id in names.indices {
            let kind = kinds[id]
            let box = PreviewBox(x: (centres[id] - widths[id] / 2).rounded(), y: 0,
                                 width: widths[id], height: nodeHeight,
                                 label: labels[id],
                                 strokeHex: kind?.strokeColor ?? defaultStroke,
                                 fillHex: kind?.backgroundColor ?? "transparent")
            boxes.append(box)
            elements.append(shapeElement(id: "a\(id)", box: box))

            connectors.append(PreviewConnector(x1: centres[id], y1: nodeHeight,
                                               x2: centres[id], y2: lifelineBottom,
                                               label: "", dashed: true, isLifeline: true))
            elements.append([
                "type": "line",
                "x": centres[id], "y": nodeHeight,
                "width": 0.0, "height": lifelineBottom - nodeHeight,
                "strokeColor": defaultStroke,
                "strokeStyle": "dashed",
            ])
        }

        for (position, message) in messages.enumerated() {
            let y = firstMessageY + Double(position) * messageSpacing
            let fromX = centres[message.from]
            // A self-message has no second lifeline to land on, so it is a
            // short stub to the right of its own.
            let toX = message.from == message.to ? fromX + selfMessageWidth : centres[message.to]
            connectors.append(PreviewConnector(x1: fromX, y1: y, x2: toX, y2: y,
                                               label: message.label ?? "",
                                               dashed: message.dashed, isLifeline: false))
            var arrow: [String: Any] = [
                "type": "arrow",
                "x": fromX, "y": y,
                "width": toX - fromX, "height": 0.0,
                "strokeColor": defaultStroke,
                "strokeStyle": message.dashed ? "dashed" : "solid",
            ]
            if let label = message.label {
                arrow["label"] = ["text": label, "fontSize": labelFontSize]
            }
            elements.append(arrow)
        }

        guard elements.count <= WhiteboardDiagram.maxElements else {
            return .failure(DiagramDSLError(
                line: nil,
                message: "that comes to \(elements.count) elements, past the \(WhiteboardDiagram.maxElements)-element limit."))
        }
        return .success(Diagram(elements: elements,
                                summary: "\(count(names.count, "actor", "actors")), \(count(messages.count, "message", "messages"))",
                                boxes: boxes,
                                connectors: connectors))
    }

    // MARK: Shared

    /// Excalidraw's own default stroke. Everything untyped is drawn in it, so a
    /// bare `A --> B` looks exactly like two boxes the captain drew by hand.
    static let defaultStroke = "#1e1e1e"

    private static func shapeElement(id: String, box: PreviewBox) -> [String: Any] {
        [
            "type": "rectangle",
            "id": id,
            "x": box.x, "y": box.y,
            "width": box.width, "height": box.height,
            "strokeColor": box.strokeHex,
            "backgroundColor": box.fillHex,
            "fillStyle": "solid",
            "roundness": ["type": 3],
            // A bound label, never a separate text element laid over the box:
            // `formatRules` says so for the AI path and the reason is the same
            // here - a bound caption moves, resizes and re-wraps with its
            // container, and an overlaid one does not.
            "label": ["text": box.label, "fontSize": fontSize],
        ]
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }
}
