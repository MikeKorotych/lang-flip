import SwiftUI

struct DictationTranscriptionModePicker: View {
    var title: String? = nil
    var detail: String? = nil

    @AppStorage(DictationTranscriptionMode.storageKey)
    private var rawMode = DictationTranscriptionMode.fast.rawValue

    private var selectedMode: DictationTranscriptionMode {
        DictationTranscriptionMode(rawValue: rawMode) ?? .fast
    }

    private var selection: Binding<DictationTranscriptionMode> {
        Binding(
            get: { selectedMode },
            set: { rawMode = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || detail != nil {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            Text(title)
                                .font(.system(size: 14))
                                .foregroundColor(FlowTheme.ink)
                        }
                        if let detail {
                            Text(detail)
                                .font(.system(size: 12))
                                .foregroundColor(FlowTheme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 12)

                    segmentedControl
                }
            } else {
                segmentedControl
            }
        }
    }

    private var segmentedControl: some View {
        FlowSegmented(
            items: DictationTranscriptionMode.allCases.map {
                (value: $0, label: $0.displayName)
            },
            selection: selection
        )
    }
}
