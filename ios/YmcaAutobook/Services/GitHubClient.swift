import Foundation

/// Thin GitHub REST client. Everything the app needs routes through here, so a
/// later migration to a Cloudflare Worker only touches `baseURL` + `authHeader`.
struct GitHubClient {
    var baseURL = Config.apiBase
    var tokenProvider: () -> String? = { KeychainStore.token() }

    enum GitHubError: Error { case notAuthenticated, http(Int, String), decode }

    // MARK: Auth

    /// Verify the stored token by hitting an endpoint that only needs a valid
    /// credential. Returns nil on success, or a human-readable reason.
    func validateToken() async -> String? {
        let url = baseURL.appending(path: "/user")
        do {
            _ = try await send(url, method: "GET", json: nil)
            return nil
        } catch GitHubError.notAuthenticated {
            return "No token stored."
        } catch GitHubError.http(let code, _) where code == 401 {
            return "GitHub rejected this token (401 Bad credentials). Paste the full token (it starts with github_pat_ and is long) and make sure it hasn't expired."
        } catch GitHubError.http(let code, _) {
            return "GitHub returned \(code). Check the token's repository access and permissions."
        } catch {
            return "Couldn't reach GitHub: \(error.localizedDescription)"
        }
    }

    // MARK: Contents API

    struct FileContents: Decodable {
        let content: String   // base64
        let sha: String
        var decoded: String? {
            let cleaned = content.replacingOccurrences(of: "\n", with: "")
            guard let data = Data(base64Encoded: cleaned) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// Read a file's raw text + blob sha (sha needed to write it back).
    func readFile(repo: String, path: String) async throws -> (text: String, sha: String) {
        let url = baseURL.appending(path: "/repos/\(Config.owner)/\(repo)/contents/\(path)")
        let file: FileContents = try await get(url)
        guard let text = file.decoded else { throw GitHubError.decode }
        return (text, file.sha)
    }

    /// Commit new contents for a file. `sha` is the previous blob sha.
    /// Pass `branch` to commit somewhere other than the default branch.
    func writeFile(repo: String, path: String, text: String, message: String,
                   sha: String, branch: String? = nil) async throws {
        let url = baseURL.appending(path: "/repos/\(Config.owner)/\(repo)/contents/\(path)")
        var body: [String: Any] = [
            "message": message,
            "content": Data(text.utf8).base64EncodedString(),
            "sha": sha,
        ]
        if let branch { body["branch"] = branch }
        _ = try await send(url, method: "PUT", json: body)
    }

    // MARK: Branches & pull requests (for editing protected main via PR)

    private struct Ref: Decodable { let object: Obj; struct Obj: Decodable { let sha: String } }

    /// Current head commit sha of a branch.
    func headSha(repo: String = Config.publicRepo, branch: String = "main") async throws -> String {
        let url = baseURL.appending(path: "/repos/\(Config.owner)/\(repo)/git/ref/heads/\(branch)")
        let ref: Ref = try await get(url)
        return ref.object.sha
    }

    /// Create a new branch at `fromSha`.
    func createBranch(_ name: String, fromSha: String, repo: String = Config.publicRepo) async throws {
        let url = baseURL.appending(path: "/repos/\(Config.owner)/\(repo)/git/refs")
        _ = try await send(url, method: "POST", json: ["ref": "refs/heads/\(name)", "sha": fromSha])
    }

    struct PullRequest: Decodable { let number: Int; let html_url: String; let node_id: String }

    func createPR(title: String, head: String, base: String = "main",
                  body: String, repo: String = Config.publicRepo) async throws -> PullRequest {
        let url = baseURL.appending(path: "/repos/\(Config.owner)/\(repo)/pulls")
        let data = try await send(url, method: "POST",
                                  json: ["title": title, "head": head, "base": base, "body": body])
        guard let pr = try? JSONDecoder().decode(PullRequest.self, from: data) else { throw GitHubError.decode }
        return pr
    }

    /// Merge a PR immediately (works when no required checks block it).
    func mergePR(number: Int, repo: String = Config.publicRepo) async throws {
        let url = baseURL.appending(path: "/repos/\(Config.owner)/\(repo)/pulls/\(number)/merge")
        _ = try await send(url, method: "PUT", json: ["merge_method": "squash"])
    }

    /// Best-effort: enable auto-merge so the PR lands once checks pass.
    /// Requires auto-merge to be enabled in the repo settings.
    func enableAutoMerge(prNodeId: String) async throws {
        let url = baseURL.appending(path: "/graphql")
        let mutation = "mutation($id:ID!){enablePullRequestAutoMerge(input:{pullRequestId:$id,mergeMethod:SQUASH}){clientMutationId}}"
        _ = try await send(url, method: "POST",
                           json: ["query": mutation, "variables": ["id": prNodeId]])
    }

    // MARK: Actions API

    /// Fire `book.yml` for a one-off booking of a specific class key.
    func dispatchBook(classKey: String, ref: String = "main") async throws {
        let url = baseURL.appending(
            path: "/repos/\(Config.owner)/\(Config.publicRepo)/actions/workflows/\(Config.bookWorkflow)/dispatches")
        let body: [String: Any] = ["ref": ref, "inputs": ["class_key": classKey]]
        _ = try await send(url, method: "POST", json: body)
    }

    struct RunList: Decodable { let workflow_runs: [Run] }
    struct Run: Decodable {
        let id: Int
        let name: String?
        let status: String?       // queued | in_progress | completed
        let conclusion: String?   // success | failure | ...
        let created_at: Date
    }

    /// Recent workflow runs, newest first — feeds the Jobs "recent" section.
    func recentRuns(perPage: Int = 20) async throws -> [Run] {
        let url = baseURL
            .appending(path: "/repos/\(Config.owner)/\(Config.publicRepo)/actions/runs")
            .appending(queryItems: [.init(name: "per_page", value: String(perPage))])
        let list: RunList = try await get(url)
        return list.workflow_runs
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let data = try await send(url, method: "GET", json: nil)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let value = try? dec.decode(T.self, from: data) else { throw GitHubError.decode }
        return value
    }

    @discardableResult
    private func send(_ url: URL, method: String, json: [String: Any]?) async throws -> Data {
        guard let token = tokenProvider() else { throw GitHubError.notAuthenticated }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let json { req.httpBody = try JSONSerialization.data(withJSONObject: json) }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw GitHubError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
