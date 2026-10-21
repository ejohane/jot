import SwiftUI
import UIKit

/// The editor remains first responder while the rail is being customized.
struct JotKeyboardRail: View {
    @Binding var isCustomizing: Bool
    var enabled: Bool
    var activeActions: Set<KeyboardRailAction>
    var perform: (KeyboardRailAction) -> Void
    var dismissKeyboard: () -> Void
    var finished: () -> Void
    @AppStorage(KeyboardRailLayout.preferenceKey) private var savedActions = KeyboardRailLayout().storedValue
    @State private var draft = KeyboardRailLayout()
    @State private var showingActions = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layout: KeyboardRailLayout { isCustomizing ? draft : KeyboardRailLayout(storedValue: savedActions) }

    var body: some View {
        HStack(spacing: 0) {
            KeyboardRailIcons(
                actions: layout.actions, isCustomizing: isCustomizing, enabled: enabled,
                activeActions: activeActions, perform: perform, beginCustomizing: beginCustomizing,
                remove: { action in animate { draft.remove(action) } },
                move: { action, index in draft.move(action, to: index) }
            )
            .frame(height: isCustomizing ? 56 : 44)
            if isCustomizing || layout.actions.isEmpty {
                Button("Add action", systemImage: "plus") {
                    if !isCustomizing { beginCustomizing() }
                    showingActions = true
                }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("rail.add")
            }
            if isCustomizing {
                Button("Done") {
                    savedActions = draft.storedValue
                    animate { isCustomizing = false }
                    finished()
                }
                .font(.body.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minWidth: 60, minHeight: 44)
                .accessibilityIdentifier("rail.done")
            } else {
                Button("Dismiss keyboard", systemImage: "keyboard.chevron.compact.down", action: dismissKeyboard)
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 21, weight: .semibold))
        .foregroundStyle(.primary)
        .tint(.primary)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .modifier(KeyboardBarSurface())
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .sheet(isPresented: $showingActions, onDismiss: { finished() }) {
            NavigationStack {
                List {
                    Section {
                        ForEach(KeyboardRailAction.allCases) { action in
                            let included = draft.actions.contains(action)
                            Button {
                                animate { draft.add(action) }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: action.symbol).frame(width: 28)
                                    Text(action.title)
                                    Spacer()
                                    Image(systemName: included ? "checkmark" : "plus")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(minHeight: 36)
                            }
                            .disabled(included)
                            .accessibilityLabel(included ? "\(action.title), already on rail" : "Add \(action.title)")
                        }
                    } footer: {
                        Text("Drag icons on the rail to reorder them. Tap a minus to remove one.")
                    }
                }
                .navigationTitle("Add Actions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingActions = false } } }
            }
            .tint(.primary)
            .presentationDetents([.medium, .large])
        }
    }

    private func beginCustomizing() {
        guard enabled, !isCustomizing else { return }
        draft = KeyboardRailLayout(storedValue: savedActions)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        animate { isCustomizing = true }
        UIAccessibility.post(notification: .announcement, argument: "Customizing keyboard rail. Drag to reorder, or use the actions menu to move or remove an action.")
    }

    private func animate(_ changes: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18), changes)
    }
}

private struct KeyboardRailIcons: UIViewRepresentable {
    var actions: [KeyboardRailAction]
    var isCustomizing: Bool
    var enabled: Bool
    var activeActions: Set<KeyboardRailAction>
    var perform: (KeyboardRailAction) -> Void
    var beginCustomizing: () -> Void
    var remove: (KeyboardRailAction) -> Void
    var move: (KeyboardRailAction, Int) -> Void

    func makeUIView(context: Context) -> RailCollectionView { RailCollectionView() }
    func updateUIView(_ view: RailCollectionView, context: Context) { view.update(self) }

    final class RailCollectionView: UICollectionView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
        private var configuration: KeyboardRailIcons?
        private var items: [KeyboardRailAction] = []
        private var moving = false
        private var lastDestination: IndexPath?
        private let feedback = UISelectionFeedbackGenerator()
        private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold))
        private lazy var reorderPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))

        init() {
            let flow = UICollectionViewFlowLayout()
            flow.scrollDirection = .horizontal
            flow.minimumLineSpacing = 0
            flow.minimumInteritemSpacing = 0
            super.init(frame: .zero, collectionViewLayout: flow)
            backgroundColor = .clear
            showsHorizontalScrollIndicator = false
            alwaysBounceHorizontal = false
            dataSource = self
            delegate = self
            register(RailCell.self, forCellWithReuseIdentifier: "action")
            hold.minimumPressDuration = 0.45
            hold.delegate = self
            addGestureRecognizer(hold)
            reorderPan.delegate = self
            addGestureRecognizer(reorderPan)
            panGestureRecognizer.require(toFail: reorderPan)
            accessibilityIdentifier = "keyboardRail"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(_ configuration: KeyboardRailIcons) {
            let changed = items != configuration.actions
            let modeChanged = self.configuration?.isCustomizing != configuration.isCustomizing
            self.configuration = configuration
            if changed && !moving {
                items = configuration.actions
                reloadData()
            } else {
                for case let cell as RailCell in visibleCells {
                    guard let index = indexPath(for: cell)?.item, items.indices.contains(index) else { continue }
                    configure(cell, action: items[index])
                }
            }
            if modeChanged { collectionViewLayout.invalidateLayout() }
        }

        override func layoutSubviews() {
            // Invalidate widths when Done appears, the device width changes, or text size changes.
            if let flow = collectionViewLayout as? UICollectionViewFlowLayout {
                let width = max(48, bounds.width / CGFloat(max(items.count, 1)))
                let size = CGSize(width: width, height: bounds.height)
                if flow.itemSize != size { flow.itemSize = size }
            }
            super.layoutSubviews()
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = dequeueReusableCell(withReuseIdentifier: "action", for: indexPath) as! RailCell
            configure(cell, action: items[indexPath.item])
            return cell
        }

        private func configure(_ cell: RailCell, action: KeyboardRailAction) {
            guard let configuration else { return }
            cell.configure(action: action, editing: configuration.isCustomizing,
                           enabled: configuration.enabled, selected: configuration.activeActions.contains(action))
            cell.activate = { [weak self] in
                guard let configuration = self?.configuration, !configuration.isCustomizing, configuration.enabled else { return }
                configuration.perform(action)
            }
            cell.remove = { [weak self] in self?.configuration?.remove(action) }
            if configuration.isCustomizing {
                cell.icon.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: "Move left") { [weak self] _ in self?.moveAccessible(action, offset: -1) ?? false },
                    UIAccessibilityCustomAction(name: "Move right") { [weak self] _ in self?.moveAccessible(action, offset: 1) ?? false },
                    UIAccessibilityCustomAction(name: "Remove from rail") { [weak self] _ in self?.configuration?.remove(action); return true }
                ]
            } else {
                cell.icon.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: "Customize rail") { [weak self] _ in self?.configuration?.beginCustomizing(); return true }
                ]
            }
        }

        private func moveAccessible(_ action: KeyboardRailAction, offset: Int) -> Bool {
            guard let index = items.firstIndex(of: action), items.indices.contains(index + offset) else { return false }
            configuration?.move(action, index + offset)
            feedback.selectionChanged()
            return true
        }

        func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool {
            configuration?.isCustomizing == true
        }
        func collectionView(_ collectionView: UICollectionView, moveItemAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
            let action = items.remove(at: sourceIndexPath.item)
            items.insert(action, at: destinationIndexPath.item)
            configuration?.move(action, destinationIndexPath.item)
        }
        func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath, toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
            if proposedIndexPath != lastDestination {
                feedback.selectionChanged()
                feedback.prepare()
                lastDestination = proposedIndexPath
            }
            return proposedIndexPath
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let configuration, configuration.enabled else { return false }
            if gestureRecognizer === reorderPan { return configuration.isCustomizing && actionAt(gestureRecognizer.location(in: self)) != nil }
            if gestureRecognizer === hold { return actionAt(gestureRecognizer.location(in: self)) != nil }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Minus buttons must be tappable without beginning a reorder.
            !(touch.view is UIButton && touch.view?.accessibilityIdentifier?.hasPrefix("rail.remove.") == true)
        }
        private func actionAt(_ point: CGPoint) -> IndexPath? { indexPathForItem(at: point) }

        @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                if configuration?.isCustomizing != true {
                    configuration?.beginCustomizing()
                    if let index = actionAt(gesture.location(in: self)), let cell = cellForItem(at: index) {
                        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15, animations: {
                            cell.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
                        })
                    }
                } else { startMovement(at: gesture.location(in: self)) }
            case .changed: if moving { updateInteractiveMovementTargetPosition(gesture.location(in: self)) }
            case .ended, .cancelled, .failed:
                finishMovement(cancelled: gesture.state != .ended)
                visibleCells.forEach { $0.transform = .identity }
            default: break
            }
        }
        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began: startMovement(at: gesture.location(in: self))
            case .changed: if moving { updateInteractiveMovementTargetPosition(gesture.location(in: self)) }
            case .ended: finishMovement(cancelled: false)
            case .cancelled, .failed: finishMovement(cancelled: true)
            default: break
            }
        }
        private func startMovement(at point: CGPoint) {
            guard !moving, let index = actionAt(point), configuration?.isCustomizing == true else { return }
            moving = beginInteractiveMovementForItem(at: index)
            lastDestination = index
            feedback.prepare()
        }
        private func finishMovement(cancelled: Bool) {
            guard moving else { return }
            if cancelled { cancelInteractiveMovement() } else { endInteractiveMovement() }
            moving = false
            lastDestination = nil
        }
    }
}

private final class RailCell: UICollectionViewCell {
    let icon = UIButton(type: .system)
    private let minus = UIButton(type: .system)
    var activate: (() -> Void)?
    var remove: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(icon)
        contentView.addSubview(minus)
        icon.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        minus.addTarget(self, action: #selector(removed), for: .touchUpInside)
        minus.setImage(UIImage(systemName: "minus.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        minus.tintColor = .label
        minus.backgroundColor = .secondarySystemBackground
        minus.layer.cornerRadius = 11
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 0, y: minus.isHidden ? 0 : 8, width: bounds.width, height: 44)
        minus.frame = CGRect(x: max(2, bounds.midX - 23), y: 0, width: 26, height: 26)
    }
    func configure(action: KeyboardRailAction, editing: Bool, enabled: Bool, selected: Bool) {
        icon.setImage(UIImage(systemName: action.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)), for: .normal)
        icon.tintColor = selected && !editing ? .black : .label
        icon.backgroundColor = selected && !editing ? .systemYellow : .clear
        icon.layer.cornerRadius = 22
        icon.isEnabled = enabled
        icon.accessibilityLabel = action.title
        icon.accessibilityHint = editing ? "Drag to reorder. Actions also let you move or remove this shortcut." : "Touch and hold to customize the rail."
        icon.accessibilityIdentifier = "rail.action.\(action.rawValue)"
        icon.accessibilityTraits = selected && !editing ? [.button, .selected] : .button
        minus.isHidden = !editing
        minus.accessibilityLabel = "Remove \(action.title)"
        minus.accessibilityIdentifier = "rail.remove.\(action.rawValue)"
        setNeedsLayout()
    }
    @objc private func tapped() { activate?() }
    @objc private func removed() { remove?() }
}
