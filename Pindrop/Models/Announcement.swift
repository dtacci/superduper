//
//  Announcement.swift
//  Pindrop
//
//  Created on 2026-07-07.
//

import Foundation

struct Announcement: Identifiable {
    let id: String
    let titleKey: String
    let headerKey: String
    let subtitleKey: String
    let footerKey: String?
    let items: [AnnouncementItem]
}

struct AnnouncementItem: Identifiable {
    enum Visual {
        case symbol(String)
        case orbDemo
    }

    let id: String
    let visual: Visual
    let titleKey: String
    let bodyKey: String
    let credit: AnnouncementCredit?
}

struct AnnouncementCredit {
    let name: String
    let url: URL?
    let labelKey: String
}

enum AnnouncementCatalog {
    /// Upstream announcements describe features intentionally removed from this
    /// fork. A future release can add a fork-specific, localized announcement.
    static let current: Announcement? = nil
}
