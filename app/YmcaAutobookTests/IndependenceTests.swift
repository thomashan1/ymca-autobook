#if os(iOS)
import XCTest
@testable import YMCA_Booker

/// The iPhone and iPad read everything from the Mac through iCloud and never
/// contact GitHub unless it's chosen under Settings → Advanced.
final class IndependenceTests: XCTestCase {
    func testICloudIsTheDefault() {
        XCTAssertEqual(DataSource.resolve(nil), .icloud)
        XCTAssertEqual(DataSource.resolve("icloud"), .icloud)
        XCTAssertEqual(DataSource.resolve("something else"), .icloud)
        XCTAssertEqual(DataSource.resolve("github"), .github)
    }

    func testGitHubClientMakesNoCallsOutsideGitHubMode() async {
        var tokenRead = false
        // An unroutable host: if the guard failed, the error would be a network one.
        let client = GitHubClient(baseURL: URL(string: "https://example.invalid")!,
                                  tokenProvider: { tokenRead = true; return "x" },
                                  allowed: { false })
        do { _ = try await client.readFile(repo: "r", path: "classes.yml"); XCTFail("read went through") }
        catch GitHubClient.GitHubError.notInGitHubMode {} catch { XCTFail("\(error)") }
        do { try await client.writeFile(repo: "r", path: "pauses.yml", text: "", message: "m", sha: "s"); XCTFail("write went through") }
        catch GitHubClient.GitHubError.notInGitHubMode {} catch { XCTFail("\(error)") }
        do { try await client.dispatchBook(classKey: "k"); XCTFail("dispatch went through") }
        catch GitHubClient.GitHubError.notInGitHubMode {} catch { XCTFail("\(error)") }
        let reason = await client.validateToken()
        XCTAssertNotNil(reason)
        XCTAssertFalse(tokenRead, "the token must not even be read")
    }

    func testGitHubClientStillWorksInGitHubMode() async {
        let client = GitHubClient(baseURL: URL(string: "https://example.invalid")!,
                                  tokenProvider: { nil }, allowed: { true })
        do { _ = try await client.readFile(repo: "r", path: "classes.yml"); XCTFail() }
        catch GitHubClient.GitHubError.notAuthenticated {} catch { XCTFail("\(error)") }   // got past the guard
    }
}
#endif
