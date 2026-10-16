import AppKit
import WebKit

// Optional native macOS WebKit smoke test; all files come from webkit-fixture.cjs.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let book = root.appendingPathComponent("Extracted/book", isDirectory: true)
let app = NSApplication.shared
var webView: WKWebView!

class Receiver: NSObject, WKScriptMessageHandler {
    var tested = false
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "booted", !tested {
            tested = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                webView.evaluateJavaScript("""
                (function () {
                  var reader = window.__reader;
                  var initial = reader.state();
                  var turned = reader.nextPage();
                  reader.goToFragment('target', false);
                  var jumped = reader.state().page > 0;
                  reader.goToPosition({elementPath:[0,0], offset:0}, false);
                  reader.setHighlights([{id:'test', color:'rgba(255,214,69,0.45)', style:'fill', start:{elementPath:[0,0],offset:0}, end:{elementPath:[0,0],offset:20}, text:'A highlighted passage'}]);
                  document.getElementById('target').click();
                  var result = {
                    type:'result', pages:initial.pageCount, turned:turned, jumped:jumped,
                    restored:reader.state().page === 0,
                    highlights:document.getElementById('reader-highlight-layer').children.length,
                    publisherExecuted:!!window.publisherExecuted, publisherEvent:!!window.publisherEvent
                  };
                  var xhr = new XMLHttpRequest();
                  xhr.open('GET', '../../library.json');
                  xhr.onload = function () { result.privateRead = xhr.responseText.indexOf('synthetic private notes') >= 0; window.webkit.messageHandlers.reader.postMessage(result); };
                  xhr.onerror = function () { result.privateRead=false; window.webkit.messageHandlers.reader.postMessage(result); };
                  try { xhr.send(); } catch (e) { result.privateRead=false; window.webkit.messageHandlers.reader.postMessage(result); }
                })();
                """) { _, error in
                    if let error { print("Smoke evaluation failed: \(error)"); exit(1) }
                }
            }
        } else if body["type"] as? String == "result" {
            print(body)
            let passed = (body["pages"] as? Int ?? 0) > 1
                && body["turned"] as? Bool == true && body["jumped"] as? Bool == true
                && body["restored"] as? Bool == true && (body["highlights"] as? Int ?? 0) > 0
                && body["publisherExecuted"] as? Bool == false && body["publisherEvent"] as? Bool == false
                && body["privateRead"] as? Bool == false
            print(passed ? "Protected reader WebKit smoke test passed" : "Protected reader WebKit smoke test FAILED")
            fflush(stdout)
            exit(passed ? 0 : 1)
        } else if body["type"] as? String == "error" {
            print(body); exit(1)
        }
    }
}
let receiver = Receiver()
let config = WKWebViewConfiguration()
config.userContentController.add(receiver, name: "reader")
config.userContentController.addUserScript(WKUserScript(source: "window.ReactNativeWebView={postMessage:function(s){window.webkit.messageHandlers.reader.postMessage(JSON.parse(s));}};", injectionTime: .atDocumentStart, forMainFrameOnly: true))
webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
webView.loadFileURL(book.appendingPathComponent("chapter.xhtml"), allowingReadAccessTo: book)
DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("WebKit smoke test timed out"); exit(1) }
app.run()
