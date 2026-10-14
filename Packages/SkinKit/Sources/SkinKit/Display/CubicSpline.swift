import Foundation

/// Port of Webamp's EqualizerWindow/spline.js (itself adapted from morganherlocker/cubic-spline; Webamp is MIT,
/// see NOTICE): a natural cubic spline whose coefficients come from Gaussian elimination, kept step for step so the
/// rounded graph pixels agree with Webamp's.
enum CubicSpline {
    /// y for every integer x in 0...xs.last, given knots (xs strictly increasing, xs[0] == 0).
    static func interpolate(xs: [Double], ys: [Double]) -> [Double] {
        guard xs.count >= 2, xs.count == ys.count, let maxX = xs.last else { return ys }
        let ks = naturalKs(xs: xs, ys: ys)
        var all: [Double] = []
        var i = 1
        var x = 0.0
        while x <= maxX {
            while xs[i] < x { i += 1 }
            let dx = xs[i] - xs[i - 1]
            let dy = ys[i] - ys[i - 1]
            let t = (x - xs[i - 1]) / dx
            let a = ks[i - 1] * dx - dy
            let b = -ks[i] * dx + dy
            all.append((1 - t) * ys[i - 1] + t * ys[i] + t * (1 - t) * (a * (1 - t) + b * t))
            x += 1
        }
        return all
    }

    private static func naturalKs(xs: [Double], ys: [Double]) -> [Double] {
        let n = xs.count - 1
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: n + 2), count: n + 1)
        if n >= 2 {
            for i in 1..<n {
                matrix[i][i - 1] = 1 / (xs[i] - xs[i - 1])
                matrix[i][i] = 2 * (1 / (xs[i] - xs[i - 1]) + 1 / (xs[i + 1] - xs[i]))
                matrix[i][i + 1] = 1 / (xs[i + 1] - xs[i])
                matrix[i][n + 1] = 3 * (
                    (ys[i] - ys[i - 1]) / ((xs[i] - xs[i - 1]) * (xs[i] - xs[i - 1]))
                        + (ys[i + 1] - ys[i]) / ((xs[i + 1] - xs[i]) * (xs[i + 1] - xs[i])))
            }
        }
        matrix[0][0] = 2 / (xs[1] - xs[0])
        matrix[0][1] = 1 / (xs[1] - xs[0])
        matrix[0][n + 1] = 3 * (ys[1] - ys[0]) / ((xs[1] - xs[0]) * (xs[1] - xs[0]))
        matrix[n][n - 1] = 1 / (xs[n] - xs[n - 1])
        matrix[n][n] = 2 / (xs[n] - xs[n - 1])
        matrix[n][n + 1] = 3 * (ys[n] - ys[n - 1]) / ((xs[n] - xs[n - 1]) * (xs[n] - xs[n - 1]))
        return solve(&matrix)
    }

    private static func solve(_ matrix: inout [[Double]]) -> [Double] {
        let m = matrix.count
        var ks = [Double](repeating: 0, count: m)
        for k in 0..<m {
            // Pivot: the first row with the largest value in column k (JS `>` keeps the earliest on ties).
            var iMax = 0
            var best = -Double.infinity
            for i in k..<m where matrix[i][k] > best {
                iMax = i
                best = matrix[i][k]
            }
            matrix.swapAt(k, iMax)
            for i in (k + 1)..<max(m, k + 1) {
                for j in (k + 1)..<(m + 1) {
                    matrix[i][j] -= matrix[k][j] * (matrix[i][k] / matrix[k][k])
                }
                matrix[i][k] = 0
            }
        }
        for i in stride(from: m - 1, through: 0, by: -1) {
            let v = matrix[i][m] / matrix[i][i]
            ks[i] = v
            for j in stride(from: i - 1, through: 0, by: -1) {
                matrix[j][m] -= matrix[j][i] * v
                matrix[j][i] = 0
            }
        }
        return ks
    }
}
