import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct PermissionReviewSourceTests {
    static func main() {
        let cid = "38447143434855682"
        let reject = #"[1:1:1014/130409.867389:INFO:x] DidStartNavigation chat_page_navigate_event: stage=navigation_start, url: https://example/agent-confirm_09_10_1.html?requestId=common-ask-human-action-button-1791954249805-sxzn1w8jjkp\u0026text=reject, last_committed_url: doubao://doubao-chat/chat/38447143434855682, IsSameDocument: 0"#
        let allow = #"[1:1:1014/130409.929925:INFO:x] DidStartNavigation chat_page_navigate_event: stage=navigation_start, url: https://example/agent-confirm_09_10_1.html?requestId=common-ask-human-action-button-1791954249805-9r81mqae8z\u0026text=allow, last_committed_url: doubao://doubao-chat/chat/38447143434855682, IsSameDocument: 0"#
        let first = PermissionReviewSource.reviewPresented(in: reject)
        let second = PermissionReviewSource.reviewPresented(in: allow)
        require(first?.conversationID == cid, "review must retain conversation id")
        require(first?.reviewID == "permission-review-1791954249805", "review id must use shared timestamp")
        require(second == first, "allow and reject buttons must collapse to one review")

        let unrelated = #"DidStartNavigation chat_page_navigate_event: url: https://example/not-confirm.html?requestId=common-ask-human-action-button-1791954249805-x, last_committed_url: doubao://doubao-chat/chat/38447143434855682"#
        require(PermissionReviewSource.reviewPresented(in: unrelated) == nil, "ordinary navigation must not be a review")

        let toolStart = #"[lid={"conversation_id":"38447143434855682","agent_id":"x","sandbox_id":"sandbox-a","tcid":"888a4576-31ab-4acf-93de-7d70c809c53b"}] [sandbox] operator() bash.run enter request_id=x"#
        let started = PermissionReviewSource.toolStarted(in: toolStart)
        require(started?.conversationID == cid, "tool start must retain conversation id")
        require(started?.toolCallID == "888a4576-31ab-4acf-93de-7d70c809c53b", "tool start must retain tcid")

        let permissionModeOnly = #"tool execution permission mode resolved, permission_mode=ask_on_demand"#
        require(PermissionReviewSource.toolStarted(in: permissionModeOnly) == nil, "permission mode diagnostics must not resolve a review")

        print("{\"permission_review_parser\":true,\"paired_buttons_deduplicated\":true,\"tool_start_correlated\":true,\"false_positives\":0}")
    }
}
