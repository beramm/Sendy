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

        var warnings: [String] = []
        let (climbing, floorCount) = Self.dropFloorContacts(contacts, scale: scale, config: config)
        if floorCount > 0 {
            warnings.append(
                "\(floorCount) foot contact\(floorCount == 1 ? "" : "s") on the floor "
                + "\(floorCount == 1 ? "was" : "were") left out of the route. "
                + "The mat is not a hold; lower the ground margin if this route genuinely starts that low."
            )
        }
        guard !climbing.isEmpty else {
            return Route(holds: [], warnings: warnings + ["Every contact on the reference climb was on the floor, so no route could be derived."])
        }

        var clusters = Self.cluster(climbing, radius: config.holdClusterEpsilon, scale: scale)
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

        if holds.count < config.minPlausibleHolds {
            warnings.append("Only \(holds.count) holds derived — contact detection probably under-fired. Lower the dwell frames or raise the velocity threshold.")
        }
        if holds.count > config.maxPlausibleHolds {
            warnings.append("\(holds.count) holds derived, which is implausible for one route — raise the cluster radius or the contact merge radius.")
        }
        if holds.filter(\.isHandHold).count < 2 {
            warnings.append("Fewer than two hand holds derived, so the climb cannot be split into moves.")
        }
        let singles = holds.filter { $0.contactCount == 1 }.count
        if singles > 0 {
            // Kept, not dropped: the reference climber touches some holds
            // exactly once, and a foot placed once is still a foothold. Said
            // out loud because it is also what a stray contact looks like.
            warnings.append("\(singles) hold\(singles == 1 ? " was" : "s were") touched exactly once.")
        }
        return Route(holds: holds, warnings: warnings)
    }

    // MARK: Clustering

    /// Contacts made on the floor, dropped before anything is clustered.
    ///
    /// A climber stands on the mat arranging themselves before pulling on, and
    /// lands back on it afterwards. Those are foot contacts like any other and
    /// they clustered into holds at the bottom of the route — three of them on
    /// `gym-testing/test1`, sitting on the mat in the rendered overlay.
    ///
    /// The floor is read from the data rather than assumed: the lowest foot
    /// contact plus `groundMargin`. Guarded so it can never empty the route —
    /// if every foot contact is on the line, the line is wrong and nothing is
    /// dropped.
    static func dropFloorContacts(
        _ contacts: [Contact], scale: ClimbScale, config: TuningConfig
    ) -> (kept: [Contact], dropped: Int) {
        guard config.groundMargin > 0 else { return (contacts, 0) }
        let feet = contacts.filter(\.isFoot)
        guard let floor = feet.map(\.position.y).min() else { return (contacts, 0) }
        let line = floor + config.groundMargin * scale.torsoLength
        let onFloor = feet.filter { $0.position.y <= line }
        guard !onFloor.isEmpty, onFloor.count < feet.count else { return (contacts, 0) }
        let ids = Set(onFloor.map(\.id))
        return (contacts.filter { !ids.contains($0.id) }, onFloor.count)
    }

    /// Groups contacts into holds by **agglomerative complete-linkage**, capped
    /// at a hold-sized diameter.
    ///
    /// This replaced DBSCAN, which was wrong in a way that only showed up once
    /// the wall was drawn behind the route. With `minPoints` at 1 every contact
    /// is a core point, so DBSCAN degenerates to single linkage: clusters grow
    /// by transitive closure and nothing bounds how far they reach. On
    /// `gym-testing/test1` that produced four "holds" whose contacts spanned
    /// 1.0–1.2 body-lengths — a region covering several real holds — while
    /// isolated touches stayed separate. Both failures at once, and no value of
    /// the radius fixes both: raising it chains harder, lowering it splinters.
    ///
    /// Complete linkage bounds the **diameter** instead of the link, which is
    /// the physical fact being modelled: a hold is a bounded object, and two
    /// contacts a body-length apart are not on it however many contacts lie
    /// between them. `radius` is that object's radius, so the cap is `2 ×
    /// radius`.
    ///
    /// O(n³) in the worst case, on the order of a hundred contacts. Not worth
    /// optimising.
    static func cluster(_ contacts: [Contact], radius: Double, scale: ClimbScale) -> [[Contact]] {
        guard contacts.count > 1 else { return contacts.map { [$0] } }
        let diameter = max(0, radius) * 2

        // Distances are symmetric and reused every merge round.
        let n = contacts.count
        var distance = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0 ..< n {
            for j in (i + 1) ..< n {
                let d = scale.distance(contacts[i].position, contacts[j].position)
                distance[i][j] = d
                distance[j][i] = d
            }
        }

        var groups: [[Int]] = (0 ..< n).map { [$0] }

        /// Complete-linkage distance: the diameter the merged cluster would have.
        ///
        /// Time is deliberately *not* consulted here. Forbidding a limb's
        /// consecutive contacts from merging — on the theory that it must have
        /// moved between them — was tried and is wrong on real footage: it
        /// takes the reference pair from 18 holds to 32 and from 11 hand holds
        /// to 19, against 8–11 hand moves by eye. A limb adjusting on a hold
        /// beyond `contactMergeRadius` is common, and it is not a move.
        func linkage(_ a: [Int], _ b: [Int]) -> Double {
            var worst = 0.0
            for i in a {
                for j in b { worst = max(worst, distance[i][j]) }
            }
            return worst
        }

        while groups.count > 1 {
            var best = Double.infinity
            var pair: (Int, Int)?
            for i in 0 ..< groups.count {
                for j in (i + 1) ..< groups.count {
                    let d = linkage(groups[i], groups[j])
                    // Strictly less keeps the first pair on a tie, and the
                    // groups are in a deterministic order, so equal-distance
                    // merges resolve the same way on every run.
                    if d < best { best = d; pair = (i, j) }
                }
            }
            guard let (i, j) = pair, best <= diameter else { break }
            groups[i].append(contentsOf: groups[j])
            groups.remove(at: j)
        }

        return groups.map { $0.map { contacts[$0] } }
    }
}
