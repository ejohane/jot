import SwiftUI
import UIKit

struct JotPageTitle: UIViewRepresentable {
    let store: JotStore
    func makeUIView(context: Context) -> JotPageTitleSurface {
        let title = JotPageTitleSurface()
        store.pageTitleView = title
        title.setDate(store.noteTitleDate)
        return title
    }
    func updateUIView(_ title: JotPageTitleSurface, context: Context) {
        store.pageTitleView = title
        title.setDate(store.noteTitleDate)
    }
}

/// The title uses the content page's normalized offset and the same UIKit snap animation.
@MainActor final class JotPageTitleSurface: UIView {
    private let current = UILabel()
    private let incoming = UILabel()
    private var transitioning = false
    private var direction = 0
    private var progress: CGFloat = 0

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .header
        for label in [current, incoming] {
            label.textAlignment = .center
            label.textColor = .label
            label.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
            label.adjustsFontForContentSizeCategory = true
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.75
            label.isAccessibilityElement = false
            addSubview(label)
        }
        incoming.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        for label in [current, incoming] {
            label.bounds = bounds
            label.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        setProgress(progress)
    }
    func setDate(_ date: Date) {
        guard !transitioning else { return }
        current.text = date.formatted(date: .abbreviated, time: .shortened)
        accessibilityLabel = current.text
    }
    func begin(from date: Date, to next: Date, direction: Int) {
        setDate(date)
        transitioning = true
        self.direction = direction
        incoming.text = next.formatted(date: .abbreviated, time: .shortened)
        incoming.isHidden = false
        setProgress(0)
    }
    func setProgress(_ progress: CGFloat) {
        self.progress = progress
        current.transform = CGAffineTransform(translationX: progress * bounds.width, y: 0)
        incoming.transform = CGAffineTransform(translationX: (progress + CGFloat(direction)) * bounds.width, y: 0)
    }
    func finish(date: Date) {
        transitioning = false
        current.transform = .identity
        incoming.isHidden = true
        progress = 0
        setDate(date)
    }
}
