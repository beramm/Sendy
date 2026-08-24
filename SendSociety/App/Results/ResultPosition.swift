import Foundation

/// The Results playhead: a selected sequence plus progress within that
/// sequence. The reference frame is derived from this value and the attempt
/// frame is resolved through the sequence's synchronization path.
struct MovePosition: Equatable {
    var sectionIndex = 0
    var offset = 0.0
}
