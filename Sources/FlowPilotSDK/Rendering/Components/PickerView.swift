import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Picker View

/// Renders the `picker` primitive: a scroll-snap wheel (one or more side-by-side
/// columns) with two-way variable binding. The dashboard canvas paints the
/// STATIC at-rest state (selected value centered, neighbours faded); this SDK
/// renders that same at-rest look and adds live scroll-snap + haptics. The
/// editor renderer (`picker-renderer.tsx` / `picker-geometry.ts`) is the
/// visual-parity source of truth — keep the at-rest geometry in lockstep.
///
/// Variable binding mirrors `SliderView`: per column the bound variable is read
/// on appear, written back on each detent, and the node's `onChange` interaction
/// is fired on settle. The wheel UI is ported from the DemoApp's `WheelPickerView`
/// (UIScrollView snapping engine) and adapted to honour the picker prop contract
/// (configurable item height / fonts / colors and the editor's exact opacity
/// falloff). On non-UIKit platforms it degrades to a native wheel `Picker`.
struct PickerView: View {
    let node: ComponentNode
    let variableStore: VariableStore
    let actionExecutor: ActionExecutor
    let actionContext: ActionContext
    let renderTrigger: Int

    private var props: ComponentProps? { node.props }

    private var isDateMode: Bool {
        PropertyResolver.resolve(props?.pickerMode, store: variableStore, default: "wheel") == "date"
    }

    var body: some View {
        let _ = renderTrigger
        let appearance = resolveAppearance()

        Group {
            if isDateMode {
                PickerDateView(
                    variableKey: props?.variableKey,
                    minDate: PropertyResolver.resolve(props?.pickerMinDate, store: variableStore, default: "1900-01-01"),
                    maxDate: PropertyResolver.resolve(props?.pickerMaxDate, store: variableStore, default: PickerDateUtil.todayISO()),
                    dateOrder: PropertyResolver.resolve(props?.pickerDateOrder, store: variableStore, default: "mdy"),
                    monthFormat: PropertyResolver.resolve(props?.pickerMonthFormat, store: variableStore, default: "short"),
                    defaultValue: PropertyResolver.resolve(props?.pickerDefaultDate, store: variableStore),
                    appearance: appearance,
                    variableStore: variableStore,
                    renderTrigger: renderTrigger,
                    fireOnChange: fireOnChange
                )
            } else if let toggle = props?.pickerUnitToggle,
                      let rawOptions = PickerNumber.dictArray(toggle["options"]), !rawOptions.isEmpty {
                let config = buildUnitToggleConfig(toggle)
                PickerUnitToggleView(
                    config: config,
                    appearance: appearance,
                    variableStore: variableStore,
                    renderTrigger: renderTrigger,
                    fireOnChange: fireOnChange
                )
            } else {
                let columns = buildWheelColumns()
                let headers = columns.map { $0.header }
                PickerColumnGroupLayout(
                    groups: makePickerGroups(headers: headers, widths: columns.map { $0.width }),
                    columnWidths: columns.map { $0.width },
                    anyHeader: headers.contains { $0?.isEmpty == false },
                    appearance: appearance
                ) { i in
                    PickerWheelColumnView(
                        spec: columns[i],
                        appearance: appearance,
                        variableStore: variableStore,
                        renderTrigger: renderTrigger,
                        fireOnChange: fireOnChange
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Appearance

    private func resolveAppearance() -> PickerAppearance {
        var rows = Int(PropertyResolver.resolve(props?.pickerVisibleRows, store: variableStore, default: 5.0).rounded())
        rows = max(3, min(9, rows))
        if rows % 2 == 0 { rows += 1 } // keep odd so there is a single centered row

        let itemHeight = CGFloat(PropertyResolver.resolve(props?.pickerItemHeight, store: variableStore, default: 40.0))
        let fontSize = CGFloat(PropertyResolver.resolve(props?.pickerFontSize, store: variableStore, default: 20.0))
        let selectedFontSize = CGFloat(PropertyResolver.resolve(props?.pickerSelectedFontSize, store: variableStore, default: 22.0))
        let selectionStyle = PropertyResolver.resolve(props?.pickerSelectionStyle, store: variableStore, default: "pill")

        let selectionColor = resolveColor(props?.pickerSelectionColor, defaultValue: "rgba(120,120,128,0.16)", hexFallback: "rgba(120,120,128,0.16)")
        let textColor = resolveColor(props?.pickerTextColor, defaultValue: "token:textSecondary", hexFallback: "#3C3C43")
        let selectedTextColor = resolveColor(props?.pickerSelectedTextColor, defaultValue: "token:textPrimary", hexFallback: "#111827")
        let headerColor = resolveColor(props?.pickerHeaderColor, defaultValue: "token:textPrimary", hexFallback: "#111827")

        let haptics = PropertyResolver.resolve(props?.pickerHaptics, store: variableStore, default: true)
        let loop = PropertyResolver.resolve(props?.pickerLoop, store: variableStore, default: false)

        return PickerAppearance(
            visibleRows: rows,
            itemHeight: itemHeight,
            fontSize: fontSize,
            selectedFontSize: selectedFontSize,
            selectionStyle: selectionStyle,
            selectionColor: selectionColor,
            textColor: textColor,
            selectedTextColor: selectedTextColor,
            headerColor: headerColor,
            haptics: haptics,
            loop: loop
        )
    }

    /// Resolve a color prop: PropertyResolver handles token + conditional refs
    /// when the prop is set; when it is absent we fall back to the documented
    /// default token and resolve that, finally falling back to the hex literal.
    private func resolveColor(_ prop: PropertyValue<String>?, defaultValue: String, hexFallback: String) -> Color {
        let raw = PropertyResolver.resolve(prop, store: variableStore) ?? defaultValue
        let resolved = ThemeTokens.isRef(raw) ? variableStore.resolveThemeToken(raw) : raw
        return Color(hex: resolved) ?? Color(hex: hexFallback) ?? .primary
    }

    // MARK: Wheel columns

    private func buildWheelColumns() -> [WheelColumnSpec] {
        let raw = props?.pickerColumns ?? [["min": 0, "max": 100, "step": 1]]
        return raw.map { PickerColumnBuilder.build($0) }
    }

    private func buildUnitToggleConfig(_ toggle: [String: Any]) -> UnitToggleConfig {
        let systemVariableKey = toggle["systemVariableKey"] as? String
        let defaultKey = toggle["default"] as? String
        let toggleStyle = (toggle["toggleStyle"] as? String) == "switch" ? "switch" : "segmented"
        let rawOptions = PickerNumber.dictArray(toggle["options"]) ?? []

        let options: [UnitSystemOption] = rawOptions.compactMap { od in
            guard let key = od["key"] as? String else { return nil }
            let label = od["label"] as? String ?? key
            let columns = (PickerNumber.dictArray(od["columns"]) ?? []).map { PickerColumnBuilder.build($0) }
            return UnitSystemOption(key: key, label: label, columns: columns)
        }

        // canonicalSystem: explicit key → option keyed "metric" → last option.
        let explicit = toggle["canonicalSystem"] as? String
        let canonicalKey: String =
            (explicit.flatMap { k in options.contains(where: { $0.key == k }) ? k : nil })
            ?? (options.contains(where: { $0.key == "metric" }) ? "metric" : nil)
            ?? options.last?.key
            ?? ""

        return UnitToggleConfig(
            systemVariableKey: systemVariableKey,
            defaultKey: defaultKey,
            canonicalKey: canonicalKey,
            toggleStyle: toggleStyle,
            options: options
        )
    }

    // MARK: Interaction

    private func fireOnChange() {
        guard let interaction = node.interactions?.first(where: { $0.event == .onChange }) else { return }
        Task {
            await actionExecutor.execute(
                actions: interaction.actions,
                context: actionContext,
                elementId: node.id,
                elementType: node.type.rawValue,
                interactionType: "change"
            )
        }
    }
}

// MARK: - Appearance Model

struct PickerAppearance {
    var visibleRows: Int
    var itemHeight: CGFloat
    var fontSize: CGFloat
    var selectedFontSize: CGFloat
    var selectionStyle: String
    var selectionColor: Color
    var textColor: Color
    var selectedTextColor: Color
    var headerColor: Color
    var haptics: Bool
    var loop: Bool

    var headerFontSize: CGFloat { 15 }
    var viewportHeight: CGFloat { CGFloat(visibleRows) * itemHeight }
    /// Vertical space reserved above the wheel for a column header (single line +
    /// the 12pt gap the editor uses). Generous so it never clips the header text.
    var headerReserve: CGFloat { ceil(headerFontSize * 1.3) + 12 }
}

// MARK: - Column Model

private struct PickerItem {
    let label: String          // displayed text (incl. unit suffix)
    let value: VariableValue   // value written to the bound variable
    let canon: String          // canonical string form, used to match stored values
}

private struct WheelColumnSpec {
    let header: String?
    let variableKey: String?
    let unit: String?
    let width: CGFloat
    let items: [PickerItem]
    let defaultCanon: String?
    /// Numeric bounds for RANGE columns (nil for options columns); used by the
    /// unit-toggle distribution to clamp converted values before snapping.
    let minValue: Double?
    let maxValue: Double?
}

/// Builds a `WheelColumnSpec` from an untyped column dict (shared by the plain
/// wheel path and the unit-toggle systems).
private enum PickerColumnBuilder {
    static func build(_ dict: [String: Any]) -> WheelColumnSpec {
        let header = dict["header"] as? String
        let variableKey = dict["variableKey"] as? String
        let unit = dict["unit"] as? String
        let width = (PickerNumber.asDouble(dict["width"]).map { CGFloat($0 > 0 ? $0 : 1) }) ?? 1

        let items: [PickerItem]
        var minValue: Double? = nil
        var maxValue: Double? = nil

        if let options = PickerNumber.dictArray(dict["options"]), !options.isEmpty {
            items = options.map { opt in
                let (value, canon) = PickerNumber.valueFrom(opt["value"])
                let label = (opt["label"] as? String) ?? canon
                return PickerItem(label: PickerNumber.applyUnit(label, unit), value: value, canon: canon)
            }
        } else {
            let mn = PickerNumber.asDouble(dict["min"]) ?? 0
            let mx = PickerNumber.asDouble(dict["max"]) ?? 100
            var st = PickerNumber.asDouble(dict["step"]) ?? 1
            if st <= 0 { st = 1 }
            minValue = Swift.min(mn, mx)
            maxValue = Swift.max(mn, mx)
            items = PickerNumber.rangeItems(mn, mx, st).map { n in
                PickerItem(label: PickerNumber.applyUnit(PickerNumber.format(n), unit), value: .number(n), canon: PickerNumber.format(n))
            }
        }

        var defaultCanon: String? = nil
        if let dv = dict["defaultValue"], !(dv is NSNull) {
            defaultCanon = PickerNumber.canon(of: dv)
        }

        return WheelColumnSpec(
            header: header,
            variableKey: variableKey,
            unit: unit,
            width: width,
            items: items,
            defaultCanon: defaultCanon,
            minValue: minValue,
            maxValue: maxValue
        )
    }

    /// Initial selection for a column: bound variable → default → middle.
    static func initialIndex(for col: WheelColumnSpec, store: VariableStore) -> Int {
        guard !col.items.isEmpty else { return 0 }
        if let key = col.variableKey, let stored = store.get(key), let i = matchIndex(col.items, stored) {
            return i
        }
        if let dc = col.defaultCanon, let i = col.items.firstIndex(where: { $0.canon == dc }) {
            return i
        }
        return col.items.count / 2
    }

    /// Index of the item matching a stored variable value (number- or string-keyed).
    static func matchIndex(_ items: [PickerItem], _ stored: VariableValue) -> Int? {
        if let d = stored.numberValue, let i = items.firstIndex(where: { $0.canon == PickerNumber.format(d) }) {
            return i
        }
        if let s = stored.stringValue, let i = items.firstIndex(where: { $0.canon == s }) {
            return i
        }
        return nil
    }
}

// MARK: - Proportional Column Layout (grouped headers)

/// A run of consecutive columns sharing ONE centered header. A column's header
/// opens a group; header-less columns extend the current one. So a two-column
/// "Height" wheel (ft + in, header on the ft column) shows a single "Height"
/// title centered across BOTH columns. Mirrors `groupPickerColumns` in the
/// editor's `picker-geometry.ts` (the visual-parity source of truth).
private struct PickerColumnGroupDescriptor {
    let header: String?
    let columnIndices: [Int]   // absolute indices into the flat column array
    let weight: CGFloat        // summed width weight of the member columns
}

/// Group columns (by parallel `headers` / `widths` arrays) into header runs.
private func makePickerGroups(headers: [String?], widths: [CGFloat]) -> [PickerColumnGroupDescriptor] {
    var groups: [PickerColumnGroupDescriptor] = []
    for i in headers.indices {
        let h = headers[i]
        let hasHeader = (h?.isEmpty == false)
        let w = i < widths.count ? widths[i] : 1
        if groups.isEmpty || hasHeader {
            groups.append(PickerColumnGroupDescriptor(header: hasHeader ? h : nil, columnIndices: [i], weight: w))
        } else {
            let last = groups.removeLast()
            groups.append(PickerColumnGroupDescriptor(
                header: last.header,
                columnIndices: last.columnIndices + [i],
                weight: last.weight + w
            ))
        }
    }
    return groups
}

/// Lays columns side by side, each proportional to its `width` weight, with an
/// 8pt gap, centered — matching the editor's `flexGrow: width; flexBasis: 0` row.
/// Columns are grouped under shared headers: each group stacks its centered
/// header above its own columns row. When any group has a header every group
/// reserves the same header height so the wheels stay vertically aligned. Total
/// gap count (= columns - 1) is preserved across the split so the proportional
/// widths line up with the flat editor layout.
private struct PickerColumnGroupLayout<Content: View>: View {
    let groups: [PickerColumnGroupDescriptor]
    let columnWidths: [CGFloat]
    let anyHeader: Bool
    let appearance: PickerAppearance
    @ViewBuilder let content: (Int) -> Content

    private let gap: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let totalWeight = max(0.0001, groups.reduce(0) { $0 + $1.weight })
            let topGaps = gap * CGFloat(max(0, groups.count - 1))
            let topAvailable = max(0, geo.size.width - topGaps)
            let headerTextHeight = appearance.headerReserve - 12

            HStack(alignment: .top, spacing: gap) {
                ForEach(groups.indices, id: \.self) { gi in
                    let group = groups[gi]
                    let groupWidth = topAvailable * group.weight / totalWeight
                    let innerGaps = gap * CGFloat(max(0, group.columnIndices.count - 1))
                    let innerAvailable = max(0, groupWidth - innerGaps)
                    let innerWeight = max(0.0001, group.weight)

                    VStack(spacing: 0) {
                        if anyHeader {
                            Text(group.header ?? "")
                                .font(.system(size: appearance.headerFontSize, weight: .semibold))
                                .foregroundColor(appearance.headerColor)
                                .multilineTextAlignment(.center)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .frame(height: headerTextHeight)
                                .padding(.bottom, 12)
                        }
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(group.columnIndices, id: \.self) { ci in
                                content(ci)
                                    .frame(width: innerAvailable * columnWidths[ci] / innerWeight)
                            }
                        }
                    }
                    .frame(width: groupWidth)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: appearance.viewportHeight + (anyHeader ? appearance.headerReserve : 0))
    }
}

// MARK: - Wheel Column (self-binding, wheel mode)

private struct PickerWheelColumnView: View {
    let spec: WheelColumnSpec
    let appearance: PickerAppearance
    let variableStore: VariableStore
    let renderTrigger: Int
    let fireOnChange: () -> Void

    @State private var index: Int = 0

    var body: some View {
        WheelColumnUI(
            labels: spec.items.map { $0.label },
            selectedIndex: Binding(
                get: { index },
                set: { newIndex in
                    let clamped = max(0, min(spec.items.count - 1, newIndex))
                    index = clamped
                    writeAndFire(clamped)
                }
            ),
            appearance: appearance
        )
        .onAppear { loadInitial() }
        .onChange(of: renderTrigger) { _ in syncFromVariable() }
    }

    private func loadInitial() {
        let items = spec.items
        guard !items.isEmpty else { return }
        if let key = spec.variableKey, let stored = variableStore.get(key), let i = matchIndex(stored) {
            index = i
            return
        }
        if let dc = spec.defaultCanon, let i = items.firstIndex(where: { $0.canon == dc }) {
            index = i
            return
        }
        index = items.count / 2 // middle
    }

    private func matchIndex(_ stored: VariableValue) -> Int? {
        let items = spec.items
        if let d = stored.numberValue, let i = items.firstIndex(where: { $0.canon == PickerNumber.format(d) }) {
            return i
        }
        if let s = stored.stringValue, let i = items.firstIndex(where: { $0.canon == s }) {
            return i
        }
        return nil
    }

    private func syncFromVariable() {
        guard let key = spec.variableKey, let stored = variableStore.get(key), let i = matchIndex(stored) else { return }
        if i != index { index = i }
    }

    private func writeAndFire(_ i: Int) {
        guard i >= 0 && i < spec.items.count else { return }
        if let key = spec.variableKey {
            variableStore.set(key, value: spec.items[i].value)
        }
        fireOnChange()
    }
}

// MARK: - Date Mode

private struct PickerDateView: View {
    let variableKey: String?
    let minDate: String
    let maxDate: String
    let dateOrder: String
    let monthFormat: String
    let defaultValue: String?
    let appearance: PickerAppearance
    let variableStore: VariableStore
    let renderTrigger: Int
    let fireOnChange: () -> Void

    private enum DateCol { case year, month, day }

    @State private var year: Int = 2000
    @State private var month: Int = 1   // 1...12
    @State private var day: Int = 1     // 1...daysInMonth
    @State private var loaded = false

    private var minParts: (year: Int, month: Int, day: Int) {
        PickerDateUtil.parse(minDate) ?? (1900, 1, 1)
    }
    private var maxParts: (year: Int, month: Int, day: Int) {
        PickerDateUtil.parse(maxDate) ?? PickerDateUtil.todayParts()
    }

    private var orderedCols: [DateCol] {
        switch dateOrder {
        case "ymd": return [.year, .month, .day]
        case "dmy": return [.day, .month, .year]
        default: return [.month, .day, .year] // "mdy"
        }
    }

    private func width(for col: DateCol) -> CGFloat {
        switch col {
        case .year: return 1.1
        case .month: return 1.4
        case .day: return 0.9
        }
    }

    var body: some View {
        let cols = orderedCols
        let widths = cols.map { width(for: $0) }
        // Date columns carry no headers, so this is a single header-less group.
        PickerColumnGroupLayout(
            groups: makePickerGroups(headers: cols.map { _ in nil }, widths: widths),
            columnWidths: widths,
            anyHeader: false,
            appearance: appearance
        ) { i in
            columnView(for: cols[i])
        }
        .onAppear {
            if !loaded { loadInitial(); loaded = true }
        }
        .onChange(of: renderTrigger) { _ in syncFromVariable() }
    }

    @ViewBuilder
    private func columnView(for col: DateCol) -> some View {
        switch col {
        case .year:
            let years = yearValues
            WheelColumnUI(
                labels: years.map { String($0) },
                selectedIndex: Binding(
                    get: { max(0, years.firstIndex(of: year) ?? 0) },
                    set: { idx in
                        let safe = max(0, min(years.count - 1, idx))
                        year = years[safe]
                        clampDayAndCommit()
                    }
                ),
                appearance: appearance
            )
        case .month:
            WheelColumnUI(
                labels: (1...12).map { PickerDateUtil.monthLabel($0, format: monthFormat) },
                selectedIndex: Binding(
                    get: { max(0, min(11, month - 1)) },
                    set: { idx in
                        month = max(1, min(12, idx + 1))
                        clampDayAndCommit()
                    }
                ),
                appearance: appearance
            )
        case .day:
            let dim = PickerDateUtil.daysInMonth(year, month)
            WheelColumnUI(
                labels: (1...dim).map { String($0) },
                selectedIndex: Binding(
                    get: { max(0, min(dim - 1, day - 1)) },
                    set: { idx in
                        day = max(1, min(dim, idx + 1))
                        commit()
                    }
                ),
                appearance: appearance
            )
        }
    }

    private var yearValues: [Int] {
        let lo = min(minParts.year, maxParts.year)
        let hi = max(minParts.year, maxParts.year)
        return Array(lo...hi)
    }

    private func loadInitial() {
        let mn = minParts
        let mx = maxParts
        let bound = variableKey.flatMap { variableStore.get($0)?.stringValue }
        let selected = PickerDateUtil.parse(bound) ?? PickerDateUtil.parse(defaultValue) ?? mx
        year = max(min(mn.year, mx.year), min(max(mn.year, mx.year), selected.year))
        month = max(1, min(12, selected.month))
        day = max(1, min(PickerDateUtil.daysInMonth(year, month), selected.day))
    }

    private func syncFromVariable() {
        guard let key = variableKey, let stored = variableStore.get(key)?.stringValue,
              let parts = PickerDateUtil.parse(stored) else { return }
        let newDay = max(1, min(PickerDateUtil.daysInMonth(parts.year, parts.month), parts.day))
        if parts.year != year || parts.month != month || newDay != day {
            year = parts.year
            month = parts.month
            day = newDay
        }
    }

    private func clampDayAndCommit() {
        let dim = PickerDateUtil.daysInMonth(year, month)
        if day > dim { day = dim }
        if day < 1 { day = 1 }
        commit()
    }

    private func commit() {
        let iso = String(format: "%04d-%02d-%02d", year, month, day)
        if let key = variableKey {
            variableStore.set(key, value: .string(iso))
        }
        fireOnChange()
    }
}

// MARK: - Unit Toggle (Imperial / Metric)

/// The mass/length unit table + scalar conversions live in the shared
/// `UnitSystem` (UnitSystem.swift), single-sourced with the `ruler` primitive.
/// The picker keeps its own column distribution math below (the ft+in split),
/// looking units up via `UnitSystem.info`.

private struct UnitSystemOption {
    let key: String
    let label: String
    let columns: [WheelColumnSpec]
}

private struct UnitToggleConfig {
    let systemVariableKey: String?
    let defaultKey: String?
    let canonicalKey: String
    /// "segmented" (the Imperial|Metric pill) or "switch" (a label on each side
    /// of an iOS toggle). "switch" requires exactly two options; otherwise the
    /// view degrades to the segmented control. Mirrors the editor `toggleStyle`.
    let toggleStyle: String
    let options: [UnitSystemOption]
}

/// The "switch"-style toggle geometry lives in the shared `UnitSwitchMetrics`
/// (UnitSystem.swift), single-sourced with the `ruler` primitive's switch.

/// Wheel picker with an Imperial/Metric segmented control above the columns.
/// Switching systems preserves the underlying physical value (e.g. 150 lb → 68 kg)
/// and always writes a normalized canonical variable. See the picker contract.
private struct PickerUnitToggleView: View {
    let config: UnitToggleConfig
    let appearance: PickerAppearance
    let variableStore: VariableStore
    let renderTrigger: Int
    let fireOnChange: () -> Void

    @State private var activeKey: String = ""
    @State private var indices: [Int] = []
    @State private var loaded = false

    private var activeOption: UnitSystemOption? {
        config.options.first(where: { $0.key == activeKey }) ?? config.options.first
    }

    /// Render the side-by-side switch only when opted in AND there are exactly
    /// two systems (a binary switch); otherwise fall back to the segmented pill.
    private var usesSwitch: Bool {
        config.toggleStyle == "switch" && config.options.count == 2
    }

    var body: some View {
        VStack(spacing: 0) {
            if usesSwitch {
                switchControl
                    .padding(.bottom, 16)
            } else {
                segmentedControl
                    .padding(.bottom, 16)
            }

            if let opt = activeOption {
                let headers = opt.columns.map { $0.header }
                PickerColumnGroupLayout(
                    groups: makePickerGroups(headers: headers, widths: opt.columns.map { $0.width }),
                    columnWidths: opt.columns.map { $0.width },
                    anyHeader: headers.contains { $0?.isEmpty == false },
                    appearance: appearance
                ) { i in
                    columnView(opt: opt, index: i)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { if !loaded { loadInitial(); loaded = true } }
        .onChange(of: renderTrigger) { _ in syncFromVariable() }
    }

    // MARK: Segmented control

    private var segmentedControl: some View {
        HStack(spacing: 0) {
            ForEach(config.options.indices, id: \.self) { idx in
                let opt = config.options[idx]
                let active = opt.key == activeKey
                Text(opt.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(active ? appearance.selectedTextColor : appearance.textColor)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(active ? Color.white : Color.clear)
                            .shadow(color: active ? Color.black.opacity(0.12) : Color.clear, radius: 2, x: 0, y: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { switchSystem(to: opt.key) }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(appearance.selectionColor))
    }

    // MARK: Switch control (label ─◯─ label)

    /// A label on each side of an iOS-style switch. The FIRST option is the OFF
    /// (knob-left) position, the SECOND is ON (knob-right). Tapping the switch
    /// toggles to the other system; tapping a label selects that side. The active
    /// side's label is emphasised. Mirrors the editor `SwitchControl`.
    private var switchControl: some View {
        let firstKey = config.options[0].key
        let secondKey = config.options[1].key
        let knobRight = activeKey == secondKey
        let m = UnitSwitchMetrics.self

        return HStack(spacing: m.labelGap) {
            switchLabel(config.options[0].label, active: !knobRight)
                .onTapGesture { switchSystem(to: firstKey) }

            ZStack(alignment: knobRight ? .trailing : .leading) {
                Capsule()
                    .fill(m.trackColor)
                    .frame(width: m.trackWidth, height: m.trackHeight)
                Circle()
                    .fill(m.knobColor)
                    .frame(width: m.knobSize, height: m.knobSize)
                    .shadow(color: Color.black.opacity(0.18), radius: 1.5, x: 0, y: 1)
                    .padding(m.knobPadding)
            }
            .frame(width: m.trackWidth, height: m.trackHeight)
            .contentShape(Rectangle())
            .onTapGesture { switchSystem(to: knobRight ? firstKey : secondKey) }

            switchLabel(config.options[1].label, active: knobRight)
                .onTapGesture { switchSystem(to: secondKey) }
        }
    }

    private func switchLabel(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: UnitSwitchMetrics.labelFontSize, weight: active ? .bold : .semibold))
            .foregroundColor(active ? appearance.selectedTextColor : appearance.textColor)
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func columnView(opt: UnitSystemOption, index: Int) -> some View {
        let col = opt.columns[index]
        WheelColumnUI(
            labels: col.items.map { $0.label },
            selectedIndex: Binding(
                get: { index < indices.count ? indices[index] : 0 },
                set: { newIdx in
                    guard index < indices.count, !col.items.isEmpty else { return }
                    indices[index] = max(0, min(col.items.count - 1, newIdx))
                    onColumnChange(opt: opt, index: index)
                }
            ),
            appearance: appearance
        )
    }

    // MARK: State

    private func loadInitial() {
        activeKey = resolveInitialKey()
        guard let opt = activeOption else { return }
        indices = opt.columns.map { PickerColumnBuilder.initialIndex(for: $0, store: variableStore) }
        // Populate canonical vars on load so they're available pre-interaction.
        writeCanonical(from: opt)
    }

    private func resolveInitialKey() -> String {
        func valid(_ k: String?) -> String? {
            guard let k, config.options.contains(where: { $0.key == k }) else { return nil }
            return k
        }
        let stored = config.systemVariableKey.flatMap { variableStore.get($0)?.stringValue }
        return valid(stored)
            ?? valid(config.defaultKey)
            ?? valid(config.canonicalKey)
            ?? config.options.first?.key
            ?? ""
    }

    private func syncFromVariable() {
        // External system switch.
        if let key = config.systemVariableKey,
           let k = variableStore.get(key)?.stringValue,
           k != activeKey, config.options.contains(where: { $0.key == k }) {
            activeKey = k
            if let opt = activeOption {
                indices = opt.columns.map { PickerColumnBuilder.initialIndex(for: $0, store: variableStore) }
            }
            return
        }
        // External column-value change (also reads back our own writes idempotently).
        guard let opt = activeOption else { return }
        var updated = indices
        var changed = false
        for (i, col) in opt.columns.enumerated() where i < updated.count {
            if let key = col.variableKey, let stored = variableStore.get(key),
               let m = PickerColumnBuilder.matchIndex(col.items, stored), m != updated[i] {
                updated[i] = m
                changed = true
            }
        }
        if changed { indices = updated }
    }

    // MARK: Interaction

    private func onColumnChange(opt: UnitSystemOption, index: Int) {
        guard index < opt.columns.count, index < indices.count else { return }
        let col = opt.columns[index]
        let sel = indices[index]
        if let key = col.variableKey, sel >= 0, sel < col.items.count {
            variableStore.set(key, value: col.items[sel].value)
        }
        writeCanonical(from: opt)
        fireOnChange()
    }

    private func switchSystem(to newKey: String) {
        guard newKey != activeKey,
              let current = activeOption,
              let target = config.options.first(where: { $0.key == newKey }) else { return }

        // 1. canonical base from the CURRENT active system.
        let base = canonicalBase(of: current, indices: indices)

        // 2. switch + persist the active system key.
        activeKey = newKey
        if let key = config.systemVariableKey { variableStore.set(key, value: .string(newKey)) }

        // 3. distribute base into the target columns (defaults first, then overrides).
        var newIndices = target.columns.map { PickerColumnBuilder.initialIndex(for: $0, store: variableStore) }
        distribute(base: base, into: target, indices: &newIndices)
        indices = newIndices

        // 4. write each target column var, then canonical, then fire.
        for (i, col) in target.columns.enumerated() where i < newIndices.count {
            let sel = newIndices[i]
            if let key = col.variableKey, sel >= 0, sel < col.items.count {
                variableStore.set(key, value: col.items[sel].value)
            }
        }
        writeCanonical(from: target)
        fireOnChange()

        #if canImport(UIKit)
        if appearance.haptics { UISelectionFeedbackGenerator().selectionChanged() }
        #endif
    }

    // MARK: Conversion

    /// canonical_base[dim] = Σ (selectedValue / perBase(unit)) over the option's
    /// in-table columns of that dimension.
    private func canonicalBase(of option: UnitSystemOption, indices idx: [Int]) -> [String: Double] {
        var sums: [String: Double] = [:]
        for (i, col) in option.columns.enumerated() where i < idx.count {
            guard let info = UnitSystem.info(col.unit) else { continue }
            let sel = idx[i]
            guard sel >= 0, sel < col.items.count, let value = col.items[sel].value.numberValue else { continue }
            sums[info.dimension, default: 0] += value / info.perBase
        }
        return sums
    }

    /// Write the canonical system's columns from the active system's base sums.
    /// Runs on every change so canonical (normalized) vars are always populated.
    private func writeCanonical(from option: UnitSystemOption) {
        let base = canonicalBase(of: option, indices: indices)
        guard let canon = config.options.first(where: { $0.key == config.canonicalKey }) else { return }
        for col in canon.columns {
            guard let info = UnitSystem.info(col.unit), let key = col.variableKey,
                  let b = base[info.dimension] else { continue }
            variableStore.set(key, value: .number((b * info.perBase).rounded()))
        }
    }

    /// Distribute base sums into the target system's columns, per dimension group,
    /// largest unit first (ascending perBase). In-table columns with an available
    /// base are overridden; others keep their default selection.
    private func distribute(base: [String: Double], into option: UnitSystemOption, indices idx: inout [Int]) {
        var groups: [String: [Int]] = [:]
        for (i, col) in option.columns.enumerated() {
            if let info = UnitSystem.info(col.unit) { groups[info.dimension, default: []].append(i) }
        }

        for (dim, positions) in groups {
            guard let canonBase = base[dim] else { continue } // unavailable → keep defaults

            let ordered = positions.sorted {
                (UnitSystem.info(option.columns[$0].unit)?.perBase ?? 0) < (UnitSystem.info(option.columns[$1].unit)?.perBase ?? 0)
            }
            // Smallest unit = the one with the LARGEST perBase in the group.
            let smallestPerBase = ordered.compactMap { UnitSystem.info(option.columns[$0].unit)?.perBase }.max() ?? 1
            var totalSmall = canonBase * smallestPerBase

            for (k, pos) in ordered.enumerated() {
                let col = option.columns[pos]
                let perBase = UnitSystem.info(col.unit)?.perBase ?? 1
                if k < ordered.count - 1 {
                    let unitsPerSmall = smallestPerBase / perBase
                    let colVal = floor(totalSmall / unitsPerSmall + 1e-9)
                    let snapped = snap(col, target: colVal)
                    idx[pos] = snapped.index
                    totalSmall -= snapped.value * unitsPerSmall
                } else {
                    let snapped = snap(col, target: totalSmall.rounded())
                    idx[pos] = snapped.index
                }
            }
        }
    }

    /// Clamp `target` to the column's bounds, then snap to the nearest numeric item.
    private func snap(_ col: WheelColumnSpec, target: Double) -> (index: Int, value: Double) {
        guard !col.items.isEmpty else { return (0, target) }
        var t = target
        if let mn = col.minValue { t = max(mn, t) }
        if let mx = col.maxValue { t = min(mx, t) }
        var best = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, item) in col.items.enumerated() {
            guard let v = item.value.numberValue else { continue }
            let d = abs(v - t)
            if d < bestDist { bestDist = d; best = i }
        }
        let value = col.items[best].value.numberValue ?? t
        return (best, value)
    }
}

// MARK: - Wheel Column UI (header + selection band + scroll wheel)

private struct WheelColumnUI: View {
    let labels: [String]
    @Binding var selectedIndex: Int
    let appearance: PickerAppearance

    var body: some View {
        // The column header is rendered by `PickerColumnGroupLayout` above the
        // group so a multi-column wheel shows one centered title; this view is
        // just the wheel viewport.
        ZStack {
            selectionBand
            PickerSnapScrollView(labels: labels, selectedIndex: $selectedIndex, appearance: appearance)
        }
        .frame(height: appearance.viewportHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var selectionBand: some View {
        let ih = appearance.itemHeight
        switch appearance.selectionStyle {
        case "pill":
            Capsule()
                .fill(appearance.selectionColor)
                .frame(height: ih)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case "lines":
            ZStack {
                Rectangle().fill(appearance.selectionColor).frame(height: 1).offset(y: -ih / 2)
                Rectangle().fill(appearance.selectionColor).frame(height: 1).offset(y: ih / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        default: // "none"
            EmptyView()
        }
    }
}

// MARK: - Opacity falloff (matches editor `rowOpacity`)

/// Per-row opacity by (continuous) distance from the centered row, interpolating
/// the editor's discrete anchors so the at-rest values are exact (dist 0 -> 1,
/// 1 -> 0.5, 2 -> 0.25, >=3 -> 0.15) while live scroll stays smooth.
private func pickerRowOpacity(_ distance: CGFloat) -> CGFloat {
    if distance <= 0 { return 1 }
    if distance < 1 { return 1 - 0.5 * distance }
    if distance < 2 { return 0.5 - 0.25 * (distance - 1) }
    if distance < 3 { return 0.25 - 0.10 * (distance - 2) }
    return 0.15
}

// MARK: - UIKit Snap Scroll Wheel

#if canImport(UIKit)

/// Container view that notifies when layout occurs (so we can do initial setup
/// once bounds are known). Ported from the DemoApp wheel picker.
final class PickerSnapContainer: UIView {
    let scrollView = UIScrollView()
    let contentView = UIView()
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        onLayout?()
    }
}

/// UIScrollView-backed scroll-snap wheel. Renders `labels` as stacked, centered
/// rows with per-row opacity falloff, snaps to the nearest detent, and commits
/// `selectedIndex` on settle. Adapted from the DemoApp's `SnapScrollView`.
private struct PickerSnapScrollView: UIViewRepresentable {
    let labels: [String]
    @Binding var selectedIndex: Int
    let appearance: PickerAppearance

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PickerSnapContainer {
        let container = PickerSnapContainer()
        container.scrollView.showsVerticalScrollIndicator = false
        container.scrollView.showsHorizontalScrollIndicator = false
        container.scrollView.delegate = context.coordinator
        container.scrollView.decelerationRate = .fast
        container.scrollView.bounces = true
        container.scrollView.backgroundColor = .clear
        container.scrollView.addSubview(container.contentView)
        context.coordinator.contentView = container.contentView
        context.coordinator.scrollView = container.scrollView

        let coordinator = context.coordinator
        container.onLayout = { [weak coordinator] in coordinator?.performInitialSetup() }
        return container
    }

    func updateUIView(_ container: PickerSnapContainer, context: Context) {
        context.coordinator.parent = self
        if container.scrollView.bounds.width > 0 {
            context.coordinator.performInitialSetup()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: PickerSnapScrollView
        weak var contentView: UIView?
        weak var scrollView: UIScrollView?
        var rowLabels: [UILabel] = []
        var lastTickIndex: Int = -1
        var isUserScrolling = false
        let haptic = UISelectionFeedbackGenerator()

        init(_ parent: PickerSnapScrollView) {
            self.parent = parent
            super.init()
            haptic.prepare()
        }

        private var itemHeight: CGFloat { parent.appearance.itemHeight }
        private var viewHeight: CGFloat { parent.appearance.viewportHeight }

        func performInitialSetup() {
            guard let scrollView, let contentView, scrollView.bounds.width > 0 else { return }
            let count = parent.labels.count
            guard count > 0 else { return }

            let topInset = (viewHeight - itemHeight) / 2
            let contentHeight = CGFloat(count) * itemHeight
            scrollView.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: topInset, right: 0)
            scrollView.contentSize = CGSize(width: scrollView.bounds.width, height: contentHeight)
            contentView.frame = CGRect(x: 0, y: 0, width: scrollView.bounds.width, height: contentHeight)

            let needsInitialScroll = setupLabels(in: scrollView)
            let index = max(0, min(count - 1, parent.selectedIndex))
            let targetOffset = CGFloat(index) * itemHeight - topInset
            if needsInitialScroll || (abs(scrollView.contentOffset.y - targetOffset) > 1 && !isUserScrolling) {
                scrollView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
            }
            updateLabelAppearances(scrollView: scrollView)
        }

        @discardableResult
        private func setupLabels(in scrollView: UIScrollView) -> Bool {
            guard let contentView, scrollView.bounds.width > 0 else { return false }
            let isInitial = rowLabels.isEmpty
            let values = parent.labels

            if rowLabels.count != values.count {
                rowLabels.forEach { $0.removeFromSuperview() }
                rowLabels.removeAll()
                for (i, text) in values.enumerated() {
                    let label = UILabel()
                    label.text = text
                    label.textAlignment = .center
                    label.frame = CGRect(x: 0, y: CGFloat(i) * itemHeight, width: scrollView.bounds.width, height: itemHeight)
                    label.isUserInteractionEnabled = true
                    label.tag = i
                    let tap = UITapGestureRecognizer(target: self, action: #selector(labelTapped(_:)))
                    label.addGestureRecognizer(tap)
                    contentView.addSubview(label)
                    rowLabels.append(label)
                }
                lastTickIndex = max(0, min(values.count - 1, parent.selectedIndex))
            } else {
                for (i, label) in rowLabels.enumerated() {
                    if label.text != values[i] { label.text = values[i] }
                    let ey = CGFloat(i) * itemHeight
                    if label.frame.width != scrollView.bounds.width || label.frame.origin.y != ey {
                        label.frame = CGRect(x: 0, y: ey, width: scrollView.bounds.width, height: itemHeight)
                    }
                }
            }

            updateLabelAppearances(scrollView: scrollView)
            return isInitial && !rowLabels.isEmpty
        }

        @objc func labelTapped(_ gesture: UITapGestureRecognizer) {
            guard let label = gesture.view as? UILabel else { return }
            let index = label.tag
            guard index >= 0 && index < parent.labels.count, let scrollView else { return }
            if parent.appearance.haptics { haptic.selectionChanged() }
            let topInset = scrollView.contentInset.top
            let target = CGFloat(index) * itemHeight - topInset
            scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
            // selection commits on the resulting didEndScrollingAnimation callback
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserScrolling = true
            haptic.prepare()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let topInset = scrollView.contentInset.top
            let centerOffset = scrollView.contentOffset.y + topInset
            let idx = Int((centerOffset / itemHeight).rounded())
            if idx >= 0 && idx < parent.labels.count && idx != lastTickIndex {
                lastTickIndex = idx
                if parent.appearance.haptics { haptic.selectionChanged() }
            }
            updateLabelAppearances(scrollView: scrollView)
        }

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            let topInset = scrollView.contentInset.top
            let targetY = targetContentOffset.pointee.y + topInset
            let nearest = max(0, min(parent.labels.count - 1, Int((targetY / itemHeight).rounded())))
            targetContentOffset.pointee.y = CGFloat(nearest) * itemHeight - topInset
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { isUserScrolling = false; commit(scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            isUserScrolling = false
            commit(scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isUserScrolling = false
            commit(scrollView)
        }

        private func commit(_ scrollView: UIScrollView) {
            let topInset = scrollView.contentInset.top
            let centerOffset = scrollView.contentOffset.y + topInset
            let nearest = max(0, min(parent.labels.count - 1, Int((centerOffset / itemHeight).rounded())))
            if nearest != parent.selectedIndex {
                parent.selectedIndex = nearest
            }
            updateLabelAppearances(scrollView: scrollView)
        }

        private func updateLabelAppearances(scrollView: UIScrollView) {
            let topInset = scrollView.contentInset.top
            let centerY = scrollView.contentOffset.y + topInset + itemHeight / 2
            let app = parent.appearance
            let textColor = UIColor(app.textColor)
            let selectedColor = UIColor(app.selectedTextColor)

            for (i, label) in rowLabels.enumerated() {
                let labelCenterY = CGFloat(i) * itemHeight + itemHeight / 2
                let distance = abs(labelCenterY - centerY) / itemHeight
                if distance < 0.5 {
                    label.font = .systemFont(ofSize: app.selectedFontSize, weight: .semibold)
                    label.textColor = selectedColor
                    label.alpha = 1
                } else {
                    label.font = .systemFont(ofSize: app.fontSize, weight: .regular)
                    label.textColor = textColor
                    label.alpha = pickerRowOpacity(distance)
                }
            }
        }
    }
}

#else

// Fallback for non-UIKit platforms (macOS): a native wheel-style Picker. Parity
// is a best-effort here; iOS is the visual gate.
private struct PickerSnapScrollView: View {
    let labels: [String]
    @Binding var selectedIndex: Int
    let appearance: PickerAppearance

    var body: some View {
        Picker("", selection: $selectedIndex) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, text in
                Text(text).tag(i)
            }
        }
        .labelsHidden()
    }
}

#endif

// MARK: - Numeric / value helpers

private enum PickerNumber {
    /// Coerce a JSON-decoded value to a Double.
    static func asDouble(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let f as CGFloat: return Double(f)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// Conditionally downcast a JSON-decoded array to `[[String: Any]]`.
    static func dictArray(_ value: Any?) -> [[String: Any]]? {
        guard let arr = value as? [Any] else { return value as? [[String: Any]] }
        let dicts = arr.compactMap { $0 as? [String: Any] }
        return dicts.isEmpty ? nil : dicts
    }

    /// Format a number the way the editor does: integral values drop the decimal
    /// ("5"), fractional values stay compact ("0.5").
    static func format(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 {
            return String(Int(n))
        }
        return String(format: "%g", n)
    }

    /// Build the integer/step item list for a RANGE column (min..max by step),
    /// rounding to avoid float drift. Capped so a degenerate range can't blow up.
    static func rangeItems(_ minV: Double, _ maxV: Double, _ step: Double) -> [Double] {
        let s = step > 0 ? step : 1
        let lo = Swift.min(minV, maxV)
        let hi = Swift.max(minV, maxV)
        var out: [Double] = []
        var v = lo
        var count = 0
        let maxItems = 10000
        while v <= hi + 1e-9 && count < maxItems {
            out.append((v * 1e6).rounded() / 1e6)
            v += s
            count += 1
        }
        return out
    }

    /// Map an option's raw value to a typed `VariableValue` + its canonical string.
    static func valueFrom(_ value: Any?) -> (VariableValue, String) {
        switch value {
        case let i as Int: return (.number(Double(i)), format(Double(i)))
        case let d as Double: return (.number(d), format(d))
        case let n as NSNumber:
            // Avoid mis-bridging booleans to numbers.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return (.boolean(n.boolValue), n.boolValue ? "true" : "false") }
            return (.number(n.doubleValue), format(n.doubleValue))
        case let b as Bool: return (.boolean(b), b ? "true" : "false")
        case let s as String: return (.string(s), s)
        default: return (.string(""), "")
        }
    }

    /// Canonical string form of a raw (default) value, for matching against items.
    static func canon(of value: Any) -> String {
        if let i = value as? Int { return format(Double(i)) }
        if let d = value as? Double { return format(d) }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return format(n.doubleValue) }
        return ""
    }

    static func applyUnit(_ label: String, _ unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return label }
        return "\(label) \(unit)"
    }
}

// MARK: - Date helpers

private enum PickerDateUtil {
    private static let calendar = Calendar(identifier: .gregorian)
    private static let monthsLong = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
    private static let monthsShort = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    static func parse(_ value: String?) -> (year: Int, month: Int, day: Int)? {
        guard let value, value.count >= 10 else { return nil }
        let parts = value.prefix(10).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return (y, m, d)
    }

    static func todayParts() -> (year: Int, month: Int, day: Int) {
        let c = calendar.dateComponents([.year, .month, .day], from: Date())
        return (c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    static func todayISO() -> String {
        let p = todayParts()
        return String(format: "%04d-%02d-%02d", p.year, p.month, p.day)
    }

    static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        var comps = DateComponents()
        comps.year = year
        comps.month = max(1, min(12, month))
        if let date = calendar.date(from: comps), let range = calendar.range(of: .day, in: .month, for: date) {
            return range.count
        }
        return 31
    }

    static func monthLabel(_ month1to12: Int, format: String) -> String {
        let i = max(0, min(11, month1to12 - 1))
        switch format {
        case "long": return monthsLong[i]
        case "number": return String(month1to12)
        default: return monthsShort[i]
        }
    }
}
