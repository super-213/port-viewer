import AppKit
import SwiftUI

struct TableGlassBackgroundBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        scheduleUpdate(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scheduleUpdate(from: nsView)
    }

    private func scheduleUpdate(from view: NSView) {
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let current = ancestor {
                let tables = current.descendants(of: NSTableView.self)
                if !tables.isEmpty {
                    for table in tables {
                        table.backgroundColor = .clear
                        table.usesAlternatingRowBackgroundColors = false
                        table.enclosingScrollView?.drawsBackground = false
                        table.enclosingScrollView?.backgroundColor = .clear
                        table.enclosingScrollView?.contentView.drawsBackground = false
                    }
                    return
                }
                ancestor = current.superview
            }
        }
    }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        var matches: [T] = []
        for child in subviews {
            if let match = child as? T {
                matches.append(match)
            }
            matches.append(contentsOf: child.descendants(of: type))
        }
        return matches
    }
}
