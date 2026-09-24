import SwiftUI

struct RatioChooser: View {
    @Binding var selection: OutputRatio

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a shape").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(OutputRatio.allCases) { ratio in
                    Button { selection = ratio } label: {
                        HStack(spacing: 16) {
                            Rectangle().stroke(lineWidth: 1.5)
                                .aspectRatio(CGFloat(ratio.width) / CGFloat(ratio.height), contentMode: .fit)
                                .frame(width: 28, height: 40).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(ratio.title) · \(ratio.label)").font(.headline)
                                Text("\(ratio.width) × \(ratio.height) pixels").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: selection == ratio ? "checkmark.circle.fill" : "circle")
                                .font(.title3).accessibilityHidden(true)
                        }.padding(.vertical, 14).padding(.horizontal, 16).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(ratio.title), \(ratio.label), \(ratio.width) by \(ratio.height) pixels")
                        .accessibilityAddTraits(selection == ratio ? .isSelected : [])
                    if ratio != .square { Divider().padding(.leading, 60) }
                }
            }.background(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }
}
