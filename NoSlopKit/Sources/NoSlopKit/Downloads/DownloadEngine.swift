import Foundation

/// The URLSession side of downloads: the background session, one download task per Range chunk, the delegate
/// that moves each finished chunk into the work directory, and retry bookkeeping. `DownloadManager` drives it.
///
/// STUB (Task 1A). Task 7 owns this file; nothing outside `Downloads/` refers to it, so Task 7 may reshape it freely.
enum DownloadEngine {}
