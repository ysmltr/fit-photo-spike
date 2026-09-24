import SwiftUI

struct RatioChooser: View {
    @Binding var selection: OutputRatio

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a shape").font(.headline).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(OutputRatio.allCases) { ratio in
                    Button { selection = ratio } label: {
                        HStack(spacing: 12) {
                            Rectangle().stroke(lineWidth: 1.5)
                                .aspectRatio(CGFloat(ratio.width) / CGFloat(ratio.height), contentMode: .fit)
                                .frame(width: 24, height: 32).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(ratio.title) · \(ratio.label)").font(.body.weight(.medium))
                                Text("\(ratio.width) × \(ratio.height) pixels").font(.caption).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Image(systemName: selection == ratio ? "checkmark.circle.fill" : "circle")
                                .font(.title3).accessibilityHidden(true)
                        }.padding(.vertical, 10).padding(.horizontal, 16)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(ratio.title), \(ratio.label), \(ratio.width) by \(ratio.height) pixels")
                        .accessibilityAddTraits(selection == ratio ? .isSelected : [])
                    if ratio != .square { Divider().padding(.leading, 52) }
                }
            }.background(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }
}
