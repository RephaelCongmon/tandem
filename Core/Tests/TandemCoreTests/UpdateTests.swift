import XCTest
@testable import TandemCore

final class AppVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(AppVersion("1.2.3")?.components, [1, 2, 3])
        XCTAssertEqual(AppVersion("v1.10.0")?.components, [1, 10, 0])
        XCTAssertEqual(AppVersion(" 2 ")?.components, [2])
        for bad in ["", "v", "1..2", "1.2.x", "-1.0", "1.2.3.4.5", "1.٢"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
    }

    func testOrdering() throws {
        let v = { (text: String) in AppVersion(text)! }
        XCTAssertLessThan(v("1.9"), v("1.10"))
        XCTAssertLessThan(v("1.0.0"), v("1.0.1"))
        XCTAssertLessThan(v("1.1"), v("1.1.1"))
        XCTAssertLessThan(v("0.9.9"), v("1.0"))
        XCTAssertEqual(v("1.1"), v("1.1.0"))
        XCTAssertEqual(v("v2.0"), v("2"))
        XCTAssertEqual(Set([v("1.1"), v("1.1.0")]).count, 1, "equal versions hash alike")
        XCTAssertFalse(v("1.2") < v("1.2.0"))
        XCTAssertEqual(v("1.10.2").description, "1.10.2")
    }
}

final class ReleaseFeedTests: XCTestCase {
    private let restJSON = #"""
    {
      "tag_name": "v1.2.0",
      "name": "Tandem 1.2.0",
      "body": "- Update Now button\n- Faster pairing",
      "draft": false,
      "prerelease": false,
      "published_at": "2026-09-30T10:00:00Z",
      "assets": [
        {"name": "Tandem-1.2.0.dmg", "url": "https://api.github.com/repos/o/r/releases/assets/2", "size": 7400000},
        {"name": "Tandem-1.2.0.zip", "url": "https://api.github.com/repos/o/r/releases/assets/1", "size": 6600000}
      ]
    }
    """#

    func testDecodesTheRESTAPIRelease() throws {
        let release = try ReleaseDecoding.rest(Data(restJSON.utf8))
        XCTAssertEqual(release.tag, "v1.2.0")
        XCTAssertEqual(release.version, AppVersion("1.2.0"))
        XCTAssertEqual(release.title, "Tandem 1.2.0")
        XCTAssertEqual(release.notes, "- Update Now button\n- Faster pairing")
        XCTAssertNotNil(release.publishedAt)
        XCTAssertEqual(release.appArchive?.name, "Tandem-1.2.0.zip", "the zip, not the disk image")
        XCTAssertEqual(release.appArchive?.apiURL?.absoluteString, "https://api.github.com/repos/o/r/releases/assets/1")
    }

    func testDecodesTheGitHubCLIRelease() throws {
        let json = #"""
        {"assets":[{"apiUrl":"https://api.github.com/repos/o/r/releases/assets/9","name":"Tandem-1.3.zip","size":10}],
         "body":"","name":"","publishedAt":"2026-10-01T08:30:00Z","tagName":"v1.3"}
        """#
        let release = try ReleaseDecoding.cli(Data(json.utf8))
        XCTAssertEqual(release.version, AppVersion("1.3.0"))
        XCTAssertEqual(release.title, "Tandem 1.3", "an empty title gets a default")
        XCTAssertEqual(release.appArchive?.name, "Tandem-1.3.zip")
    }

    func testNonVersionTagsAreRejected() {
        let json = #"{"tag_name":"nightly","assets":[]}"#
        XCTAssertThrowsError(try ReleaseDecoding.rest(Data(json.utf8)))
    }

    func testTokenIsSentToGitHubButNotAcrossRedirects() {
        let feed = GitHubAPIFeed(repository: "o/r", token: " secret \n")
        let original = feed.request(URL(string: "https://api.github.com/repos/o/r/releases/assets/1")!, accept: "application/octet-stream")
        XCTAssertEqual(original.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(original.value(forHTTPHeaderField: "Accept"), "application/octet-stream")

        var storage = original
        storage.url = URL(string: "https://objects.githubusercontent.com/signed?x=1")
        XCTAssertNil(GitHubAPIFeed.redirected(storage, from: original).value(forHTTPHeaderField: "Authorization"))

        var sameHost = original
        sameHost.url = URL(string: "https://api.github.com/repositories/1/releases/assets/1")
        XCTAssertEqual(GitHubAPIFeed.redirected(sameHost, from: original).value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testHTTPErrorsExplainTheFix() {
        func error(_ status: Int) -> UpdateError? {
            let response = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
            do { try GitHubAPIFeed.check(response, repository: "o/r"); return nil } catch { return error as? UpdateError }
        }
        XCTAssertNil(error(200))
        guard case .accessDenied? = error(401) else { return XCTFail("401") }
        guard case .accessDenied? = error(403) else { return XCTFail("403") }
        guard case .noRelease? = error(404) else { return XCTFail("404") }
        guard case .network? = error(500) else { return XCTFail("500") }
    }
}

final class UpdateInstallerTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testInstallLocation() {
        let apps = URL(fileURLWithPath: "/Applications")
        let userApps = URL(fileURLWithPath: "/Users/me/Applications")
        func location(_ path: String, writable: Set<String> = ["/Applications", "/Users/me/Tools"], readOnly: Bool = false) -> String {
            UpdateInstaller.installLocation(
                for: URL(fileURLWithPath: path),
                isWritable: { writable.contains($0.path) },
                isOnReadOnlyVolume: { _ in readOnly },
                applications: apps,
                userApplications: userApps
            ).path
        }
        XCTAssertEqual(location("/Applications/Tandem.app"), "/Applications/Tandem.app", "updated in place")
        XCTAssertEqual(location("/Users/me/Tools/Tandem.app"), "/Users/me/Tools/Tandem.app")
        XCTAssertEqual(location("/Volumes/Tandem 1.0.0/Tandem.app", readOnly: true), "/Applications/Tandem.app", "a disk image moves to Applications")
        XCTAssertEqual(location("/private/var/folders/x/AppTranslocation/ABC/d/Tandem.app"), "/Applications/Tandem.app")
        XCTAssertEqual(location("/Volumes/Tandem 1.0.0/Tandem.app", writable: [], readOnly: true), "/Users/me/Applications/Tandem.app")
    }

    private func makeBundle(_ name: String, marker: String) throws -> URL {
        let app = scratch.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try marker.write(to: contents.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        return app
    }

    func testInstallReplacesAnExistingApp() throws {
        let installed = try makeBundle("Installed/Tandem.app", marker: "old")
        let update = try makeBundle("Update/Tandem.app", marker: "new")
        try UpdateInstaller.install(update, at: installed)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8), "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["Tandem.app"], "no staging folders left behind")
    }

    func testInstallCreatesTheAppWhenMissing() throws {
        let update = try makeBundle("Update/Tandem.app", marker: "new")
        let target = scratch.appendingPathComponent("Applications/Tandem.app")
        try UpdateInstaller.install(update, at: target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Contents/marker"), encoding: .utf8), "new")
    }

    func testUnsignedOrForeignAppsAreRefused() async throws {
        // A bundle with the right identifier and version but no signature.
        let app = try makeBundle("Pack/Tandem.app", marker: "x")
        let plist: [String: Any] = ["CFBundleIdentifier": "com.rofel.tandem", "CFBundleShortVersionString": "9.0", "CFBundleExecutable": "Tandem", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let archive = scratch.appendingPathComponent("Tandem-9.0.zip")
        let zip = await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--keepParent", app.path, archive.path], timeout: 30)
        XCTAssertEqual(zip?.status, 0)

        do {
            _ = try await UpdateInstaller.prepare(archive: archive, expectedVersion: AppVersion("9.0")!, bundleIdentifier: "com.rofel.tandem", teamIdentifier: "2TJNTBA58V")
            XCTFail("an unsigned app must not pass")
        } catch UpdateError.invalidPackage(let message) {
            XCTAssertTrue(message.contains("signed"), message)
        }
        do {
            _ = try await UpdateInstaller.prepare(archive: archive, expectedVersion: AppVersion("9.1")!, bundleIdentifier: "com.rofel.tandem", teamIdentifier: "2TJNTBA58V")
            XCTFail("the wrong version must not pass")
        } catch UpdateError.invalidPackage(let message) {
            XCTAssertTrue(message.contains("9.1"), message)
        }
        do {
            _ = try await UpdateInstaller.prepare(archive: archive, expectedVersion: AppVersion("9.0")!, bundleIdentifier: "com.example.other", teamIdentifier: "2TJNTBA58V")
            XCTFail("a different app must not pass")
        } catch UpdateError.invalidPackage {}
    }

    func testAppleSignedAppsDontMatchOurTeam() {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        XCTAssertThrowsError(try CodeSignature.verify(appAt: calculator, bundleIdentifier: "com.apple.calculator", teamIdentifier: "2TJNTBA58V"))
    }

    func testABuiltTandemPassesItsOwnTeamCheck() throws {
        let built = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/Release.noindex/Build/Products/Release/Tandem.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: built.path), "build the Release app first (scripts/build-release.sh)")
        let team = try XCTUnwrap(CodeSignature.teamIdentifier(ofAppAt: built))
        XCTAssertNoThrow(try CodeSignature.verify(appAt: built, bundleIdentifier: "com.rofel.tandem", teamIdentifier: team))
        XCTAssertThrowsError(try CodeSignature.verify(appAt: built, bundleIdentifier: "com.rofel.tandem", teamIdentifier: "ZZZZZZZZZZ"))
    }
}
