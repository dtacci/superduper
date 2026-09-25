//
//  VocabularyPacksSection.swift
//  SuperduperDictation
//
//  Created on 2026-09-23.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dictionary page section for vocabulary packs: which glossaries this Mac boosts,
/// plus import/export so a pack can move between Macs.
struct VocabularyPacksSection: View {
    @Environment(\.locale) private var locale
    let store: VocabularyPackStore

    @State private var isEnteringRemoteURL = false
    @State private var remoteURLText = ""
    @State private var isDownloading = false
    @State private var errorMessage: String?
    @State private var isBuildingFromDocs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: localized("Vocabulary packs", locale: locale),
                trailing: localized("Glossaries boosted on this Mac", locale: locale),
                isFirst: true
            ) {
                addPackMenu
            }
            .padding(.horizontal, 20)

            VStack(spacing: 0) {
                ForEach(store.packs) { pack in
                    packRow(pack)
                }
            }
            .padding(.horizontal, 20)

            Text(localized(
                "Packs boost names and jargon with Parakeet models. In a pack file, write one term per line and add spellings the recognizer hears after a bar, like “Teensy | TNC”.",
                locale: locale
            ))
            .font(AppTypography.caption)
            .foregroundStyle(AppColors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 16)
        .alert(localized("Import pack from URL", locale: locale), isPresented: $isEnteringRemoteURL) {
            TextField("https://", text: $remoteURLText)
            Button(localized("Import", locale: locale)) { importFromRemoteURL() }
            Button(localized("Cancel", locale: locale), role: .cancel) {}
        } message: {
            Text(localized("A JSON pack, or a text file with one term per line.", locale: locale))
        }
        .alert(
            localized("Vocabulary pack error", locale: locale),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(localized("OK", locale: locale)) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $isBuildingFromDocs) {
            VocabularyPackBuilderSheet(store: store)
        }
    }

    private var addPackMenu: some View {
        Menu {
            Button(localized("Build pack from docs…", locale: locale)) { isBuildingFromDocs = true }
            Divider()
            Button(localized("Import pack file…", locale: locale)) { importFromFile() }
            Button(localized("Import pack from URL…", locale: locale)) {
                remoteURLText = ""
                isEnteringRemoteURL = true
            }
        } label: {
            if isDownloading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isDownloading)
        .help(localized("Add a vocabulary pack", locale: locale))
        .accessibilityLabel(localized("Add a vocabulary pack", locale: locale))
        .accessibilityIdentifier("dictionary.vocabularyPacks.add")
    }

    private func packRow(_ pack: VocabularyPack) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(pack.name)
                        .font(AppTypography.labelStrong)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("\(pack.terms.count)")
                        .font(FontLoader.font(family: .jetbrainsMono, size: 10, weight: .medium))
                        .foregroundStyle(AppColors.textTertiary)
                }
                if !pack.summary.isEmpty {
                    Text(pack.summary)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Menu {
                Button(localized("Export…", locale: locale)) { export(pack) }
                if !store.isBuiltIn(pack) {
                    Button(localized("Delete", locale: locale), role: .destructive) { delete(pack) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(AppColors.textTertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(localized("More", locale: locale))

            Toggle(
                pack.name,
                isOn: Binding(
                    get: { store.enabledPackIDs.contains(pack.id) },
                    set: { store.setEnabled($0, packID: pack.id) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("dictionary.vocabularyPacks.toggle.\(pack.id)")
        }
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText]
        panel.title = localized("Import pack file…", locale: locale)
        panel.message = localized("A JSON pack, or a text file with one term per line.", locale: locale)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            _ = try store.importPack(from: url)
        } catch {
            present(error)
        }
    }

    private func importFromRemoteURL() {
        let text = remoteURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            errorMessage = localized("Enter a web address that starts with https://", locale: locale)
            return
        }
        isDownloading = true
        Task { @MainActor in
            defer { isDownloading = false }
            do {
                _ = try await store.importPack(fromRemote: url)
            } catch {
                present(error)
            }
        }
    }

    private func export(_ pack: VocabularyPack) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(pack.id).json"
        panel.title = localized("Export…", locale: locale)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(pack, to: url)
        } catch {
            present(error)
        }
    }

    private func delete(_ pack: VocabularyPack) {
        do {
            try store.delete(pack)
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        Log.ui.error("Vocabulary pack action failed: \(error.localizedDescription)")
        errorMessage = error.localizedDescription
    }
}

/// Builds a pack from a documentation link: fetch, suggest terms, review, save.
struct VocabularyPackBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let store: VocabularyPackStore

    @State private var urlText = ""
    @State private var packName = ""
    @State private var candidates: [VocabularyPackExtractor.Candidate] = []
    @State private var selectedTerms: Set<String> = []
    @State private var sourceHost = ""
    @State private var isFetching = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localized("Build a vocabulary pack", locale: locale))
                    .font(AppTypography.labelStrongSelected)
                    .foregroundStyle(AppColors.textPrimary)
                Text(localized(
                    "Paste a documentation link. Sites with an llms.txt index work best, like docs.livekit.io/llms.txt.",
                    locale: locale
                ))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField("https://", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(fetch)
                    .accessibilityIdentifier("vocabularyPackBuilder.url")
                Button(localized("Find terms", locale: locale), action: fetch)
                    .disabled(isFetching || url == nil)
                    .keyboardShortcut(.defaultAction)
            }

            if isFetching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(localized("Reading the docs…", locale: locale))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            } else if let message {
                Text(message)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !candidates.isEmpty {
                TextField(localized("Pack name", locale: locale), text: $packName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("vocabularyPackBuilder.name")

                HStack {
                    Text(String(format: localized("%d of %d terms selected", locale: locale), selectedTerms.count, candidates.count))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Button(localized("Select all", locale: locale)) { selectedTerms = Set(candidates.map(\.term)) }
                        .buttonStyle(.link)
                    Button(localized("Select none", locale: locale)) { selectedTerms = [] }
                        .buttonStyle(.link)
                }
                .font(AppTypography.caption)

                List(candidates) { candidate in
                    Toggle(isOn: Binding(
                        get: { selectedTerms.contains(candidate.term) },
                        set: { isOn in
                            if isOn { selectedTerms.insert(candidate.term) } else { selectedTerms.remove(candidate.term) }
                        }
                    )) {
                        HStack {
                            Text(candidate.term)
                                .font(AppTypography.label)
                                .foregroundStyle(AppColors.textPrimary)
                            Spacer()
                            Text("\(candidate.count)")
                                .font(FontLoader.font(family: .jetbrainsMono, size: 10, weight: .medium))
                                .foregroundStyle(AppColors.textTertiary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .frame(minHeight: 220)
            }

            HStack {
                Spacer()
                Button(localized("Cancel", locale: locale), role: .cancel) { dismiss() }
                Button(localized("Save pack", locale: locale), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedTerms.isEmpty || packName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("vocabularyPackBuilder.save")
            }
        }
        .padding(20)
        .frame(width: 480)
        .frame(minHeight: candidates.isEmpty ? 0 : 520)
    }

    private var url: URL? {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else {
            return nil
        }
        return url
    }

    private func fetch() {
        guard let url, !isFetching else { return }
        isFetching = true
        message = nil
        Task { @MainActor in
            defer { isFetching = false }
            do {
                let docs = try await VocabularyPackStore.fetchDocumentation(from: url)
                let found = VocabularyPackExtractor.candidates(in: docs.text)
                candidates = found
                // Terms mentioned more than once are pre-selected; one-offs are optional.
                selectedTerms = Set(found.filter { $0.count > 1 }.map(\.term))
                sourceHost = url.host ?? ""
                if packName.isEmpty {
                    packName = docs.title ?? sourceHost
                }
                if found.isEmpty {
                    message = localized("No likely terms found on that page.", locale: locale)
                }
            } catch {
                Log.ui.error("Building a vocabulary pack failed: \(error.localizedDescription)")
                candidates = []
                message = String(format: localized("Couldn't read that page: %@", locale: locale), error.localizedDescription)
            }
        }
    }

    private func save() {
        let name = packName.trimmingCharacters(in: .whitespaces)
        let terms = candidates.filter { selectedTerms.contains($0.term) }.map { VocabularyPackTerm($0.term) }
        let pack = VocabularyPack(
            id: VocabularyPack.slug(for: name),
            name: name,
            summary: String(format: localized("Built from %@", locale: locale), sourceHost),
            terms: terms
        )
        do {
            try store.save(pack)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
