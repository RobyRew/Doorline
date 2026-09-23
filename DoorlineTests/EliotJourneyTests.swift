import XCTest
@testable import Doorline

@MainActor
final class EliotJourneyTests: XCTestCase {
    func testSignInPostsThePageScriptBodyAndStopsOn400() async throws {
        let wire = ScriptedEliotWire(responses: [
            page(signInHTML, cookie: "x-ms-cpim-csrf=fixture-cookie; path=/; secure"),
            json(#"{"status":"400","errorCode":"AADB2C90054","message":"Your password is incorrect."}"#),
        ])
        let journey = EliotWebJourney(wire: wire)
        do {
            _ = try await journey.submitSignIn(identifier: "  ada@example.com  ", password: " a?b);c,(d) ")
            XCTFail("A 400 page status should not return a token")
        } catch let failure as DoorEntrySignInFailure {
            XCTAssertEqual(failure.message, "Your password is incorrect.")
        }
        XCTAssertEqual(wire.sent.count, 2)
        let post = wire.sent[1]
        XCTAssertEqual(post.method, "POST")
        XCTAssertTrue(post.url.contains("/SelfAsserted?tx=StateProperties=fixture-trans&p=B2C_1_BS_DoorEntry_App_iOS-SignUpOrSignIn"))
        XCTAssertFalse(post.url.contains("rememberMe"))
        XCTAssertEqual(post.headers["X-CSRF-TOKEN"], "fixture-csrf")
        XCTAssertEqual(post.headers["Cookie"], "x-ms-cpim-csrf=fixture-cookie")
        XCTAssertEqual(post.body, "request_type=RESPONSE&logonIdentifier=ada%40example.com&password=a%3Fb)%3Bc%2C(d)")
        XCTAssertFalse(wire.sent.contains { $0.url.contains("/confirmed") })
    }

    func testSignInSendsTheTransCookieURLSessionJoinsIntoSetCookie() async throws {
        let joined = [
            "x-ms-cpim-csrf=fixture-csrf-cookie; domain=login.eliotbylegrand.com; path=/; secure",
            "x-ms-cpim-cache|fixture_0=fixture-cache; domain=login.eliotbylegrand.com; path=/; secure",
            "x-ms-cpim-trans=fixture-trans-cookie; domain=login.eliotbylegrand.com; path=/; secure",
        ].joined(separator: ", ")
        let wire = ScriptedEliotWire(responses: [
            page(signInHTML, cookie: joined),
            json(#"{"status":"400","errorCode":"AADB2C90054","message":"Your password is incorrect."}"#),
        ])
        let journey = EliotWebJourney(wire: wire)
        do {
            _ = try await journey.submitSignIn(identifier: "ada@example.com", password: "a?b);c,(d)")
            XCTFail("A 400 page status should not return a token")
        } catch let failure as DoorEntrySignInFailure {
            XCTAssertEqual(failure.message, "Your password is incorrect.")
        }
        let cookie = wire.sent[1].headers["Cookie"] ?? ""
        XCTAssertTrue(cookie.contains("x-ms-cpim-csrf=fixture-csrf-cookie"))
        XCTAssertTrue(cookie.contains("x-ms-cpim-cache|fixture_0=fixture-cache"))
        XCTAssertTrue(cookie.contains("x-ms-cpim-trans=fixture-trans-cookie"))
        XCTAssertFalse(wire.sent.contains { $0.url.contains("/confirmed") })
    }

    func testSignInExchangesTheCodeForTheAccessToken() async throws {
        let wire = ScriptedEliotWire(responses: [
            page(signInHTML, cookie: "x-ms-cpim-csrf=fixture-cookie; path=/; secure"),
            json(#"{"status":"200"}"#),
            EliotWireResponse(status: 302, headers: ["Location": "com.legrandgroup.c300x://oauth2redirect?code=fixture-code"], body: Data()),
            json(#"{"access_token":"fixture-token"}"#),
        ])
        let journey = EliotWebJourney(wire: wire)
        let token = try await journey.submitSignIn(identifier: "ada@example.com", password: "a?b);c,(d)")
        XCTAssertEqual(token, "fixture-token")
        let confirmed = wire.sent[2]
        XCTAssertEqual(confirmed.method, "GET")
        XCTAssertTrue(confirmed.url.contains("/api/CombinedSigninAndSignup/confirmed?csrf_token=fixture-csrf&tx=StateProperties=fixture-trans&p=B2C_1_BS_DoorEntry_App_iOS-SignUpOrSignIn"))
        XCTAssertFalse(confirmed.url.contains("rememberMe"))
        XCTAssertTrue(wire.sent[3].body.contains("grant_type=authorization_code"))
        XCTAssertTrue(wire.sent[3].body.contains("code=fixture-code"))
    }

    func testForgotPasswordVerificationAndPasswordPair() async throws {
        let wire = ScriptedEliotWire(responses: [
            page(resetHTML, cookie: "x-ms-cpim-csrf=reset-cookie; path=/; secure"),
            json(#"{"status":"200"}"#),
            json(#"{"status":"200"}"#),
            json(#"{"status":"400","message":"That code is incorrect. Please try again."}"#),
        ])
        let journey = EliotWebJourney(wire: wire)
        try await journey.loadPasswordReset()
        try await journey.sendCode(claimId: "email", claimValue: " ada@example.com ")
        try await journey.verifyCode(claimId: "email", claimValue: "ada@example.com", userInput: " 123456 ")
        do {
            try await journey.submit(["email": "ada@example.com"])
            XCTFail("A 400 continue should not advance")
        } catch let failure as DoorEntrySignInFailure {
            XCTAssertEqual(failure.message, "That code is incorrect. Please try again.")
        }
        XCTAssertEqual(wire.sent[1].body, "&request_type=VERIFICATION_REQUEST&claim_id=email&claim_value=ada%40example.com")
        XCTAssertEqual(wire.sent[2].body, "&request_type=VALIDATION_REQUEST&claim_id=email&claim_value=ada%40example.com&user_input=123456")
        XCTAssertEqual(wire.sent[1].headers["Cookie"], "x-ms-cpim-csrf=reset-cookie")
        XCTAssertFalse(wire.sent.contains { $0.url.contains("/confirmed") })

        let next = ScriptedEliotWire(responses: [
            page(newPasswordHTML, cookie: "x-ms-cpim-csrf=reset-cookie; path=/; secure"),
            json(#"{"status":"200"}"#),
            page(newPasswordHTML, cookie: ""),
        ])
        let second = EliotWebJourney(wire: next)
        try await second.loadPasswordReset()
        let before = next.sent.count
        do {
            try await second.submit(["newPassword": "Abcdef1!", "reenterPassword": "Otherpass1!"])
            XCTFail("Mismatched passwords should not be posted")
        } catch {
            XCTAssertEqual(next.sent.count, before)
        }
        try await second.submit(["newPassword": "Abcdef1!", "reenterPassword": "Abcdef1!"])
        XCTAssertTrue(next.sent.contains { $0.body == "newPassword=Abcdef1!&reenterPassword=Abcdef1!&request_type=RESPONSE" })
        XCTAssertTrue(next.sent.contains { $0.method == "GET" && $0.url.contains("/api/SelfAsserted/confirmed?csrf_token=fixture-csrf&tx=StateProperties=fixture-trans&p=B2C_1_BS_DoorEntry_App_iOS-password") })
    }

    func testRegistrationPostsConsentAndStopsOn400() async throws {
        let wire = ScriptedEliotWire(responses: [
            page(signInHTML, cookie: "x-ms-cpim-csrf=signup-cookie; path=/; secure"),
            page(signupHTML, cookie: ""),
            json(#"{"status":"400","message":"A required field is missing. Please fill out all required fields and try again."}"#),
        ])
        let journey = EliotWebJourney(wire: wire)
        try await journey.loadRegistration()
        XCTAssertTrue(wire.sent[1].url.contains("/api/CombinedSigninAndSignup/unified?local=signup&csrf_token=fixture-csrf&tx=StateProperties=fixture-trans&p=B2C_1_BS_DoorEntry_App_iOS-SignUpOrSignIn"))
        let before = wire.sent.count
        do {
            try await journey.submit([
                "email": "ada@example.com",
                "newPassword": "short",
                "reenterPassword": "short",
                "givenName": "Ada",
                "surname": "Lovelace",
                "country": "it",
                "extension_CGU": "1",
                "extension_PrivacyPolicy": "1",
            ])
            XCTFail("A password that misses the page pattern should not be posted")
        } catch {
            XCTAssertEqual(wire.sent.count, before)
        }
        do {
            try await journey.submit([
                "email": "ada@example.com",
                "newPassword": "Abcdef1!",
                "reenterPassword": "Abcdef1!",
                "givenName": "Ada",
                "surname": "Lovelace",
                "country": "it",
                "extension_CGU": "1",
                "extension_PrivacyPolicy": "1",
            ])
            XCTFail("A 400 registration response should not continue")
        } catch let failure as DoorEntrySignInFailure {
            XCTAssertEqual(failure.message, "A required field is missing. Please fill out all required fields and try again.")
        }
        let posted = wire.sent.last
        XCTAssertEqual(posted?.body, "email=ada%40example.com&newPassword=Abcdef1!&reenterPassword=Abcdef1!&givenName=Ada&surname=Lovelace&extension_CGU=1&extension_PrivacyPolicy=1&country=it&request_type=RESPONSE")
        XCTAssertFalse(wire.sent.contains { $0.url.contains("/confirmed") })
        XCTAssertEqual(posted?.headers["Cookie"], "x-ms-cpim-csrf=signup-cookie")
    }

    private func page(_ html: String, cookie: String) -> EliotWireResponse {
        var headers: [String: String] = [:]
        if !cookie.isEmpty { headers["Set-Cookie"] = cookie }
        return EliotWireResponse(status: 200, headers: headers, body: Data(html.utf8))
    }

    private func json(_ text: String) -> EliotWireResponse {
        EliotWireResponse(status: 200, headers: [:], body: Data(text.utf8))
    }
}

private final class ScriptedEliotWire: EliotWire {
    var responses: [EliotWireResponse]
    var sent: [EliotWireRequest] = []
    init(responses: [EliotWireResponse]) { self.responses = responses }

    func send(_ request: EliotWireRequest) async throws -> EliotWireResponse {
        sent.append(request)
        return responses.removeFirst()
    }
}

private let signInHTML = """
<script>
var SETTINGS = {"csrf":"fixture-csrf","transId":"StateProperties=fixture-trans","api":"CombinedSigninAndSignup","trimSpacesInPassword":true,"hosts":{"tenant":"/EliotClouduamprd.onmicrosoft.com/B2C_1_BS_DoorEntry_App_iOS-SignUpOrSignIn","policy":"B2C_1_BS_DoorEntry_App_iOS-SignUpOrSignIn"}};
var SA_FIELDS = {"AttributeFields":[{"ID":"logonIdentifier","UX_INPUT_TYPE":"TextBox","IS_REQ":true,"VERIFY":false,"PAT":"","OPTIONS":[]},{"ID":"password","UX_INPUT_TYPE":"Password","IS_REQ":true,"VERIFY":false,"PAT":"","OPTIONS":[]}]};
</script>
"""

private let resetHTML = """
<script>
var SETTINGS = {"csrf":"fixture-csrf","transId":"StateProperties=fixture-trans","api":"SelfAsserted","trimSpacesInPassword":true,"hosts":{"tenant":"/EliotClouduamprd.onmicrosoft.com/B2C_1_BS_DoorEntry_App_iOS-password","policy":"B2C_1_BS_DoorEntry_App_iOS-password"}};
var SA_FIELDS = {"AttributeFields":[{"ID":"email","UX_INPUT_TYPE":"EmailBox","IS_REQ":true,"VERIFY":true,"PAT":"","OPTIONS":[]}]};
</script>
"""

private let newPasswordHTML = """
<script>
var SETTINGS = {"csrf":"fixture-csrf","transId":"StateProperties=fixture-trans","api":"SelfAsserted","trimSpacesInPassword":true,"hosts":{"tenant":"/EliotClouduamprd.onmicrosoft.com/B2C_1_BS_DoorEntry_App_iOS-password","policy":"B2C_1_BS_DoorEntry_App_iOS-password"}};
var SA_FIELDS = {"AttributeFields":[{"ID":"newPassword","UX_INPUT_TYPE":"Password","IS_REQ":true,"VERIFY":false,"PAT":"^(?=.*[a-z])(?=.*[A-Z])(?=.*\\\\d).{8,16}$","OPTIONS":[]},{"ID":"reenterPassword","UX_INPUT_TYPE":"Password","IS_REQ":true,"VERIFY":false,"PAT":"","OPTIONS":[]}]};
</script>
"""

private let signupHTML = """
<script>
var SETTINGS = {"csrf":"fixture-csrf","transId":"StateProperties=fixture-trans","api":"SelfAsserted","trimSpacesInPassword":true,"hosts":{"tenant":"/EliotClouduamprd.onmicrosoft.com/B2C_1_BS_DoorEntry_App_iOS-SignUpOrSignIn","policy":"B2C_1_BS_DoorEntry_App_iOS-SignUpOrSignIn"}};
var SA_FIELDS = {"AttributeFields":[{"ID":"email","UX_INPUT_TYPE":"EmailBox","IS_REQ":true,"VERIFY":true,"PAT":"","OPTIONS":[]},{"ID":"newPassword","UX_INPUT_TYPE":"Password","IS_REQ":true,"VERIFY":false,"PAT":"^(?=.*[a-z])(?=.*[A-Z])(?=.*\\\\d).{8,16}$","OPTIONS":[]},{"ID":"reenterPassword","UX_INPUT_TYPE":"Password","IS_REQ":true,"VERIFY":false,"PAT":"","OPTIONS":[]},{"ID":"givenName","UX_INPUT_TYPE":"TextBox","IS_REQ":true,"VERIFY":false,"PAT":"","OPTIONS":[]},{"ID":"surname","UX_INPUT_TYPE":"TextBox","IS_REQ":true,"VERIFY":false,"PAT":"","OPTIONS":[]},{"ID":"country","UX_INPUT_TYPE":"DropdownSingleSelect","IS_REQ":true,"VERIFY":false,"PAT":"","OPTIONS":[{"VAL":"it","DISP":"Italy"},{"VAL":"fr","DISP":"France"}]},{"ID":"extension_CGU","UX_INPUT_TYPE":"CheckboxMultiSelect","IS_REQ":true,"VERIFY":false,"PAT":"","OPTIONS":[{"VAL":"1","DISP":"terms"}]},{"ID":"extension_PrivacyPolicy","UX_INPUT_TYPE":"CheckboxMultiSelect","IS_REQ":true,"VERIFY":false,"PAT":"","OPTIONS":[{"VAL":"1","DISP":"privacy"}]},{"ID":"extension_Language","UX_INPUT_TYPE":"DropdownSingleSelect","IS_REQ":false,"VERIFY":false,"PAT":"","OPTIONS":[{"VAL":"en","DISP":"English"},{"VAL":"fr","DISP":"Francais"},{"VAL":"it","DISP":"Italiano"}]},{"ID":"displayName","UX_INPUT_TYPE":"TextBox","IS_REQ":false,"VERIFY":false,"PAT":"","OPTIONS":[]}]};
</script>
"""
