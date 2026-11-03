import NoSlopKit
import SwiftUI

/// The toolbar button that opens the filter sheet. A filled icon with a count shows that filters are on.
struct SearchFilterButton: View {
    let filter: SearchFilter
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: filter.isDefault
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filters")
        .accessibilityValue(filter.isDefault ? "Off" : "\(filter.activeCount) on")
    }
}

/// Type, sort order, duration and upload date. Changes are kept in a draft and take effect with Apply.
struct SearchFilterSheet: View {
    let apply: (SearchFilter) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: SearchFilter

    init(filter: SearchFilter, apply: @escaping (SearchFilter) -> Void) {
        self.apply = apply
        _draft = State(initialValue: filter)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Type", selection: $draft.type) {
                        ForEach(SearchType.allCases, id: \.self) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section {
                    Picker("Sort by", selection: $draft.sort) {
                        ForEach(SearchSort.allCases, id: \.self) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }

                    // Duration and upload date describe videos; a channel or playlist search has no use for them.
                    if draft.type == .all || draft.type == .video {
                        Picker("Duration", selection: $draft.duration) {
                            ForEach(SearchDuration.allCases, id: \.self) { duration in
                                Text(duration.label).tag(duration)
                            }
                        }
                        Picker("Upload date", selection: $draft.uploadDate) {
                            ForEach(SearchUploadDate.allCases, id: \.self) { date in
                                Text(date.label).tag(date)
                            }
                        }
                    }
                }

                Section {
                    Button("Reset filters", role: .destructive) {
                        draft = SearchFilter()
                    }
                    .disabled(draft.isDefault)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        apply(draft.normalized)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        SearchFilterSheet(filter: SearchFilter(type: .video, sort: .viewCount)) { _ in }
    }
}
