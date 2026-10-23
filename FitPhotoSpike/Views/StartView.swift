import SwiftUI

struct StartView: View {
    let isBusy: Bool
    let onChoose: () -> Void
    @State private var showsAbout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Fit Photos").font(.fitDisplay(.title3))
                Spacer()
                Button { showsAbout = true } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(Theme.ink)
                .accessibilityLabel("About Fit Photos")
            }
            .padding(.top, 8)

            StartIllustration()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 12) {
                Text("The whole photo,\nin the right frame.")
                    .font(.fitDisplay(.largeTitle))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Choose up to \(AppBatchProcessor.maximumImageCount) photos, pick an Instagram size, and save them all at once.")
                    .font(.body)
                    .foregroundStyle(Theme.inkQuiet)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onChoose) {
                Label("Choose photos", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(InkButtonStyle())
            .disabled(isBusy)
            .padding(.top, 22)

            Text("Free · No account · Photos stay on your iPhone")
                .font(.fitMono(.caption2))
                .foregroundStyle(Theme.inkQuiet)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .foregroundStyle(Theme.ink)
        .sheet(isPresented: $showsAbout) { AboutView() }
    }
}

/// Three framed example photos laid on the table, the chosen one circled.
struct StartIllustration: View {
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 342, proxy.size.height / 300, 1.25)
            ZStack(alignment: .topLeading) {
                ExampleFrame(mat: RGBColor(hex: 0xF3D477), size: CGSize(width: 118, height: 210),
                             photo: CGSize(width: 118, height: 78)) { BeachScene() }
                    .rotationEffect(.degrees(-7))
                    .offset(x: 4, y: 44)
                ExampleFrame(mat: RGBColor(hex: 0x16181B), size: CGSize(width: 128, height: 128),
                             photo: CGSize(width: 84, height: 108)) { PlantScene() }
                    .rotationEffect(.degrees(5))
                    .offset(x: 208, y: 168)
                ExampleFrame(mat: .white, size: CGSize(width: 168, height: 210),
                             photo: CGSize(width: 168, height: 112)) { CityScene() }
                    .markerRing(true, inset: -18, lineWidth: 3.5)
                    .rotationEffect(.degrees(2))
                    .offset(x: 86, y: 14)
            }
            .frame(width: 342, height: 300, alignment: .topLeading)
            .scaleEffect(max(scale, 0.1))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }
}

struct ExampleFrame<Photo: View>: View {
    let mat: RGBColor
    let size: CGSize
    let photo: CGSize
    let content: Photo

    init(mat: RGBColor, size: CGSize, photo: CGSize, @ViewBuilder content: () -> Photo) {
        self.mat = mat
        self.size = size
        self.photo = photo
        self.content = content()
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color(rgb: mat))
            content
                .frame(width: photo.width, height: photo.height)
                .clipped()
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 10)
    }
}

private struct CityScene: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack(alignment: .bottomLeading) {
                Color(rgb: RGBColor(hex: 0xF2A65A))
                Circle()
                    .fill(Color(rgb: RGBColor(hex: 0xF9D37C)))
                    .frame(width: w * 0.18, height: w * 0.18)
                    .position(x: w * 0.24, y: h * 0.32)
                HStack(alignment: .bottom, spacing: 0) {
                    building(width: w * 0.2, height: h * 0.55, dark: false)
                    building(width: w * 0.17, height: h * 0.75, dark: true)
                    building(width: w * 0.24, height: h * 0.45, dark: false)
                    building(width: w * 0.15, height: h * 0.82, dark: true)
                    building(width: w * 0.24, height: h * 0.52, dark: false)
                }
            }
        }
    }

    private func building(width: CGFloat, height: CGFloat, dark: Bool) -> some View {
        Rectangle()
            .fill(Color(rgb: RGBColor(hex: dark ? 0x2C2644 : 0x3B3355)))
            .frame(width: width, height: height)
    }
}

private struct BeachScene: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack(alignment: .bottom) {
                Color(rgb: RGBColor(hex: 0x9CC9E3))
                Circle()
                    .fill(Color(rgb: RGBColor(hex: 0xF6C85F)))
                    .frame(width: h * 0.24, height: h * 0.24)
                    .position(x: w * 0.68, y: h * 0.24)
                VStack(spacing: 0) {
                    Color(rgb: RGBColor(hex: 0x2F7FA8)).frame(height: h * 0.28)
                    Color(rgb: RGBColor(hex: 0xE9D3A6)).frame(height: h * 0.16)
                }
            }
        }
    }
}

private struct PlantScene: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                Color(rgb: RGBColor(hex: 0xE7E1D5))
                Ellipse()
                    .fill(Color(rgb: RGBColor(hex: 0x4F7A4A)))
                    .frame(width: w * 0.34, height: h * 0.38)
                    .position(x: w * 0.38, y: h * 0.4)
                Ellipse()
                    .fill(Color(rgb: RGBColor(hex: 0x5E8C56)))
                    .frame(width: w * 0.34, height: h * 0.42)
                    .position(x: w * 0.62, y: h * 0.34)
                Rectangle()
                    .fill(Color(rgb: RGBColor(hex: 0xC46A4A)))
                    .frame(width: w * 0.32, height: h * 0.26)
                    .position(x: w * 0.5, y: h * 0.87)
            }
        }
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    fact("Your photos stay yours",
                         "Fit Photos only sees the photos you choose. Everything happens on your iPhone; nothing is uploaded.")
                    fact("Originals stay untouched",
                         "Saving adds new copies to your library. Your original photos are never changed or deleted.")
                    fact("Free, for real",
                         "No account, no ads, no subscriptions and no locked features.")
                    Text("Version \(version)")
                        .font(.fitMono(.caption))
                        .foregroundStyle(Theme.inkQuiet)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.table.ignoresSafeArea())
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func fact(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.inkQuiet)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(short) (\(build))"
    }
}
