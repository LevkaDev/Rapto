//
//  AppBundleLookupTests.swift
//  RaptoTests
//
//  Which app a process without a bundle identifier belongs to.
//

import Testing
@testable import Rapto

struct AppBundleLookupTests {

    @Test("A helper deep inside an app bundle belongs to that app")
    func helperInsideAnApp() {
        let path = "/Applications/Sample Trader.app/Contents/SharedSupport/wine/lib/wine/x86_64-unix/wine"
        #expect(AppBundleLookup.enclosingAppPaths(of: path) == ["/Applications/Sample Trader.app"])
    }

    @Test("With an app inside an app the inner one comes first")
    func nestedApps() {
        let path = "/Applications/Outer.app/Contents/Helpers/Inner.app/Contents/MacOS/tool"
        #expect(AppBundleLookup.enclosingAppPaths(of: path) == [
            "/Applications/Outer.app/Contents/Helpers/Inner.app",
            "/Applications/Outer.app"
        ])
    }

    @Test("An executable outside every app bundle belongs to none")
    func executableOutsideAnApp() {
        #expect(AppBundleLookup.enclosingAppPaths(of: "/usr/local/bin/tool").isEmpty)
    }

    @Test("A file that is itself named like an app is not its own bundle")
    func fileNamedLikeAnApp() {
        #expect(AppBundleLookup.enclosingAppPaths(of: "/tmp/odd.app").isEmpty)
    }
}
