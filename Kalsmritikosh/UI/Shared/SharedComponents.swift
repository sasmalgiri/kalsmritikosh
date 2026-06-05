//
//  SharedComponents.swift
//  Kalsmritikosh
//
//  Small reusable UI primitives: ConfidenceBadge, SourcePill, EntityChip.
//

import SwiftUI

public struct ConfidenceBadge: View {
    let confidence: Confidence
    public init(_ confidence: Confidence) { self.confidence = confidence }
    public var body: some View {
        let pct = Int(confidence.value * 100)
        let tint: Color = {
            switch confidence.value {
            case ..<0.33: return .red
            case ..<0.66: return .orange
            default: return .green
            }
        }()
        return Text("\(pct)%")
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.2), in: .capsule)
            .foregroundStyle(tint)
    }
}

public struct SourcePill: View {
    let label: String
    public init(_ label: String) { self.label = label }
    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text.magnifyingglass").imageScale(.small)
            Text(label).font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.tint.opacity(0.15), in: .capsule)
    }
}

public struct EntityChip: View {
    let value: String
    let kind: Entity.Kind?
    public init(_ value: String, kind: Entity.Kind? = nil) {
        self.value = value
        self.kind = kind
    }
    public var body: some View {
        HStack(spacing: 4) {
            if let kind {
                Image(systemName: icon(for: kind)).imageScale(.small)
            }
            Text(value).font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: .capsule)
    }
    private func icon(for kind: Entity.Kind) -> String {
        switch kind {
        case .person: return "person"
        case .organization, .vendor, .client: return "building.2"
        case .emailAddress: return "envelope"
        case .phoneNumber: return "phone"
        case .money, .currency, .invoiceNumber, .paymentID: return "dollarsign.circle"
        case .date, .deadline, .milestone: return "calendar"
        case .address, .city, .country, .location: return "mappin.and.ellipse"
        case .project, .deliverable: return "shippingbox"
        case .other: return "tag"
        }
    }
}
