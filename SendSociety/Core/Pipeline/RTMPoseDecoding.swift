import Foundation
import CoreGraphics

/// The parts of RTMPose that are pure arithmetic, kept separate from the
/// ONNX Runtime session so they can be unit-tested without a model file.
///
/// Getting SimCC decoding subtly wrong produces keypoints that look plausible
/// and are wrong — a failure mode no confidence number would reveal — so the
/// arithmetic is isolated and pinned against the Python implementation's
/// behaviour rather than trusted.
public enum RTMPoseDecoding {

    /// Model input, width × height. The ONNX signature is `[batch, 3, 256, 192]`
    /// — NCHW, so height 256 and width 192.
    public static let inputWidth = 192
    public static let inputHeight = 256

    /// SimCC output bins per axis: the input dimension times the split ratio.
    /// `simcc_x` is `[batch, K, 384]` and `simcc_y` is `[batch, K, 512]`.
    public static let splitRatio: Double = 2.0

    /// ImageNet normalization, matching `RTMPose.__init__` defaults in rtmlib.
    /// Divergence here would shift every keypoint slightly and silently.
    public static let mean: (r: Double, g: Double, b: Double) = (123.675, 116.28, 103.53)
    public static let std: (r: Double, g: Double, b: Double) = (58.395, 57.12, 57.375)

    /// A bounding box converted to the centre/scale form RTMPose expects.
    public struct BoxTransform: Sendable, Hashable {
        public var centre: CGPoint
        /// Width and height *after* padding and aspect correction.
        public var scale: CGSize
    }

    /// `bbox_xyxy2cs` followed by the aspect fix inside `top_down_affine`.
    ///
    /// The padding of 1.25 and the aspect correction are not cosmetic: the model
    /// was trained on boxes prepared this way, and feeding it a tighter or
    /// differently-shaped crop degrades keypoints in a way that looks like a bad
    /// model rather than a bad crop.
    public static func boxTransform(for box: CGRect, padding: Double = 1.25) -> BoxTransform {
        let centre = CGPoint(x: box.midX, y: box.midY)
        var width = Double(box.width) * padding
        var height = Double(box.height) * padding

        // Match the input aspect ratio by *expanding* the short side, never
        // cropping the long one — cropping would cut off a reaching hand, which
        // is the joint that matters most here.
        let aspect = Double(inputWidth) / Double(inputHeight)
        if width > height * aspect {
            height = width / aspect
        } else {
            width = height * aspect
        }
        return BoxTransform(centre: centre, scale: CGSize(width: width, height: height))
    }

    /// Argmax over each axis's bins, per keypoint.
    ///
    /// - Parameters:
    ///   - simccX: flat `[K * xBins]`
    ///   - simccY: flat `[K * yBins]`
    /// - Returns: keypoint positions in **model input space** and their scores.
    ///
    /// A keypoint whose peak is negative on either axis is reported with a
    /// score of zero — `get_simcc_maximum` treats that as "not found", and
    /// letting it through would put a joint at bin 0, i.e. the top-left corner.
    public static func decodeSimCC(
        simccX: [Float], simccY: [Float], keypointCount: Int
    ) -> (points: [CGPoint], scores: [Double]) {
        guard keypointCount > 0, !simccX.isEmpty, !simccY.isEmpty else { return ([], []) }
        let xBins = simccX.count / keypointCount
        let yBins = simccY.count / keypointCount
        guard xBins > 0, yBins > 0 else { return ([], []) }

        var points: [CGPoint] = []
        var scores: [Double] = []
        points.reserveCapacity(keypointCount)
        scores.reserveCapacity(keypointCount)

        for k in 0 ..< keypointCount {
            var bestX = 0, bestY = 0
            var peakX = -Float.greatestFiniteMagnitude
            var peakY = -Float.greatestFiniteMagnitude
            for i in 0 ..< xBins {
                let v = simccX[k * xBins + i]
                if v > peakX { peakX = v; bestX = i }
            }
            for i in 0 ..< yBins {
                let v = simccY[k * yBins + i]
                if v > peakY { peakY = v; bestY = i }
            }
            // rtmlib takes the lower of the two axis peaks as the score, and
            // zeroes anything not positive on both.
            let score = Double(min(peakX, peakY))
            points.append(CGPoint(x: Double(bestX) / splitRatio, y: Double(bestY) / splitRatio))
            scores.append(score > 0 ? score : 0)
        }
        return (points, scores)
    }

    /// Maps a keypoint from model input space back to pixels in the source
    /// frame. Mirrors the two lines at the end of `RTMPose.postprocess`.
    public static func toSourcePixels(_ point: CGPoint, transform: BoxTransform) -> CGPoint {
        let x = Double(point.x) / Double(inputWidth) * Double(transform.scale.width)
            + Double(transform.centre.x) - Double(transform.scale.width) / 2
        let y = Double(point.y) / Double(inputHeight) * Double(transform.scale.height)
            + Double(transform.centre.y) - Double(transform.scale.height) / 2
        return CGPoint(x: x, y: y)
    }

    /// COCO-WholeBody index → the 19 `JointName` cases.
    ///
    /// Only the body subset (0–16) maps today. Indices 17–22 are the feet, which
    /// are the reason for using this model at all and are measured in task 8.7;
    /// they have no `JointName` case yet.
    public static let cocoToJoint: [Int: JointName] = [
        0: .nose, 1: .leftEye, 2: .rightEye, 3: .leftEar, 4: .rightEar,
        5: .leftShoulder, 6: .rightShoulder, 7: .leftElbow, 8: .rightElbow,
        9: .leftWrist, 10: .rightWrist, 11: .leftHip, 12: .rightHip,
        13: .leftKnee, 14: .rightKnee, 15: .leftAnkle, 16: .rightAnkle
    ]

    /// Builds the `[JointName: Joint]` dictionary from decoded keypoints.
    ///
    /// Vision's normalized space has its origin at the **bottom left** with y
    /// increasing upward; source pixels run top-down. The flip happens here and
    /// nowhere else — getting it wrong would invert every skeleton while leaving
    /// aggregate statistics looking entirely reasonable.
    public static func joints(
        from points: [CGPoint], scores: [Double], imageSize: CGSize
    ) -> [JointName: Joint] {
        guard imageSize.width > 0, imageSize.height > 0 else { return [:] }
        var out: [JointName: Joint] = [:]
        for (index, name) in cocoToJoint {
            guard index < points.count, index < scores.count, scores[index] > 0 else { continue }
            let p = points[index]
            out[name] = Joint(
                point: Point2D(
                    x: Double(p.x) / Double(imageSize.width),
                    y: 1 - Double(p.y) / Double(imageSize.height)
                ),
                confidence: scores[index]
            )
        }
        // COCO has neither a neck nor a root; Vision reports both and the
        // pipeline uses them, so they are derived rather than left missing —
        // otherwise the two trackers would differ for a reason unrelated to
        // tracking quality.
        func midpoint(_ a: JointName, _ b: JointName, into key: JointName) {
            guard let ja = out[a], let jb = out[b] else { return }
            out[key] = Joint(
                point: (ja.point + jb.point) * 0.5,
                confidence: min(ja.confidence, jb.confidence)
            )
        }
        midpoint(.leftShoulder, .rightShoulder, into: .neck)
        midpoint(.leftHip, .rightHip, into: .root)
        return out
    }
}
