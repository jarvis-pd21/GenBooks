import SwiftUI

/// Shared Half / Full control on Living Apply and Make Living regen sheets.
/// Default selection is owned by the caller (`AdaptationLengthPreset.applyDefault` = Half).
struct AdaptationLengthPicker: View {
    @Binding var selection: AdaptationLengthPreset

    var body: some View {
        Picker("Length", selection: $selection) {
            ForEach(AdaptationLengthPreset.allCases) { preset in
                Text(preset.displayName)
                    .tag(preset)
                    .accessibilityIdentifier("adapt.apply.length.\(preset.rawValue)")
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("adapt.apply.length")
        .accessibilityLabel("Apply length")
        .accessibilityValue(selection.displayName)
    }
}
