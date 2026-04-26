import CoreGraphics
import Foundation

// Separate helper keeps CoreGraphics out of the command file while preserving the locked command import set.
func screenCaptureAccessGranted() -> Bool {
    CGPreflightScreenCaptureAccess()
}
