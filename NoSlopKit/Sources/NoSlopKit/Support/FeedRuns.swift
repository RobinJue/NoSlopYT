import Foundation

/// A stretch of a mixed feed that is laid out the same way: a run of cards that share the columns of a grid, or a
/// single row that spans the whole width.
public struct FeedRun<Element: Sendable>: Sendable {
    /// True for a run of cards that flow into the grid's columns; false for one full-width row.
    public let isGrid: Bool
    public let items: [Element]
}

extension FeedRun: Equatable where Element: Equatable {}

public enum FeedRuns {
    /// Splits `items` into runs, in order: consecutive grid items (video cards) form one run, and every other item
    /// (a channel or playlist row) is a run of its own, so that it can take the whole width instead of one column
    /// with a tall card beside it.
    public static func split<Element: Sendable>(_ items: [Element], isGridItem: (Element) -> Bool) -> [FeedRun<Element>] {
        var runs: [FeedRun<Element>] = []
        var current: [Element] = []
        for item in items {
            if isGridItem(item) {
                current.append(item)
            } else {
                if !current.isEmpty { runs.append(FeedRun(isGrid: true, items: current)); current = [] }
                runs.append(FeedRun(isGrid: false, items: [item]))
            }
        }
        if !current.isEmpty { runs.append(FeedRun(isGrid: true, items: current)) }
        return runs
    }
}
