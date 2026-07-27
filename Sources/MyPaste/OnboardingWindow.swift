import SwiftUI
import AppKit

/// 首次启动引导窗口：说明权限、快捷键和隐私策略。
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        if window == nil { makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() {
        let controller = NSHostingController(rootView: AppearanceRoot(settings: settings) { OnboardingView() })
        let window = NSWindow(contentViewController: controller)
        window.title = NSLocalizedString("欢迎使用 ClipVault", comment: "Onboarding window title")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 460))
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
    }
}

private struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private let pages: [(icon: String, title: String, description: String)] = [
        ("keyboard",
         NSLocalizedString("快捷呼出", comment: "Onboarding feature 1 title"),
         NSLocalizedString("使用 ⇧⌘V 呼出面板，⌥Tab 切换集合，Space 预览内容。", comment: "Onboarding feature 1 description")),
        ("hand.raised",
         NSLocalizedString("辅助功能权限", comment: "Onboarding feature 2 title"),
         NSLocalizedString("首次自动粘贴需要授予辅助功能权限，以便将内容粘贴到当前应用。", comment: "Onboarding feature 2 description")),
        ("lock.shield",
         NSLocalizedString("隐私优先", comment: "Onboarding feature 3 title"),
         NSLocalizedString("所有剪贴板记录本地加密存储，可设置忽略密码等敏感内容。", comment: "Onboarding feature 3 description")),
    ]

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)

            Text(NSLocalizedString("欢迎使用 ClipVault", comment: "Onboarding title"))
                .font(.title)
                .bold()

            featurePage(pages[page])
                .frame(height: 180)
                .animation(.easeInOut(duration: 0.2), value: page)

            pageIndicators

            HStack {
                if page < pages.count - 1 {
                    Button(NSLocalizedString("跳过", comment: "Onboarding skip button")) {
                        dismiss()
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button(NSLocalizedString("下一步", comment: "Onboarding next button")) {
                        withAnimation { page += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Spacer()

                    Button(NSLocalizedString("开始使用", comment: "Onboarding get started button")) {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(width: 340)
        }
        .padding(32)
        .frame(width: 520, height: 460)
    }

    private func featurePage(_ page: (icon: String, title: String, description: String)) -> some View {
        VStack(spacing: 14) {
            Image(systemName: page.icon)
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text(page.title)
                .font(.headline)
            Text(page.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }

    private var pageIndicators: some View {
        HStack(spacing: 8) {
            ForEach(0..<pages.count, id: \.self) { index in
                Circle()
                    .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .animation(.easeInOut(duration: 0.2), value: page)
            }
        }
    }
}
