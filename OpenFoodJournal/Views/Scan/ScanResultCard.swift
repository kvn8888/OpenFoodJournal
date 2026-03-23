// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

/// Slide-up card showing Gemini's parsed nutrition result. All fields are editable before confirming.
struct ScanResultCard: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Bindable var entry: NutritionEntry
    let onConfirm: () -> Void            // Log only
    let onConfirmAndSave: () -> Void     // Log + save to Food Bank
    let onRetake: () -> Void

    @State private var showExtended = false

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(.secondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Food name", text: $entry.name)
                                .font(.title3)
                                .fontWeight(.semibold)

                            if let scanMode = entry.scanMode as ScanMode?,
                               let confidence = entry.confidence,
                               scanMode == .foodPhoto {
                                Label("Estimated (~\(Int(confidence * 100))% confidence)", systemImage: "wand.and.sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else if entry.scanMode == .label {
                                Label("From label", systemImage: "barcode.viewfinder")
                                    .font(.caption)
                                    .foregroundStyle(.teal)
                            }
                        }
                        Spacer()
                        // Meal type picker
                        Picker("Meal", selection: $entry.mealType) {
                            ForEach(MealType.allCases) { type in
                                Label(type.rawValue, systemImage: type.systemImage)
                                    .tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .buttonStyle(.glass)
                    }

                    Divider()

                    // Core macros grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        MacroField(label: "Calories", unit: "kcal", value: $entry.calories, color: .orange)
                        MacroField(label: "Protein", unit: "g", value: $entry.protein, color: .blue)
                        MacroField(label: "Carbs", unit: "g", value: $entry.carbs, color: .green)
                        MacroField(label: "Fat", unit: "g", value: $entry.fat, color: .yellow)
                    }

                    // Extended fields toggle
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            showExtended.toggle()
                        }
                    } label: {
                        HStack {
                            Text(showExtended ? "Hide details" : "Show details")
                                .font(.subheadline)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(showExtended ? 180 : 0))
                                .animation(.spring(duration: 0.3), value: showExtended)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    if showExtended {
                        ExtendedMacroFields(entry: entry)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            // Actions
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 8) {
                    // Primary action — log and save to Food Bank
                    Button(action: onConfirmAndSave) {
                        Label("Add to Log & Save", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)

                    HStack(spacing: 12) {
                        Button("Retake", action: onRetake)
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity)

                        // Log only — no Food Bank save
                        Button("Add to Log", action: onConfirm)
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .ignoresSafeArea(edges: .bottom)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    // Resign first responder globally to dismiss keyboard from any field
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }
}

// MARK: - MacroField

private struct MacroField: View {
    let label: String
    let unit: String
    @Binding var value: Double
    let color: Color

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                TextField("0", text: $text)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .focused($isFocused)
                    .onChange(of: text) { _, newVal in
                        if let d = Double(newVal) { value = d }
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused {
                            text = String(format: "%.1f", value)
                        }
                    }
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .glassEffect(in: .rect(cornerRadius: 14))
        .onAppear {
            text = String(format: "%.1f", value)
        }
    }
}

// MARK: - ExtendedMacroFields

/// Dynamically renders all micronutrients the entry has.
/// Since Gemini can return any nutrient, this view iterates the dictionary
/// rather than hardcoding specific fields.
private struct ExtendedMacroFields: View {
    @Bindable var entry: NutritionEntry

    var body: some View {
        VStack(spacing: 12) {
            // Render each micronutrient as an editable field
            ForEach(entry.sortedMicronutrientNames, id: \.self) { name in
                MicronutrientField(
                    entry: entry,
                    nutrientName: name
                )
            }

            // Serving size (always shown)
            HStack {
                VStack(alignment: .leading) {
                    Text("Serving Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g. 170g", text: Binding(
                        get: { entry.servingSize ?? "" },
                        set: { entry.servingSize = $0.isEmpty ? nil : $0 }
                    ))
                    .font(.subheadline)
                }
                Spacer()
            }
            .padding(12)
            .glassEffect(in: .rect(cornerRadius: 14))
        }
    }
}

/// Editable field for a single micronutrient in the scan result card.
/// Reads/writes directly to the entry's micronutrients dictionary.
private struct MicronutrientField: View {
    let entry: NutritionEntry
    let nutrientName: String

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var unit: String {
        entry.micronutrients[nutrientName]?.unit ?? "g"
    }

    var body: some View {
        HStack {
            Text(nutrientName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 2) {
                TextField("—", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 60)
                    .focused($isFocused)
                    .onChange(of: text) { _, newVal in
                        if let d = Double(newVal) {
                            entry.micronutrients[nutrientName] = MicronutrientValue(value: d, unit: unit)
                        }
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused, let micro = entry.micronutrients[nutrientName] {
                            text = String(format: "%.1f", micro.value)
                        }
                    }
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            if let micro = entry.micronutrients[nutrientName] {
                text = String(format: "%.1f", micro.value)
            }
        }
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        Color.black.ignoresSafeArea()
        ScanResultCard(
            entry: NutritionEntry.preview,
            onConfirm: {},
            onConfirmAndSave: {},
            onRetake: {}
        )
        .frame(maxHeight: 600)
    }
}
