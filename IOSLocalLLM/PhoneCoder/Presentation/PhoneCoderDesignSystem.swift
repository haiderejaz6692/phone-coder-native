import SwiftUI

/// Native typography and semantic surfaces shared by the five screen interiors.
/// Keep layout flexible: these are minimum gutters, never fixed text heights.
enum PhoneCoderSpacing {
    static let compact: CGFloat = 8
    static let content: CGFloat = 16
    static let section: CGFloat = 24
}

struct PhoneCoderStatusHeader: View {
    let title: String
    let detail: String
    let systemImage: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: PhoneCoderSpacing.compact) {
            Label {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint).accessibilityHidden(true)
            }
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PhoneCoderSpacing.compact)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Values such as model IDs and memory provenance need all their text, even
/// when a compact phone or accessibility text size leaves no room beside a label.
struct PhoneCoderDetailRow: View {
    let title: String
    let value: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: String, value: String) { self.title = title; self.value = value }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: PhoneCoderSpacing.content) {
                        Text(title).fixedSize()
                        Spacer(minLength: PhoneCoderSpacing.compact)
                        Text(value).foregroundStyle(.secondary).fixedSize()
                    }
                    stacked
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(value).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
