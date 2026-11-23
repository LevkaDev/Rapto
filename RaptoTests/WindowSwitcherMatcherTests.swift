//
//  WindowSwitcherMatcherTests.swift
//  RaptoTests
//
//  Search ranking of the window switcher
//

import Testing
import Foundation
import CoreGraphics
@testable import Rapto

@Suite("Window Switcher Matcher")
@MainActor
struct WindowSwitcherMatcherTests {

    private func entry(_ id: CGWindowID, app: String, title: String) -> WindowSwitcherEntry {
        WindowSwitcherEntry(
            window: SpaceBarWindowRef(windowID: id, pid: pid_t(id), title: title, ownerName: app),
            appName: app,
            spaceID: 1,
            displayID: "display",
            desktopNumber: 1,
            isFullScreen: false,
            isOnCurrentDesktop: true,
            displayName: nil
        )
    }

    private func names(_ query: String, in entries: [WindowSwitcherEntry]) -> [String] {
        WindowSwitcherMatcher.rank(entries, query: query).map(\.appName)
    }

    @Test("One letter finds every app starting with it, in recent order")
    func firstLetter() {
        let entries = [
            entry(1, app: "Safari", title: "Apple"),
            entry(2, app: "Terminal", title: "zsh"),
            entry(3, app: "Telegram", title: "Telegram"),
            entry(4, app: "Notes", title: "Shopping list"),
        ]
        #expect(names("t", in: entries) == ["Terminal", "Telegram"])
    }

    @Test("App name prefix ranks above a word in a window title")
    func appBeforeTitle() {
        let entries = [
            entry(1, app: "Safari", title: "Trading View"),
            entry(2, app: "Telegram", title: "Chats"),
        ]
        #expect(names("tr", in: entries).first == "Safari")
        #expect(names("t", in: entries) == ["Telegram", "Safari"])
    }

    @Test("Initials and scattered letters match the app name")
    func initialsAndSubsequence() {
        let entries = [
            entry(1, app: "Visual Studio Code", title: "main.swift"),
            entry(2, app: "Telegram", title: "Chats"),
        ]
        #expect(names("vsc", in: entries) == ["Visual Studio Code"])
        #expect(names("tg", in: entries) == ["Telegram"])
    }

    @Test("Case and accents are ignored, every query word must match")
    func normalizationAndWords() {
        let entries = [
            entry(1, app: "Safari", title: "Café menu"),
            entry(2, app: "Safari", title: "News"),
        ]
        #expect(WindowSwitcherMatcher.rank(entries, query: "SAF cafe").map(\.id) == [1])
        #expect(WindowSwitcherMatcher.rank(entries, query: "xyz").isEmpty)
    }

    @Test("Empty query keeps the original order")
    func emptyQuery() {
        let entries = [entry(1, app: "B", title: "b"), entry(2, app: "A", title: "a")]
        #expect(WindowSwitcherMatcher.rank(entries, query: "  ").map(\.id) == [1, 2])
    }
}
