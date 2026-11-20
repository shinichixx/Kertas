import SwiftUI
import VisionKit

struct DocumentCameraView: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentCameraView
        init(_ p: DocumentCameraView) { parent = p }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onFinish(images)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.onCancel() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.onCancel() }
    }
}

/// Shows the original photo with four draggable corners and a magnifier while dragging.
struct CornerAdjustView: View {
    let image: UIImage
    @State var quad: Quad
    var onDone: (Quad) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var dragging: Int?
    @State private var dragPoint: CGPoint = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let fit = fitRect(image.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                    Image(uiImage: image).resizable().frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                    Path { p in
                        let pts = quad.points.map { point($0, fit) }
                        p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) }; p.closeSubpath()
                    }
                    .fill(Theme.red.opacity(0.15))
                    Path { p in
                        let pts = quad.points.map { point($0, fit) }
                        p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) }; p.closeSubpath()
                    }
                    .stroke(Theme.red, lineWidth: 2)

                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().stroke(Theme.red, lineWidth: 3))
                            .frame(width: 26, height: 26)
                            .position(point(quad[i], fit))
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("adjust"))
                                .onChanged { v in
                                    dragging = i
                                    dragPoint = v.location
                                    quad[i] = CGPoint(x: min(max((v.location.x - fit.minX) / fit.width, 0), 1),
                                                      y: min(max((v.location.y - fit.minY) / fit.height, 0), 1))
                                }
                                .onEnded { _ in dragging = nil })
                    }

                    if let d = dragging {
                        Magnifier(image: image, point: quad[d])
                            .frame(width: 110, height: 110)
                            .position(x: dragPoint.x < geo.size.width / 2 ? geo.size.width - 70 : 70, y: 70)
                    }
                }
                .coordinateSpace(name: "adjust")
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Adjust corners")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { onDone(quad); dismiss() }.bold() }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button("Auto detect") { if let q = Perspective.detect(image) { quad = q } }
                        Spacer()
                        Button("Whole photo") { quad = .full }
                    }
                }
            }
        }
    }

    private func fitRect(_ size: CGSize, in box: CGSize) -> CGRect {
        let pad: CGFloat = 20
        let avail = CGSize(width: box.width - 2 * pad, height: box.height - 2 * pad)
        let s = min(avail.width / size.width, avail.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    private func point(_ p: CGPoint, _ r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
    }
}

struct Magnifier: View {
    let image: UIImage
    let point: CGPoint
    var zoom: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            let w = side * zoom * (image.size.width / max(image.size.width, image.size.height)) * 2
            let h = w * image.size.height / image.size.width
            Image(uiImage: image)
                .resizable()
                .frame(width: w, height: h)
                .offset(x: side / 2 - point.x * w, y: side / 2 - point.y * h)
                .frame(width: side, height: side, alignment: .topLeading)
                .clipped()
                .overlay(Image(systemName: "plus").foregroundStyle(Theme.red))
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 3))
    }
}
