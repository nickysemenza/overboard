/// How much filesystem discovery one change requires. Directory metadata
/// changes do not imply that every descendant needs to be read again.
public nonisolated enum FileIndexRefreshScope: Int, Sendable {
    case entry
    case children
    case subtree
}
