import SieveCore
import SwiftUI

/// The bar under the toolbar: filters on the left, sorting on the right, always visible. Every option is one
/// click away and states itself in words ("Date Modified · Newest first"), unlike Finder's View Options panel.
struct ViewOptionsBar: View {
    @ObservedObject var prefs: Preferences
    /// Search results sort by relevance by default, independently from folders.
    var searching: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Kind chips drop their labels before anything gets cut off; scrolling is the last resort.
            ViewThatFits(in: .horizontal) {
                filters(compact: false)
                filters(compact: true)
                ScrollView(.horizontal, showsIndicators: false) { filters(compact: true) }
            }
            Spacer(minLength: 0)
            sortControls.padding(.trailing, 12)
        }
        .frame(height: 40)
        .tint(Theme.swiftAccent)
    }

    private func filters(compact: Bool) -> some View {
        HStack(spacing: 6) {
            kindChips(compact: compact)
            Divider().frame(height: 16)
            dateMenu
            sizeMenu
            hiddenToggle(compact: compact)
            if prefs.filter.isActive {
                Button("Clear") { prefs.filter.clear() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.swiftAccent)
                    .font(.system(size: 12, weight: .medium))
                    .help("Remove all filters")
            }
        }
        .padding(.leading, 12)
        .fixedSize()
    }

    private func kindChips(compact: Bool) -> some View {
        ForEach(FileCategory.allCases, id: \.self) { category in
            Chip(title: category.title, symbol: category.symbol, isOn: prefs.filter.categories.contains(category),
                 showsTitle: !compact || prefs.filter.categories.contains(category)) {
                // Plain click picks one kind; ⌘-click adds to the selection.
                if NSEvent.modifierFlags.contains(.command) {
                    if prefs.filter.categories.contains(category) { prefs.filter.categories.remove(category) } else { prefs.filter.categories.insert(category) }
                } else {
                    prefs.filter.categories = prefs.filter.categories == [category] ? [] : [category]
                }
            }
            .help(category == .folder ? "Only folders (\u{2318}-click to combine kinds)" : "Only \(category.title.lowercased()) (\u{2318}-click to combine kinds)")
        }
    }

    private var dateMenu: some View {
        Menu {
            Picker("Modified", selection: $prefs.filter.date) {
                ForEach(DateFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(prefs.filter.date == .any ? "Modified" : prefs.filter.date.title, systemImage: "calendar")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tint(prefs.filter.date == .any ? Color.secondary : Theme.swiftAccent)
        .help("Filter by modification date")
    }

    private var sizeMenu: some View {
        Menu {
            Picker("Size", selection: $prefs.filter.size) {
                ForEach(SizeFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(prefs.filter.size == .any ? "Size" : prefs.filter.size.title, systemImage: "scalemass")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tint(prefs.filter.size == .any ? Color.secondary : Theme.swiftAccent)
        .help("Filter by file size")
    }

    private func hiddenToggle(compact: Bool) -> some View {
        Chip(title: "Hidden", symbol: prefs.filter.showHidden ? "eye" : "eye.slash", isOn: prefs.filter.showHidden, showsTitle: !compact) {
            prefs.filter.showHidden.toggle()
        }
        .help("Show hidden files (\u{21E7}\u{2318}.)")
    }

    private var order: Binding<SortRule> { searching ? $prefs.searchSort : $prefs.sort }

    private var sortControls: some View {
        HStack(spacing: 4) {
            Menu {
                let keys = searching ? [SortKey.relevance] + SortKey.browsingKeys.filter { $0 != .created } : SortKey.browsingKeys
                ForEach(keys, id: \.self) { key in
                    Button {
                        order.wrappedValue.select(key)
                    } label: {
                        if key == order.wrappedValue.key { Label(key.title, systemImage: "checkmark") } else { Text(key.title) }
                    }
                }
                Divider()
                Toggle("Folders on Top", isOn: order.foldersFirst)
            } label: {
                Label("Sort: \(order.wrappedValue.key.title)", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tint(.primary)
            .help("Choose what to sort by. Picking the current key again reverses it.")

            if order.wrappedValue.key != .relevance {
                Button {
                    order.wrappedValue.ascending.toggle()
                } label: {
                    Text(order.wrappedValue.key.directionLabel(ascending: order.wrappedValue.ascending))
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Reverse the order")
            }
        }
    }
}

private struct Chip: View {
    let title: String
    let symbol: String
    let isOn: Bool
    var showsTitle = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                if showsTitle { Text(title).font(.system(size: 12)) }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.8))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? Theme.swiftAccent : Color.primary.opacity(hovering ? 0.09 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}
