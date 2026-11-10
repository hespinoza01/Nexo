import Cocoa

class AboutTab {
    static func makeContentView(_ fitToContent: Bool = true, _ showFeedbackButton: Bool = true, _ centerHero: Bool = false) -> NSView {
        let appIcon = LightImageView()
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        let appIconSize = NSSize(width: 128, height: 128)
        appIcon.updateContents(.cgImage(App.appIcon), appIconSize)
        appIcon.fit(128, 128)
        let appText = StackView([
            BoldLabel(NSLocalizedString("Window switcher", comment: "")),
            NSTextField(labelWithString: NSLocalizedString("Version", comment: "") + " " + App.version),
            NSTextField(labelWithString: App.licence),
            NSTextField(labelWithString: NSLocalizedString("Based on AltTab by lwouis", comment: "")),
            HyperlinkLabel(NSLocalizedString("Upstream source code", comment: ""), App.repository),
        ], .vertical)
        appText.spacing = GridView.interPadding / 2
        let rowToSeparate = 3
        appText.views[rowToSeparate].topAnchor.constraint(equalTo: appText.views[rowToSeparate - 1].bottomAnchor, constant: GridView.interPadding).isActive = true
        let appInfo = NSStackView(views: [appIcon, appText])
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        appInfo.spacing = GridView.interPadding
        appInfo.alignment = .centerY
        let grid = GridView([[appInfo]], 0)
        if centerHero {
            grid.cell(atColumnIndex: 0, rowIndex: 0).xPlacement = .center
        }
        if fitToContent {
            grid.fit()
        }
        return grid
    }
}

class AboutWindow: NSPanel {
    private static let contentPadding = CGFloat(24)
    static var shared: AboutWindow?
    private var usageTextView: NSTextView!

    override var canBecomeKey: Bool { SecondaryWindows.canBecomeKey }

    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 450), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        setupWindow()
        setupView()
        setFrameAutosaveNameSafely("AboutWindow2")
        Self.shared = self
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        updateUsageStats()
        super.makeKeyAndOrderFront(sender)
    }

    private func setupWindow() {
        applySecondaryWindowChrome(String(format: NSLocalizedString("About %@", comment: ""), App.name))
    }

    private func setupView() {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        let documentView = FlippedView(frame: .zero)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 30
        stack.translatesAutoresizingMaskIntoConstraints = false
        let aboutView = AboutTab.makeContentView(false, false, true)
        let columnWidth = frame.width - 2 * Self.contentPadding
        usageTextView = NSTextView.makeReadOnlyMarkdownView(columnWidth)
        let acknowledgmentsView = AcknowledgmentsTab.makeContentView(columnWidth: columnWidth, shouldFit: false, verticallyStacked: true)
        acknowledgmentsView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(aboutView)
        stack.addArrangedSubview(usageTextView)
        stack.addArrangedSubview(acknowledgmentsView)
        stack.setCustomSpacing(15, after: usageTextView)
        documentView.addSubview(stack)
        contentView = scrollView
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: Self.contentPadding),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: Self.contentPadding),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -Self.contentPadding),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -Self.contentPadding),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            aboutView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            aboutView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            usageTextView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            usageTextView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            acknowledgmentsView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            acknowledgmentsView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    private func updateUsageStats() {
        let now = Date()
        let weekCount = UsageStats.count("triggers", since: now.addingTimeInterval(-7 * 24 * 3600))
        let monthCount = UsageStats.count("triggers", since: now.addingTimeInterval(-30 * 24 * 3600))
        let yearCount = UsageStats.count("triggers", since: now.addingTimeInterval(-365 * 24 * 3600))
        let markdown = "## \(NSLocalizedString("Usage", comment: ""))\n\nYou have used Nexo:\n\u{2022} **\(weekCount)** times in the past week\n\u{2022} **\(monthCount)** times in the past month\n\u{2022} **\(yearCount)** times in the past year"
        usageTextView.textStorage!.setAttributedString(Markdown.toAttributedString(markdown))
        usageTextView.layoutManager!.ensureLayout(for: usageTextView.textContainer!)
        let usedRect = usageTextView.layoutManager!.usedRect(for: usageTextView.textContainer!)
        usageTextView.invalidateIntrinsicContentSize()
        usageTextView.fit(usedRect.width, usedRect.height)
    }

    override func close() {
        hideAppIfLastWindowIsClosed()
        super.close()
    }
}
