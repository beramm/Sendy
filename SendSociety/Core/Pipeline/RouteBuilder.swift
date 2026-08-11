import Foundation

/// Clusters the **reference** climb's contacts into holds and orders them.
///
/// Runs on the reference climb only. The attempt's contacts are *matched*
/// against the route this produces, never used to rebuild it — otherwise a
/// climber who grabs the wrong hold rewrites the route they're being compared
/// against.
public struct RouteBuilder: Sendable {

    public init() {}

    public func build(contacts: [Contact], scale: ClimbScale, config: TuningConfig) -> Route {
        guard !contacts.isEmpty else {
            return Route(holds: [], warnings: ["No contacts on the reference climb, so no route could be derived."])
        }

        let labels = dbscan(
            points: contacts.map(\.position),
            epsilon: config.holdClusterEpsilon,
            minPoints: config.holdClusterMinPoints,
            scale: scale
        )

        var groups: [Int: [Contact]] = [:]
        var noise: [Contact] = []
        for (i, label) in labels.enumerated() {
            if label >= 0 { groups[label, default: []].append(contacts[i]) }
            else { noise.append(contacts[i]) }
        }

        // Noise contacts become single-contact holds rather than vanishing.
        // Fail soft: an isolated touch is weak evidence of a hold, but it is
        // better evidence than silence.
        var nextLabel = (groups.keys.max() ?? -1) + 1
        for c in noise {
            groups[nextLabel] = [c]
            nextLabel += 1
        }

        // Sorted by cluster label first so `Dictionary`'s randomised iteration
        // order cannot leak into hold ids, then ordered by first touch.
        var clusters: [[Contact]] = groups.keys.sorted().map { groups[$0]! }
        clusters.sort { (a, b) in
            let firstA = a.min(by: Contact.deterministicOrder)!
            let firstB = b.min(by: Contact.deterministicOrder)!
            return Contact.deterministicOrder(firstA, firstB)
        }

        var holds: [Hold] = []
        for (ordinal, cluster) in clusters.enumerated() {
            let firstContact = cluster.min(by: Contact.deterministicOrder)!
            let weights = cluster.map { Double($0.frameCount) }
            let totalWeight = weights.reduce(0, +)
            let centroid = zip(cluster, weights)
                .reduce(Point2D.zero) { $0 + $1.0.position * $1.1 } / max(totalWeight, 1e-9)
            holds.append(Hold(
                id: ordinal,
                position: centroid,
                firstUsedBy: firstContact.joint,
                ordinal: ordinal,
                contactCount: cluster.count,
                firstFrame: firstContact.startFrame,
                usedByHands: cluster.contains(where: \.isHand),
                usedByFeet: cluster.contains(where: \.isFoot)
            ))
        }

        var warnings: [String] = []
        if holds.count < config.minPlausibleHolds {
            warnings.append("Only \(holds.count) holds derived — contact detection probably under-fired. Lower the dwell frames or raise the velocity threshold.")
        }
        if holds.count > config.maxPlausibleHolds {
            warnings.append("\(holds.count) holds derived, which is implausible for one route — raise the cluster epsilon or the contact merge radius.")
        }
        if holds.filter(\.isHandHold).count < 2 {
            warnings.append("Fewer than two hand holds derived, so the climb cannot be split into moves.")
        }
        if !noise.isEmpty {
            warnings.append("\(noise.count) isolated contacts became single-touch holds.")
        }
        return Route(holds: holds, warnings: warnings)
    }

    /// DBSCAN. Returns a cluster label per point, `-1` for noise.
    ///
    /// Chosen over k-means because the number of holds is exactly the thing we
    /// don't know, and over hierarchical clustering because a wall-width radius
    /// is a parameter that means something physical and can be tuned on site.
    func dbscan(points: [Point2D], epsilon: Double, minPoints: Int, scale: ClimbScale) -> [Int] {
        var labels = [Int](repeating: -2, count: points.count)   // -2 = unvisited
        var cluster = 0

        func neighbours(_ i: Int) -> [Int] {
            points.indices.filter { scale.distance(points[i], points[$0]) <= epsilon }
        }

        for i in points.indices {
            guard labels[i] == -2 else { continue }
            var seeds = neighbours(i)
            if seeds.count < minPoints {
                labels[i] = -1
                continue
            }
            labels[i] = cluster
            var queue = seeds.filter { $0 != i }
            var head = 0
            while head < queue.count {
                let j = queue[head]
                head += 1
                if labels[j] == -1 { labels[j] = cluster }
                guard labels[j] == -2 else { continue }
                labels[j] = cluster
                let jn = neighbours(j)
                if jn.count >= minPoints {
                    for k in jn where labels[k] == -2 || labels[k] == -1 {
                        if !queue.contains(k) { queue.append(k) }
                    }
                }
            }
            seeds.removeAll()
            cluster += 1
        }
        return labels
    }
}
