import Testing
@testable import solstone

@Suite("Observation Recovery Presentation")
struct ObservationRecoveryPresentationTests {
    @Test func tryAgainUsesInjectedErrorMessage() throws {
        let message = "screen stream failed after wake"
        let presentation = try #require(observationRecoveryPresentation(
            observationRowState: .error,
            errorMessage: message,
            tryAgainInFlight: false
        ))

        #expect(presentation.reason == message)
        #expect(presentation.buttonLabel == UICopy.SETTINGS_TRY_AGAIN)
        #expect(presentation.buttonDisabled == false)
    }

    @Test func tryAgainUsesFallbackWhenErrorMessageIsNil() throws {
        let presentation = try #require(observationRecoveryPresentation(
            observationRowState: .error,
            errorMessage: nil,
            tryAgainInFlight: false
        ))

        #expect(presentation.reason == UICopy.SETTINGS_OBSERVATION_RECOVERY_FALLBACK)
    }

    @Test func tryAgainInFlightKeepsReasonStable() throws {
        let message = "screen stream failed after wake"
        let ready = try #require(observationRecoveryPresentation(
            observationRowState: .error,
            errorMessage: message,
            tryAgainInFlight: false
        ))
        let inFlight = try #require(observationRecoveryPresentation(
            observationRowState: .error,
            errorMessage: message,
            tryAgainInFlight: true
        ))

        #expect(ready.reason == message)
        #expect(inFlight.reason == message)
        #expect(ready.reason == inFlight.reason)
        #expect(inFlight.buttonLabel == UICopy.SETTINGS_TRY_AGAIN_IN_FLIGHT)
        #expect(inFlight.buttonDisabled == true)
    }

    @Test func tryAgainHiddenForPermissionsState() {
        let presentation = observationRecoveryPresentation(
            observationRowState: .permissions,
            errorMessage: "screen stream failed after wake",
            tryAgainInFlight: false
        )

        #expect(presentation == nil)
    }

    @Test func tryAgainRerendersFailureReason() throws {
        let first = try #require(observationRecoveryPresentation(
            observationRowState: .error,
            errorMessage: "first failure message",
            tryAgainInFlight: false
        ))
        let second = try #require(observationRecoveryPresentation(
            observationRowState: .error,
            errorMessage: "second failure message",
            tryAgainInFlight: false
        ))

        #expect(first.reason == "first failure message")
        #expect(second.reason == "second failure message")
        #expect(first.reason != second.reason)
    }

    @Test func tryAgainShownOnlyForErrorRowState() {
        let message = "screen stream failed after wake"
        for rowState in MenubarStatusRowState.allCases {
            let presentation = observationRecoveryPresentation(
                observationRowState: rowState,
                errorMessage: message,
                tryAgainInFlight: false
            )
            if rowState == .error {
                #expect(presentation != nil)
            } else {
                #expect(presentation == nil)
            }
        }
    }
}
