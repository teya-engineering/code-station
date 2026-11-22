import SwiftUI

struct FlowingWires: NSViewRepresentable {
    let paths: [CGFloat: CGPath]
    let colour: Color
    var dash = FlowingWiresView.wireDash
    var period = FlowingWiresView.wirePeriod

    func makeNSView(context: Context) -> FlowingWiresView {
        FlowingWiresView(dash: dash, period: period)
    }

    func updateNSView(_ view: FlowingWiresView, context: Context) {
        view.update(paths: paths, colour: colour.resolve(in: context.environment).cgColor)
    }
}

final class FlowingWiresView: LoopLayerView {
    static let wireDash: [CGFloat] = [2, 10]
    static let wirePeriod: TimeInterval = 1.3

    private let dash: [CGFloat]
    private let period: TimeInterval
    // One layer for each line width, since a layer strokes every line it holds the same.
    private var lines: [CGFloat: CAShapeLayer] = [:]

    init(dash: [CGFloat], period: TimeInterval) {
        self.dash = dash
        self.period = period
        super.init(frame: .zero)
    }

    func update(paths: [CGFloat: CGPath], colour: CGColor) {
        LayerLoop.still {
            for (width, line) in lines where paths[width] == nil {
                line.removeFromSuperlayer()
                lines[width] = nil
            }
            for (width, path) in paths {
                let line = lines[width] ?? addLine(width: width)
                line.path = path
                line.strokeColor = colour
            }
        }
    }

    override func layoutLayers() {
        lines.values.forEach { $0.frame = bounds }
    }

    override func restartLoops() {
        lines.values.forEach(flow)
    }

    private func addLine(width: CGFloat) -> CAShapeLayer {
        let line = CAShapeLayer()
        line.fillColor = nil
        line.lineWidth = width
        line.lineCap = .round
        line.lineDashPattern = dash.map { NSNumber(value: Double($0)) }
        line.frame = bounds
        line.contentsScale = window?.backingScaleFactor ?? 2
        layer?.addSublayer(line)
        lines[width] = line
        flow(line)
        return line
    }

    // The dashes travel one whole pattern each period, along the way the path was drawn.
    private func flow(_ line: CAShapeLayer) {
        let flow = CABasicAnimation(keyPath: "lineDashPhase")
        flow.fromValue = 0
        flow.toValue = -dash.reduce(0, +)
        flow.duration = period
        line.add(LayerLoop.repeating(flow, period: period), forKey: "flow")
    }
}
