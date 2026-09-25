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
    }

    private var addPackMenu: some View {
        Menu {
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
