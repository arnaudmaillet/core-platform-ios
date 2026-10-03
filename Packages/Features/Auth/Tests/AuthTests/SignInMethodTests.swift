import Testing
@testable import Auth

/// Guest mode, decision 2: Apple, Google, email or phone — Apple being the
/// equivalent login guideline 4.8 requires next to Google.
struct SignInMethodTests {
    @Test func theMethodsAreAppleGoogleEmailAndPhoneInThatOrder() {
        #expect(SignInMethod.all == [.provider(.apple), .provider(.google), .email, .phone])
    }

    @Test func everyMethodReadsAsContinue() {
        #expect(SignInMethod.all.allSatisfy { $0.displayName.hasPrefix("Continue with") })
    }
}
