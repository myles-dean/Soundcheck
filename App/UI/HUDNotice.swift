import AppKit
import Observation
import SwiftUI

/// A short message in the volume pill: a muted app that just started, the mics being muted.
struct HUDNotice: Equatable {
    var icon: NSImage?
    var symbol: String?
    let title: String
    let detail: String?
}

/// What the pill shows: a notice, or (when nil) the levels the volume keys are changing.
@MainActor
@Observable
final class HUDState {
    static let shared = HUDState()
    var notice: HUDNotice?
}

/// The app's icon (or a symbol), its name and what happened, like "Steam · Muted".
struct HUDNoticeView: View {
    let notice: HUDNotice
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let ink = colorScheme == .dark ? Color.white : Color.black
        HStack(spacing: 10) {
            if let icon = notice.icon {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            } else if let symbol = notice.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 26, height: 26)
            }
            Text(notice.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail = notice.detail {
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ink.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: VolumeHUD.width, alignment: .leading)
    }
}
