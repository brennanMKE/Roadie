import Foundation
import Testing
import PlexKit
import PlexKitStub

struct PlexPinSignInTests {
    typealias Outcome = Result<PlexToken, PlexSignInFailure>

    static let options = PlexPinSignIn.Options(pollInterval: .milliseconds(50), timeout: .seconds(5), maxConsecutiveFailures: 3)

    private func make(options: PlexPinSignIn.Options = PlexPinSignInTests.options) -> (StubURLProtocol.Handle, PlexPinSignIn, PlexAccountClient) {
        let handle = StubURLProtocol.handle()
        let account = PlexTv.account(handle)
        return (handle, PlexPinSignIn(account: account, options: options), account)
    }

    private static func run(_ signIn: PlexPinSignIn, _ recorder: URLRecorder) async -> Outcome {
        do throws(PlexSignInFailure) {
            return .success(try await signIn.run(open: recorder.opener))
        } catch {
            return .failure(error)
        }
    }

    private func pollCount(_ handle: StubURLProtocol.Handle) -> Int {
        handle.recorded.filter(PlexTv.isPoll).count
    }

    private func createdWithExpiry(_ seconds: Int) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: PlexFixture.pinCreated.data) as? [String: Any])
        object["expiresIn"] = seconds
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func signInOpensTheBrowserThenPollsUntilClaimed() async throws {
        let fake = try PlexTv.fakeToken
        let (handle, signIn, account) = make()
        handle.register([try PlexTv.createRoute(), try PlexTv.pollRoute()])
        let recorder = URLRecorder()
        let task = Task { await Self.run(signIn, recorder) }
        #expect(await PlexTv.wait { pollCount(handle) >= 2 })
        handle.register([try PlexTv.createRoute(), try PlexTv.pollRoute(.pinClaimed)])
        let outcome = await task.value
        #expect(outcome == .success(PlexToken(fake)))
        let created = try JSONDecoder().decode(PlexPin.self, from: PlexFixture.pinCreated.data)
        #expect(recorder.opened == [account.authURL(for: created)])
        let methods = handle.recorded.map(\.method)
        #expect(methods.first == "POST")
        #expect(methods.dropFirst().allSatisfy { $0 == "GET" })
        #expect(methods.count >= 3)
    }

    @Test func cancellationWhileAPollIsInFlightStopsWithoutAToken() async throws {
        let (handle, signIn, _) = make()
        handle.register([try PlexTv.createRoute(), try PlexTv.pollRoute(delay: 60)])
        let recorder = URLRecorder()
        let task = Task { await Self.run(signIn, recorder) }
        // The stub records at startLoading and then holds the poll, so the loop is inside the fetch.
        #expect(await PlexTv.wait { pollCount(handle) >= 1 })
        let start = ContinuousClock.now
        task.cancel()
        let outcome = await task.value
        // The cancel, not the 60 s gate, ended the held request.
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(outcome == .failure(.cancelled))
        // No sleep before counting: the only poll ever handed to URLSession was recorded before the
        // cancel, and run has returned with nothing detached, so the count cannot change.
        #expect(handle.recorded.map(\.method) == ["POST", "GET"])
        #expect(pollCount(handle) == 1)
        #expect(recorder.opened.count == 1)
    }

    @Test func cancellationBetweenPollsSendsNoPoll() async throws {
        let options = PlexPinSignIn.Options(pollInterval: .seconds(60), timeout: .seconds(120), maxConsecutiveFailures: 3)
        let (handle, signIn, _) = make(options: options)
        handle.register([try PlexTv.createRoute(), try PlexTv.pollRoute()])
        let recorder = URLRecorder()
        let task = Task { await Self.run(signIn, recorder) }
        // The browser opens just before the first sleep, and no poll can be issued for 60 s after it.
        #expect(await PlexTv.wait { recorder.opened.count == 1 })
        task.cancel()
        #expect(await task.value == .failure(.cancelled))
        #expect(pollCount(handle) == 0)
        #expect(handle.recorded.map(\.method) == ["POST"])
    }

    @Test func expiredPinFails() async throws {
        let (handle, signIn, _) = make()
        handle.register([try PlexTv.createRoute(), try PlexTv.pollRoute(status: 404)])
        #expect(await Self.run(signIn, URLRecorder()) == .failure(.expired))

        handle.reset()
        handle.register([.init(method: "POST", path: "/api/v2/pins", status: 201, body: try createdWithExpiry(0)), try PlexTv.pollRoute()])
        #expect(await Self.run(signIn, URLRecorder()) == .failure(.expired))
        #expect(pollCount(handle) == 0)
    }

    @Test func timeoutFails() async throws {
        let options = PlexPinSignIn.Options(pollInterval: .milliseconds(50), timeout: .milliseconds(200), maxConsecutiveFailures: 3)
        let (handle, signIn, _) = make(options: options)
        handle.register([try PlexTv.createRoute(), try PlexTv.pollRoute()])
        #expect(await Self.run(signIn, URLRecorder()) == .failure(.timedOut))
        let count = pollCount(handle)
        #expect(count >= 1)
        try await Task.sleep(for: .seconds(0.2))
        #expect(pollCount(handle) == count)
    }

    @Test func pinCreationFailureIsUnreachable() async throws {
        let (handle, signIn, _) = make()
        handle.register([.init(method: "POST", path: "/api/v2/pins", error: URLError(.notConnectedToInternet))])
        let recorder = URLRecorder()
        #expect(await Self.run(signIn, recorder) == .failure(.unreachable(.transport(.notConnectedToInternet))))
        #expect(recorder.opened.isEmpty)
    }

    @Test func browserThatCannotOpenFails() async throws {
        let (handle, signIn, _) = make()
        handle.register([try PlexTv.createRoute(), try PlexTv.pollRoute()])
        let recorder = URLRecorder(result: false)
        #expect(await Self.run(signIn, recorder) == .failure(.couldNotOpenBrowser))
        #expect(recorder.opened.count == 1)
        #expect(pollCount(handle) == 0)
    }

    @Test func pollingSurvivesTransientFailures() async throws {
        let fake = try PlexTv.fakeToken
        let (handle, signIn, _) = make()
        let failing = try PlexTv.pollRoute(error: URLError(.networkConnectionLost))
        // The stub itself fails the first two polls and then answers with the claimed PIN, so no
        // timing between the test and the loop matters.
        handle.register([
            try PlexTv.createRoute(),
            try PlexTv.pollRoute(error: URLError(.networkConnectionLost), times: 2),
            try PlexTv.pollRoute(.pinClaimed),
        ])
        #expect(await Self.run(signIn, URLRecorder()) == .success(PlexToken(fake)))
        #expect(pollCount(handle) == 3)

        handle.reset()
        handle.register([try PlexTv.createRoute(), failing])
        #expect(await Self.run(signIn, URLRecorder()) == .failure(.unreachable(.transport(.networkConnectionLost))))
        #expect(pollCount(handle) == 3)
    }

    @Test func messagesMatchTheDoc() {
        #expect(PlexSignInFailure.unreachable(.httpStatus(500)).message == "Can't reach plex.tv. Check your internet connection and try again.")
        #expect(PlexSignInFailure.couldNotOpenBrowser.message == "Couldn't open your browser. Paste a token instead.")
        #expect(PlexSignInFailure.expired.message == "The sign-in code expired before it was used. Try again.")
        #expect(PlexSignInFailure.timedOut.message == "Sign-in took too long. Try again.")
        #expect(PlexSignInFailure.cancelled.message == "Sign-in was cancelled.")
        for failure in [PlexSignInFailure.unreachable(.notFound), .couldNotOpenBrowser, .expired, .timedOut, .cancelled] {
            #expect(failure.errorDescription == failure.message)
        }
        #expect(PlexSignInFailure.cancelled.underlying == nil)
        #expect(PlexSignInFailure.unreachable(.notFound).underlying == .notFound)
    }

    @Test func failuresAndTheLoopNeverContainTheToken() async throws {
        let fake = try PlexTv.fakeToken
        let (handle, signIn, account) = make()
        var failures: [PlexSignInFailure] = []

        handle.register([try PlexTv.createRoute(), try PlexTv.pollRoute(status: 404)])
        if case .failure(let f) = await Self.run(signIn, URLRecorder()) { failures.append(f) }
        handle.register([try PlexTv.createRoute(), try PlexTv.pollRoute(error: URLError(.networkConnectionLost))])
        if case .failure(let f) = await Self.run(signIn, URLRecorder()) { failures.append(f) }
        handle.register([try PlexTv.createRoute(), try PlexTv.pollRoute()])
        if case .failure(let f) = await Self.run(signIn, URLRecorder(result: false)) { failures.append(f) }
        handle.register([.init(method: "POST", path: "/api/v2/pins", error: URLError(.notConnectedToInternet))])
        if case .failure(let f) = await Self.run(signIn, URLRecorder()) { failures.append(f) }
        failures.append(.cancelled)
        failures.append(.timedOut)
        #expect(failures.count == 6)

        for failure in failures {
            for text in [String(describing: failure), String(reflecting: failure), failure.localizedDescription] {
                #expect(!text.contains(fake))
            }
        }
        for text in [String(describing: signIn), String(reflecting: signIn), String(describing: account), String(reflecting: account)] {
            #expect(!text.contains(fake))
        }
    }
}
