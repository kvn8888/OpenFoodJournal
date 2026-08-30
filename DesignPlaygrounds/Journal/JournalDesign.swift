// OpenFoodJournal visual scratchpad — intentionally duplicated, not app code.
// Edit this file like CSS. Nothing here reads or writes your real food journal.
// Search MARK to jump between styling, screen sections, sample data, and previews.
import SwiftUI

// MARK: - 1. EDIT HERE: design values (all dimensions are points, not pixels)

enum JournalStyle {
    static let phoneWidth: CGFloat = 393
    static let phoneHeight: CGFloat = 852
    static let pageInset: CGFloat = 16
    static let sectionGap: CGFloat = 20
    static let titleSize: CGFloat = 34
    static let calorieSize: CGFloat = 32
    static let foodNameSize: CGFloat = 17
    static let rowVerticalPadding: CGFloat = 12
    // Overlapping glass entry chips; separate from the large nutrient rings.
    static let entryMacroDiameter: CGFloat = 40
    static let entryMacroOverlap: CGFloat = 3
    static let entryMacroGlassTintOpacity: Double = 0.7
    static let entryMacroNumberSize: CGFloat = 13
    static let entryMacroUnitSize: CGFloat = 12
    static let entryProteinColor = Color(red: 0.54, green: 0.58, blue: 1.0)
    static let entryCarbColor = Color(red: 0.26, green: 0.80, blue: 0.10)
    static let entryFatColor = Color(red: 1.0, green: 0.75, blue: 0)
    static let cardPadding: CGFloat = 16
    static let cardRadius: CGFloat = 20
    static let weekdaySize: CGFloat = 12
    static let dayNumberSize: CGFloat = 20
    static let dayHeight: CGFloat = 72
    static let dayRingSize: CGFloat = 40
    static let dayRingStroke: CGFloat = 3
    static let nutrientRingSize: CGFloat = 56
    static let nutrientRingStroke: CGFloat = 4.3
    static let toolbarButtonSize: CGFloat = 44
    static let plusSize: CGFloat = 64
    static let tabBarHeight: CGFloat = 68
    static let accent = Color.blue
    static let overGoal = Color(red: 0xD8 / 255.0, green: 0x66 / 255.0, blue: 0x69 / 255.0)
    static let darkBackground = Color(red: 0.035, green: 0.035, blue: 0.04)

    static func calendarColor(progress: Double) -> Color {
        switch progress {
        case ..<0.80: .primary
        case ..<0.95: .green.opacity(0.5)
        case ..<1.05: .green
        default: overGoal
        }
    }

    static func gradient(progress: Double) -> [Color] {
        switch progress {
        case ..<0.95: [.yellow.opacity(0.13), .orange.opacity(0.08), .clear]
        case ..<1.05: [.green.opacity(0.14), .green.opacity(0.05), .clear]
        default: [.orange.opacity(0.15), overGoal.opacity(0.10), .clear]
        }
    }
}

// MARK: - 2. Journal screen composition
// Equivalent app file: Views/DailyLog/DailyLogView.swift.
// Header/tab bar are hand-drawn approximations of iOS chrome, not native iOS UI.

struct JournalDesign: View {
    var scenario: JournalScenario = .typical
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDay = 21
    @State private var menuExpanded = false
    @State private var selectedTab = "Journal"

    private var day: SampleDay { SampleDay.make(number: selectedDay, scenario: scenario) }

    var body: some View {
        ZStack(alignment: .bottom) {
            (colorScheme == .dark ? JournalStyle.darkBackground : Color.white)
            RadialGradient(
                colors: JournalStyle.gradient(progress: day.progress),
                center: .top, startRadius: 16, endRadius: 640
            )

            VStack(spacing: 0) {
                // Decorative status bar makes the composition phone-sized.
                HStack {
                    Text("9:41").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: "cellularbars")
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100percent")
                }
                .font(.system(size: 13))
                .padding(.horizontal, 28)
                .frame(height: 44)
                .accessibilityHidden(true)

                JournalHeader(selectedDay: $selectedDay)

                ScrollView {
                    VStack(spacing: JournalStyle.sectionGap) {
                        JournalCalendar(selectedDay: $selectedDay, scenario: scenario)
                        JournalMacroCard(day: day)

                        if scenario == .empty {
                            VStack(spacing: 12) {
                                Image(systemName: "fork.knife.circle")
                                    .font(.system(size: 44, weight: .light))
                                Text("No entries yet").font(.system(size: 20, weight: .semibold))
                                Text("Tap + to log your first meal.")
                                    .font(.system(size: 15)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 48)
                        } else {
                            ForEach(day.meals) { meal in
                                JournalMealSection(meal: meal)
                            }
                        }
                    }
                    .padding(.horizontal, JournalStyle.pageInset)
                    .padding(.top, 8)
                    .padding(.bottom, 172)
                }
                .scrollIndicators(.hidden)
            }

            VStack(spacing: 12) {
                JournalRadialMenu(isExpanded: $menuExpanded)
                JournalTabBar(selectedTab: $selectedTab)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .foregroundStyle(.primary)
        .tint(JournalStyle.accent)
        .frame(width: JournalStyle.phoneWidth, height: JournalStyle.phoneHeight)
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 32))
        .onChange(of: scenario) { menuExpanded = false }
        // No global animation: keep changing numbers scoped to their own views.
    }
}

// MARK: - 3. Header / Today + gear

private struct JournalHeader: View {
    @Binding var selectedDay: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsNotice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                // Approximation only: real app uses stable native ToolbarItems.
                HStack(spacing: 0) {
                    if selectedDay != 21 {
                        Button("Today") {
                            withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) {
                                selectedDay = 21
                            }
                        }
                        .font(.system(size: 17))
                        .padding(.leading, 14).padding(.trailing, 6)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    Button { showsNotice = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 23))
                            .frame(width: JournalStyle.toolbarButtonSize, height: JournalStyle.toolbarButtonSize)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("Settings preview information")
                }
                .buttonStyle(.plain)
                .foregroundStyle(JournalStyle.accent)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            Text("August 2026")
                .font(.system(size: JournalStyle.titleSize, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, JournalStyle.pageInset)
        .padding(.bottom, 12)
        .alert("Design playground", isPresented: $showsNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This button is for styling only. It cannot open or change your app settings.")
        }
    }
}

// MARK: - 4. Calendar (one sample week; Friday 21 is the fixed 'today')
// Equivalent app file: Views/DailyLog/WeeklyCalendarStrip.swift.

private struct JournalCalendar: View {
    @Binding var selectedDay: Int
    let scenario: JournalScenario

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SampleDay.week, id: \.id) { date in
                JournalDayCell(
                    number: date.number, weekday: date.weekday,
                    progress: SampleDay.make(number: date.number, scenario: scenario).progress,
                    selected: selectedDay == date.number,
                    future: date.number > 21
                ) { selectedDay = date.number }
            }
        }
    }
}

private struct JournalDayCell: View {
    let number: Int
    let weekday: String
    let progress: Double
    let selected: Bool
    let future: Bool
    let select: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                Text(weekday)
                    .font(.system(size: JournalStyle.weekdaySize, weight: .semibold))
                ZStack {
                    Circle().stroke(
                        Color.secondary.opacity(0.16),
                        style: StrokeStyle(lineWidth: JournalStyle.dayRingStroke, lineCap: .round,
                                           dash: future ? [3, 4] : [])
                    )
                    if !future {
                        Circle().trim(from: 0, to: min(max(progress, 0), 1))
                            .stroke(JournalStyle.calendarColor(progress: progress),
                                    style: StrokeStyle(lineWidth: JournalStyle.dayRingStroke, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: progress)
                    }
                    Text(number, format: .number)
                        .font(.system(size: JournalStyle.dayNumberSize, weight: selected ? .bold : .regular))
                }
                .frame(width: JournalStyle.dayRingSize, height: JournalStyle.dayRingSize)
            }
            .frame(maxWidth: .infinity)
            .frame(height: JournalStyle.dayHeight)
            .background {
                if selected || hovered {
                    RoundedRectangle(cornerRadius: 14).fill(.thinMaterial)
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)) }
                }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .opacity(future ? 0.4 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(future)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(weekday), August \(number)")
        .accessibilityValue(future ? "Future day" : "\(Int(progress * 100)) percent of goal")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 5. Calorie card / nutrient rings
// Equivalent app files: MacroSummaryBar.swift and Shared/MacroRingView.swift.

private struct JournalMacroCard: View {
    let day: SampleDay

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(day.calories, format: .number.precision(.fractionLength(0)))
                    .font(.system(size: JournalStyle.calorieSize, weight: .bold, design: .rounded))
                    .modifier(DesignNumber(value: day.calories))
                Text("/ 2,500 kcal").font(.system(size: 15)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(day.nutrients) { nutrient in
                    JournalNutrientRing(nutrient: nutrient)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .padding(JournalStyle.cardPadding)
        .glassEffect(.regular, in: .rect(cornerRadius: JournalStyle.cardRadius))
    }
}

private struct JournalNutrientRing: View {
    let nutrient: SampleNutrient
    private var isOver: Bool { nutrient.value > nutrient.goal }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().stroke(nutrient.color.opacity(0.1), lineWidth: JournalStyle.nutrientRingStroke)
                Circle().trim(from: 0, to: min(nutrient.value / nutrient.goal, 1))
                    .stroke(isOver ? JournalStyle.overGoal : nutrient.color,
                            style: StrokeStyle(lineWidth: JournalStyle.nutrientRingStroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: -2) {
                    Text(nutrient.value, format: .number.precision(.fractionLength(0)))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(isOver ? JournalStyle.overGoal : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(width: JournalStyle.nutrientRingSize - 16)
                        .modifier(DesignNumber(value: nutrient.value))
                    Text(nutrient.unit).font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            .frame(width: JournalStyle.nutrientRingSize, height: JournalStyle.nutrientRingSize)
            Text(nutrient.name).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(width: JournalStyle.nutrientRingSize).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 6. Meals / food rows / chips
// Equivalent app files: DailyLog/MealSectionView.swift and EntryRowView.swift.

private struct JournalMealSection: View {
    let meal: SampleMeal

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: meal.symbol).font(.system(size: 18))
                Text(meal.name).font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("\(meal.foods.reduce(0) { $0 + $1.calories }) kcal")
                    .font(.system(size: 15))
            }
            .foregroundStyle(.secondary).padding(.vertical, 12)
            ForEach(meal.foods) { food in
                JournalFoodRow(food: food)
                Divider()
            }
        }
    }
}

private struct JournalFoodRow: View {
    let food: SampleFood

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(food.brand).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Text(food.name).font(.system(size: JournalStyle.foodNameSize, weight: .medium)).lineLimit(1)
                Text("\(food.calories) kcal · \(food.time)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            JournalMacroChipGroup(food: food)
        }
        .padding(.vertical, JournalStyle.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }
}

private struct JournalMacroChipGroup: View {
    let food: SampleFood

    private var macros: [(name: String, value: Int, color: Color)] {
        [
            ("Protein", food.protein, JournalStyle.entryProteinColor),
            ("Carbohydrates", food.carbs, JournalStyle.entryCarbColor),
            ("Fat", food.fat, JournalStyle.entryFatColor)
        ]
    }

    var body: some View {
        ZStack {
            // The glass circles share one sampling region. Keep every label
            // above all glass so refraction/overlap cannot obscure its digits.
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: -JournalStyle.entryMacroOverlap) {
                    ForEach(macros, id: \.name) { macro in
                        Circle().fill(.clear)
                            .frame(width: JournalStyle.entryMacroDiameter, height: JournalStyle.entryMacroDiameter)
                            .glassEffect(.regular, in: .circle)
                    }
                }
            }
            HStack(spacing: -JournalStyle.entryMacroOverlap) {
                ForEach(macros, id: \.name) { macro in
                    JournalMacroChip(label: macro.name, value: macro.value, color: macro.color)
                }
            }
        }
        .fixedSize()
    }
}

private struct JournalMacroChip: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: -1) {
            Text(value, format: .number.precision(.fractionLength(0)))
                .font(.system(size: JournalStyle.entryMacroNumberSize, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .modifier(DesignNumber(value: Double(value)))
            Text("G")
                .font(.system(size: JournalStyle.entryMacroUnitSize, weight: .bold))
        }
        .foregroundStyle(color)
        // Reserve a readable text column even when adjacent circles overlap.
        .frame(width: JournalStyle.entryMacroDiameter - JournalStyle.entryMacroOverlap)
        .frame(width: JournalStyle.entryMacroDiameter, height: JournalStyle.entryMacroDiameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value) grams")
        .help("\(label): \(value) grams")
    }
}

// MARK: - 7. Bottom chrome (styling only; never navigates to real app screens)

private struct JournalRadialMenu: View {
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let actions = [
        (id: "foodbank", title: "Food Bank", symbol: "refrigerator", color: Color.purple, x: -132.0, y: -62.0),
        (id: "containers", title: "Containers", symbol: "scalemass", color: Color.orange, x: -49.0, y: -124.0),
        (id: "manual", title: "Manual", symbol: "pencil", color: Color.green, x: 49.0, y: -124.0),
        (id: "scan", title: "Scan", symbol: "camera.fill", color: Color.blue, x: 132.0, y: -62.0)
    ]

    var body: some View {
        GlassEffectContainer(spacing: 20) {
            ZStack {
                // Remove collapsed glass from the hierarchy: opacity alone can
                // leave native glass content visible over the central button.
                if isExpanded {
                    ForEach(actions, id: \.id) { item in
                        VStack(spacing: 6) {
                            Button { toggle() } label: {
                                Image(systemName: item.symbol).font(.system(size: 22))
                                    .foregroundStyle(item.color).frame(width: 52, height: 52)
                                    .glassEffect(.regular.interactive(), in: .circle)
                            }
                            .buttonStyle(.plain).accessibilityLabel("\(item.title) mock action")
                            Text(item.title).font(.system(size: 11, weight: .medium))
                        }
                        .offset(x: item.x, y: item.y)
                        .transition(.opacity.combined(with: .scale(scale: 0.5)))
                    }
                }
                Button(action: toggle) {
                    Image(systemName: "plus").font(.system(size: 32, weight: .medium))
                        .rotationEffect(.degrees(isExpanded ? 45 : 0))
                        .frame(width: JournalStyle.plusSize, height: JournalStyle.plusSize)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain).accessibilityLabel(isExpanded ? "Close menu" : "Add food")
            }
        }
        .frame(height: JournalStyle.plusSize)
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.3)) { isExpanded.toggle() }
    }
}

private struct JournalTabBar: View {
    @Binding var selectedTab: String
    private let tabs = [
        (name: "Journal", symbol: "book.pages"), (name: "Food Bank", symbol: "refrigerator"),
        (name: "History", symbol: "chart.xyaxis.line"), (name: "Assistant", symbol: "sparkles")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.name) { tab in
                Button { selectedTab = tab.name } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol).font(.system(size: 24, weight: .medium))
                        Text(tab.name).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(selectedTab == tab.name ? JournalStyle.accent : Color.primary)
                    .frame(maxWidth: .infinity).frame(height: JournalStyle.tabBarHeight - 8)
                    .background {
                        Capsule().fill(.primary.opacity(selectedTab == tab.name ? 0.07 : 0))
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Changes selection styling only; this playground contains the Journal only")
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct DesignNumber: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .numericText(value: value))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: value)
    }
}

// MARK: - 8. Sample data — edit freely, no persistence or real nutrition claims

enum JournalScenario: String, CaseIterable, Identifiable {
    case typical = "Typical", below = "Below goal", met = "Goal met", over = "Over goal", empty = "Empty"
    var id: String { rawValue }
}

private struct SampleNutrient: Identifiable {
    let name: String
    let value: Double
    let goal: Double
    let unit: String
    let color: Color
    var id: String { name }
}

private struct SampleFood: Identifiable {
    let name: String
    let brand: String
    let calories: Int
    let protein: Int
    let carbs: Int
    let fat: Int
    let time: String
    var id: String { name }
}

private struct SampleMeal: Identifiable {
    let name: String
    let symbol: String
    let foods: [SampleFood]
    var id: String { name }
}

private struct SampleDay {
    let calories: Double
    let meals: [SampleMeal]
    var progress: Double { calories / 2500 }
    var nutrients: [SampleNutrient] {
        let foods = meals.flatMap(\.foods)
        return [
            .init(name: "Protein", value: Double(foods.reduce(0) { $0 + $1.protein }), goal: 150, unit: "g", color: .blue),
            .init(name: "Carbs", value: Double(foods.reduce(0) { $0 + $1.carbs }), goal: 250, unit: "g", color: .green),
            .init(name: "Fat", value: Double(foods.reduce(0) { $0 + $1.fat }), goal: 70, unit: "g", color: .yellow),
            .init(name: "Dietary Fiber", value: calories == 0 ? 0 : 16, goal: 28, unit: "g", color: .black),
            .init(name: "Sodium", value: calories == 0 ? 0 : 2980, goal: 2300, unit: "mg", color: .black)
        ]
    }

    // Fixed calendar so a screenshot/design doesn't change when the real date changes.
    static let week = [
        (id: 16, number: 16, weekday: "SUN"), (id: 17, number: 17, weekday: "MON"),
        (id: 18, number: 18, weekday: "TUE"), (id: 19, number: 19, weekday: "WED"),
        (id: 20, number: 20, weekday: "THU"), (id: 21, number: 21, weekday: "FRI"),
        (id: 22, number: 22, weekday: "SAT")
    ]

    static func make(number: Int, scenario: JournalScenario) -> SampleDay {
        if scenario == .empty || number > 21 { return .init(calories: 0, meals: []) }
        let target: Double
        switch scenario {
        case .typical: target = [16: 2450.0, 17: 1600, 18: 2200, 19: 1200, 20: 2730, 21: 2308][number] ?? 2308
        case .below: target = 1200
        case .met: target = 2500
        case .over: target = 2800
        case .empty: target = 0
        }
        let scale = target / 2308
        func food(_ name: String, _ brand: String, _ calories: Int, _ protein: Int, _ carbs: Int, _ fat: Int, _ time: String) -> SampleFood {
            .init(name: name, brand: brand, calories: Int((Double(calories) * scale).rounded()),
                  protein: Int((Double(protein) * scale).rounded()), carbs: Int((Double(carbs) * scale).rounded()),
                  fat: Int((Double(fat) * scale).rounded()), time: time)
        }
        let meals: [SampleMeal] = [
            .init(name: "Lunch", symbol: "sun.max", foods: [
                food("Beef Franks", "Ball Park", 510, 18, 12, 45, "1:29 PM"),
                food("Enriched Hot Dog Buns", "Stroehmann", 360, 12, 69, 4, "1:29 PM"),
                food("USDA Choice Thin-Sliced Beef", "Costco", 149, 21, 0, 6, "5:15 PM")
            ]),
            .init(name: "Dinner", symbol: "moon.stars", foods: [
                food("White Rice", "Homemade", 415, 8, 90, 1, "7:02 PM"),
                food("Organic Extra Firm Tofu", "Kirkland", 260, 25, 5, 15, "7:02 PM"),
                food("Roasted Vegetables", "Homemade", 354, 10, 50, 13, "7:12 PM")
            ]),
            .init(name: "Snack", symbol: "leaf", foods: [
                food("Greek Yogurt", "Plain", 260, 23, 18, 10, "8:20 PM")
            ])
        ]
        return .init(calories: Double(meals.flatMap(\.foods).reduce(0) { $0 + $1.calories }), meals: meals)
    }
}

// MARK: - 9. Mac-only workbench controls (not part of the phone design)

struct JournalWorkbench: View {
    @State private var scenario: JournalScenario = .typical
    @State private var dark = false
    @State private var zoom = 0.85

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Sample", selection: $scenario) {
                    ForEach(JournalScenario.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 180)
                Toggle("Dark", isOn: $dark).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Text("\(Int(zoom * 100))%")
                Slider(value: $zoom, in: 0.6...1.2, step: 0.05).frame(width: 90)
                    .accessibilityLabel("Preview zoom")
            }
            .padding(12)
            Divider()
            GeometryReader { viewport in
                ScrollView([.horizontal, .vertical]) {
                    JournalDesign(scenario: scenario)
                        .preferredColorScheme(dark ? .dark : .light)
                        .scaleEffect(zoom)
                        .frame(width: JournalStyle.phoneWidth * zoom, height: JournalStyle.phoneHeight * zoom)
                        .padding(24)
                        .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.06))
            Text("SAMPLE DATA ONLY · Edit JournalDesign.swift · Mock iPhone chrome")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
        }
        .frame(minWidth: 500, minHeight: 600)
    }
}

// MARK: - 10. Xcode Canvas previews (select JournalPlayground → My Mac)

#Preview("Journal · Light") {
    JournalDesign().preferredColorScheme(.light)
}

#Preview("Journal · Dark") {
    JournalDesign().preferredColorScheme(.dark)
}

#Preview("Journal · Empty") {
    JournalDesign(scenario: .empty).preferredColorScheme(.light)
}

#Preview("Journal · Over Goal") {
    JournalDesign(scenario: .over).preferredColorScheme(.light)
}
