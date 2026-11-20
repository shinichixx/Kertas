import UIKit
import WebKit

/// Uses WebKit (which can open Word, Excel and PowerPoint files) to render a document,
/// then prints it into A4 PDF pages.
@MainActor
final class WebConverter: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?
    private var holder: UIView?

    func convert(fileURL: URL? = nil, webURL: URL? = nil, landscape: Bool = false, settle: Double = 1.2) async throws -> Data {
        let config = WKWebViewConfiguration()
        let pageWidth: CGFloat = landscape ? 842 : 595
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: pageWidth * 1.4, height: 1200), configuration: config)
        wv.navigationDelegate = self
        webView = wv

        // A web view renders reliably only when it sits in a window, so park it off screen.
        if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            let h = UIView(frame: CGRect(x: -5000, y: 0, width: wv.frame.width, height: wv.frame.height))
            h.alpha = 0.01
            h.addSubview(wv)
            window.addSubview(h)
            holder = h
        }
        defer { holder?.removeFromSuperview(); holder = nil; webView = nil }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            if let fileURL {
                wv.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
            } else if let webURL {
                wv.load(URLRequest(url: webURL, timeoutInterval: 45))
            } else {
                c.resume(throwing: KertasError("Nothing to convert."))
                continuation = nil
            }
        }
        try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        return printPDF(wv, landscape: landscape)
    }

    private func printPDF(_ wv: WKWebView, landscape: Bool) -> Data {
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(wv.viewPrintFormatter(), startingAtPageAt: 0)
        let paper = landscape ? CGRect(x: 0, y: 0, width: 841.8, height: 595.2) : CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: 28, dy: 28)), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        let bounds = UIGraphicsGetPDFContextBounds()
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: bounds)
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
