import Foundation
import SafariServices

/// Soundcheck's Safari extension, on the native side: Safari hands it the extension's messages
/// (the tabs that are playing or on a call, or just checking in), and it passes them to
/// Soundcheck and returns Soundcheck's requests for the tabs. Sandboxed; it reaches Soundcheck
/// through a port named with their shared app group.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] ?? [:]
        var reply: Any = ["commands": [Any](), "poll": 2.0] // Soundcheck isn't running: look again in a bit
        if let body = try? JSONSerialization.data(withJSONObject: ["browser": "com.apple.Safari", "message": message]),
           let data = BrowserLink.request(body, to: BrowserLink.appPort), !data.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: data) {
            reply = object
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
