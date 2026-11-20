import SwiftUI

@main
struct KertasApp: App {
    @StateObject private var router = AppRouter()

    init() {
        FontLibrary.shared.registerInstalledFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                .tint(Theme.red)
                .preferredColorScheme(.light)
                .onOpenURL { url in
                    if let adopted = FileStore.adopt(url) {
                        router.tab = .files
                        router.openedFile = adopted
                    }
                }
        }
    }
}

final class AppRouter: ObservableObject {
    enum Tab: Hashable { case tools, scan, files }
    @Published var tab: Tab = .tools
    @Published var openedFile: URL?
}

struct RootView: View {
    @EnvironmentObject var router: AppRouter

    var body: some View {
        TabView(selection: $router.tab) {
            NavigationStack { HomeView() }
                .tabItem { Label("Tools", systemImage: "square.grid.2x2") }
                .tag(AppRouter.Tab.tools)
            NavigationStack { ScanView() }
                .tabItem { Label("Scan", systemImage: "doc.viewfinder") }
                .tag(AppRouter.Tab.scan)
            FilesTab()
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(AppRouter.Tab.files)
        }
    }
}

struct HomeView: View {
    @State private var category: ToolCategory?
    @EnvironmentObject var router: AppRouter

    private var tools: [Tool] {
        Tool.allCases.filter { $0 != .scan && (category == nil || $0.category == category) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image("Wordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 70)
                    .accessibilityLabel("Kertas")
                    .padding(.top, 4)

                Button { router.tab = .scan } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.viewfinder").font(.system(size: 26, weight: .medium))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scan to PDF").font(.headline)
                            Text("Camera or photo, auto-straighten").font(.caption).opacity(0.85)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(Theme.red, in: RoundedRectangle(cornerRadius: 16))
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", selected: category == nil) { category = nil }
                        ForEach(ToolCategory.allCases) { c in
                            chip(c.rawValue, selected: category == c) { category = c }
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(tools) { tool in
                        NavigationLink(value: tool) {
                            VStack(alignment: .leading, spacing: 10) {
                                ToolIcon(tool: tool, size: 18)
                                Text(tool.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                Text(tool.subtitle).font(.caption2).foregroundStyle(Theme.grey)
                                    .lineLimit(2, reservesSpace: true)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 0.5))
                        }
                    }
                }
            }
            .padding()
        }
        .background(Theme.page)
        .navigationTitle("Tools")
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: Tool.self) { ToolRouter(tool: $0) }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(selected ? .white : Theme.ink)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? Theme.ink : Theme.chip, in: Capsule())
        }
    }
}

struct ToolRouter: View {
    let tool: Tool
    var preset: URL? = nil

    var body: some View {
        switch tool {
        case .scan: ScanView()
        case .merge: MergeView()
        case .split: SplitView(preset: preset)
        case .removePages: PagesToolView(mode: .remove, preset: preset)
        case .extractPages: PagesToolView(mode: .extract, preset: preset)
        case .organize: PagesToolView(mode: .organize, preset: preset)
        case .rotate: PagesToolView(mode: .rotate, preset: preset)
        case .compress: CompressView(preset: preset)
        case .repair: RepairView(preset: preset)
        case .ocr: OCRView(preset: preset)
        case .jpgToPdf: ImagesToPDFView()
        case .wordToPdf, .pptToPdf, .excelToPdf: OfficeToPDFView(tool: tool)
        case .htmlToPdf: HTMLToPDFView()
        case .pdfToJpg: PDFToJPGView(preset: preset)
        case .extractImages: ExtractImagesView(preset: preset)
        case .pdfToText: PDFToTextView(preset: preset)
        case .edit: EditEntryView(mode: .full, preset: preset)
        case .sign: EditEntryView(mode: .sign, preset: preset)
        case .redact: EditEntryView(mode: .redact, preset: preset)
        case .crop: CropView(preset: preset)
        case .pageNumbers: PageNumbersView(preset: preset)
        case .watermark: WatermarkView(preset: preset)
        case .forms: FormsView(preset: preset)
        case .protect: ProtectView(preset: preset)
        case .unlock: UnlockView(preset: preset)
        case .compare: CompareView()
        case .summarize: SummarizeView(preset: preset)
        case .translate: TranslateView(preset: preset)
        }
    }
}
